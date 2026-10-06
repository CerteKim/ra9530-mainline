// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Renesas RA9530 (IDT P9xxx family) wireless power transmitter / stylus charger
 *
 * The Xiaomi Book S 12.4 carries a Renesas RA9530 in "WattShare" TRx mode whose
 * only job is to charge the active stylus that magnetically attaches to the
 * tablet's edge.  Nothing in the platform enables it: the UEFI firmware does not,
 * Windows does so from its UMDF driver, and this driver is the Linux equivalent.
 *
 * Two details cost a long investigation and are worth stating up front:
 *
 *  - The TX command register is 0x0076 (TX_EN = bit0, TX_CLRINT = bit1,
 *    TX_DIS = bit2, TX_SEND_FSK = bit3, TX_WD = bit4, TX_FOD_EN = bit5,
 *    TX_TOGGLE = bit6).  The Renesas evaluation manual documents 0x007C, whose
 *    TX block is offset by six bytes on this silicon: writes there are accepted
 *    and read back, but the chip never acts on them, which makes the block look
 *    permanently dead.
 *
 *  - The reverse-mode FOD threshold (0x0092/0x0093) must be programmed *before*
 *    TX is started.  On this board both read 0x00 out of reset, and with the
 *    threshold unset the chip clamps its output to essentially nothing: the
 *    receiver answers the digital ping, the mode stays "TRx", and the pen still
 *    charges at 0 %.
 *
 * Register access is two-byte big-endian address + little-endian data with
 * auto-increment, hence the raw i2c_msg helpers below (smbus helpers cannot
 * express a 16-bit register address).
 *
 * The two AP-side power controls are optional in this driver: the firmware
 * already leaves them asserted, so the charger works even if the device tree
 * does not describe them.
 */

#include <linux/bitops.h>
#include <linux/delay.h>
#include <linux/device.h>
#include <linux/etherdevice.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/interrupt.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/pm.h>
#include <linux/power_supply.h>
#include <linux/slab.h>
#include <linux/sprintf.h>
#include <linux/sysfs.h>
#include <linux/workqueue.h>

#define RA9530_DRV_NAME		"ra9530-charger"

/* ---------------------------------------------------------------- registers */

#define RA9530_REG_CHIP_ID	0x0000	/* 16 bit */
#define RA9530_CHIP_ID		0x9530
#define RA9530_REG_CHIP_REV	0x0002	/* 8 bit */
#define RA9530_REG_CUSTOMER_ID	0x0003	/* 8 bit */

#define RA9530_REG_INT_CLEAR	0x0028	/* 32 bit, write back what 0x0030 read */
#define RA9530_REG_INT		0x0030	/* 32 bit */
#define RA9530_REG_PEN_SOC	0x003a	/* pen battery, 0..100, 0xff = invalid */
#define RA9530_REG_MODE		0x004d	/* system operating mode */
#define RA9530_REG_REV_IIN	0x006e	/* 16 bit, reverse-mode input current */
#define RA9530_REG_REV_VIN	0x0070	/* 16 bit, reverse-mode input voltage */
#define RA9530_REG_EPT_TYPE	0x0074	/* 16 bit, valid on EPT interrupt */
#define RA9530_REG_TX_CMD	0x0076	/* write: one-shot TX command bits */
#define RA9530_REG_TX_DATA	0x0078	/* TX state / data */
#define RA9530_REG_REV_TEMP	0x007a
#define RA9530_REG_DIE_TEMP	0x0084	/* 16 bit */
#define RA9530_REG_FOD_LOW	0x0092
#define RA9530_REG_FOD_HIGH	0x0093
#define RA9530_REG_PEN_MAC	0x00be	/* 6 bytes, valid after GET_BLE */
#define RA9530_REG_CEP		0x00a5	/* control error packet value */
#define RA9530_REG_RPP		0x00a6	/* received power packet value */

/*
 * Proprietary packet (0x0050..0x0057) followed by the back channel packet
 * (0x0058..0x005F).  The pen's own battery reading travels in one of these,
 * so the driver can dump them for inspection.
 */
#define RA9530_REG_PACKET	0x0050
#define RA9530_PACKET_LEN	16

/* system operating mode (0x004d) */
#define RA9530_MODE_AC_MISSING	0x00
#define RA9530_MODE_WPC_BASIC	0x01
#define RA9530_MODE_WPC_EXTD	0x02
#define RA9530_MODE_PROPRIETARY	0x03
#define RA9530_MODE_TRX		0x04

/* TX command bits (0x0076) */
#define RA9530_TX_EN		BIT(0)
#define RA9530_TX_CLRINT	BIT(1)
#define RA9530_TX_DIS		BIT(2)
#define RA9530_TX_SEND_FSK	BIT(3)
#define RA9530_TX_WD		BIT(4)
#define RA9530_TX_FOD_EN	BIT(5)
#define RA9530_TX_TOGGLE	BIT(6)

/* system interrupts (0x0030), TRx mode */
#define RA9530_INT_EPT		BIT(0)
#define RA9530_INT_START_DPING	BIT(1)
#define RA9530_INT_GET_SS	BIT(2)
#define RA9530_INT_GET_ID	BIT(3)
#define RA9530_INT_GET_CFG	BIT(4)
#define RA9530_INT_GET_PPP	BIT(5)
#define RA9530_INT_GET_DPING	BIT(6)
#define RA9530_INT_INIT_TX	BIT(7)
#define RA9530_INT_GET_BLE	BIT(8)
#define RA9530_INT_IDAUTH_OK	BIT(13)
#define RA9530_INT_CSP		BIT(15)

#define RA9530_MAX_XFER	8
#define RA9530_SOC_INVALID	0xff
#define RA9530_SOC_FULL	100
#define RA9530_SOC_RESUME	95	/* hysteresis, matches the vendor policy */

#define RA9530_ENABLE_RETRIES	3
#define RA9530_MODE_POLL_MS	20
#define RA9530_MODE_POLL_TRIES	10
#define RA9530_MONITOR_MS	5000

/*
 * This hardware never reports the pen's state of charge through the charger
 * (no CSP interrupt is ever raised), so "fully charged" is detected the way the
 * charger itself can see it: the pen stops drawing power.  RPP ("received power
 * packet", 0x00a6) is what the pen reports receiving, so it falling to zero and
 * staying there means the pen no longer wants energy.
 */
#define RA9530_RPP_IDLE_MAX	2
#define RA9530_RPP_IDLE_MS	180000	/* 3 min of no draw => assume full */
#define RA9530_RECHECK_MS	3600000	/* re-probe an hour later */

static unsigned int fod_mw = 500;
module_param(fod_mw, uint, 0644);
MODULE_PARM_DESC(fod_mw, "Reverse-mode foreign object detection threshold in mW");

static bool always_on;
module_param(always_on, bool, 0644);
MODULE_PARM_DESC(always_on, "Keep transmitting even without pen-detect GPIOs");

/* ------------------------------------------------------------------ struct */

struct ra9530_chg {
	struct i2c_client	*client;
	struct device		*dev;
	struct mutex		lock;	/* register access and session state */

	struct gpio_desc	*switch_gpio;
	struct gpio_desc	*boost_gpio;
	struct gpio_desc	*detect[2];	/* two hall sensors */

	int			irq;
	char			irq_name[32];

	struct delayed_work	monitor;
	struct power_supply	*psy;
	struct power_supply_desc psy_desc;

	bool			tx_active;
	bool			tx_disabled;	/* set from userspace via "enabled" */
	bool			pen_present;
	bool			charge_full;
	unsigned long		rpp_idle_since;	/* jiffies rpp went idle, 0 = drawing */
	unsigned long		full_since;

	/* cached telemetry, refreshed by the monitor and on sysfs reads */
	u32			mode;
	u32			tx_data;
	u32			irq_status;
	u32			irq_seen;	/* OR of every status ever seen */
	u8			pen_mac[6];	/* stylus BLE address, from GET_BLE */
	u32			rpp;
	u32			cep;
	u32			iin;
	u32			vin;
	u32			rev_temp;
	u32			die_temp;
	int			soc;
};

/* --------------------------------------------------------- register access */

static int ra9530_read(struct ra9530_chg *chg, u16 reg, void *val, size_t len)
{
	u8 addr[2] = { reg >> 8, reg & 0xff };
	struct i2c_msg msgs[2] = {
		{
			.addr = chg->client->addr,
			.flags = 0,
			.len = sizeof(addr),
			.buf = addr,
		}, {
			.addr = chg->client->addr,
			.flags = I2C_M_RD,
			.len = len,
			.buf = val,
		},
	};
	int ret;

	ret = i2c_transfer(chg->client->adapter, msgs, ARRAY_SIZE(msgs));
	if (ret < 0)
		return ret;

	return ret == ARRAY_SIZE(msgs) ? 0 : -EIO;
}

static int ra9530_write(struct ra9530_chg *chg, u16 reg, const void *val,
			size_t len)
{
	u8 buf[2 + RA9530_MAX_XFER];
	struct i2c_msg msg = {
		.addr = chg->client->addr,
		.buf = buf,
	};
	int ret;

	if (len > RA9530_MAX_XFER)
		return -EINVAL;

	buf[0] = reg >> 8;
	buf[1] = reg & 0xff;
	memcpy(buf + 2, val, len);
	msg.len = 2 + len;

	ret = i2c_transfer(chg->client->adapter, &msg, 1);
	if (ret < 0)
		return ret;

	return ret == 1 ? 0 : -EIO;
}

static int ra9530_read8(struct ra9530_chg *chg, u16 reg, u8 *val)
{
	return ra9530_read(chg, reg, val, sizeof(*val));
}

static int ra9530_read16(struct ra9530_chg *chg, u16 reg, u16 *val)
{
	u8 b[2];
	int ret;

	ret = ra9530_read(chg, reg, b, sizeof(b));
	if (ret)
		return ret;

	*val = b[0] | (b[1] << 8);
	return 0;
}

static int ra9530_read32(struct ra9530_chg *chg, u16 reg, u32 *val)
{
	u8 b[4];
	int ret;

	ret = ra9530_read(chg, reg, b, sizeof(b));
	if (ret)
		return ret;

	*val = b[0] | (b[1] << 8) | (b[2] << 16) | ((u32)b[3] << 24);
	return 0;
}

static int ra9530_write8(struct ra9530_chg *chg, u16 reg, u8 val)
{
	return ra9530_write(chg, reg, &val, sizeof(val));
}

static int ra9530_write32(struct ra9530_chg *chg, u16 reg, u32 val)
{
	u8 b[4] = { val & 0xff, (val >> 8) & 0xff,
		    (val >> 16) & 0xff, (val >> 24) & 0xff };

	return ra9530_write(chg, reg, b, sizeof(b));
}

/*
 * The charger is supposed to relay the stylus BLE address (it raises GET_BLE
 * and the sibling driver reads 0x00be).  On this customer variant that
 * register holds nothing usable ("00:00:00:00:93:00"), so anything reported
 * has to be validated before it is believed.  A Bluetooth address is either
 * public (two MSBs of the first octet = 00) or random (11); 01 and 10 are
 * reserved, and a public address never has an all-zero OUI.
 */
static bool ra9530_mac_plausible(const u8 *mac)
{
	u8 msb = mac[0] & 0xc0;

	if (is_zero_ether_addr(mac))
		return false;
	if (msb == 0x40 || msb == 0x80)
		return false;
	if (mac[0] == 0 && mac[1] == 0 && mac[2] == 0)
		return false;

	return true;
}

/* -------------------------------------------------------------- tx control */

static int ra9530_program_fod(struct ra9530_chg *chg)
{
	int ret;

	ret = ra9530_write8(chg, RA9530_REG_FOD_LOW, fod_mw & 0xff);
	if (ret)
		return ret;

	return ra9530_write8(chg, RA9530_REG_FOD_HIGH, (fod_mw >> 8) & 0xff);
}

static int ra9530_get_mode(struct ra9530_chg *chg, u8 *mode)
{
	int ret = ra9530_read8(chg, RA9530_REG_MODE, mode);

	if (!ret)
		chg->mode = *mode;

	return ret;
}

static int ra9530_tx_enable(struct ra9530_chg *chg)
{
	u8 mode = 0;
	int i, ret;

	ret = ra9530_get_mode(chg, &mode);
	if (!ret && mode == RA9530_MODE_TRX) {
		chg->tx_active = true;
		return 0;
	}

	/* Must be in place before TX starts, or the chip will not deliver power. */
	ret = ra9530_program_fod(chg);
	if (ret) {
		dev_err(chg->dev, "failed to program the FOD threshold: %d\n", ret);
		return ret;
	}

	for (i = 0; i < RA9530_ENABLE_RETRIES; i++) {
		ret = ra9530_write8(chg, RA9530_REG_TX_CMD,
				    RA9530_TX_EN | RA9530_TX_FOD_EN);
		if (ret) {
			dev_err(chg->dev, "failed to write the TX command: %d\n", ret);
			return ret;
		}

		msleep(RA9530_MODE_POLL_MS);

		if (!ra9530_get_mode(chg, &mode) && mode == RA9530_MODE_TRX) {
			chg->tx_active = true;
			dev_info(chg->dev, "transmitting (mode 0x%02x)\n", mode);
			return 0;
		}

		dev_dbg(chg->dev, "TX enable attempt %d left mode 0x%02x\n",
			i + 1, mode);
	}

	dev_err(chg->dev, "TX did not start, mode is 0x%02x\n", mode);
	return -EIO;
}

static void ra9530_tx_disable(struct ra9530_chg *chg)
{
	u8 mode = 0;
	int i, ret;

	if (!chg->tx_active)
		return;

	ret = ra9530_write8(chg, RA9530_REG_TX_CMD,
			    RA9530_TX_FOD_EN | RA9530_TX_DIS);
	if (ret) {
		dev_err(chg->dev, "failed to write TX_DIS: %d\n", ret);
		return;
	}

	for (i = 0; i < RA9530_MODE_POLL_TRIES; i++) {
		if (!ra9530_get_mode(chg, &mode) && mode != RA9530_MODE_TRX)
			break;
		msleep(RA9530_MODE_POLL_MS);
	}

	chg->tx_active = false;

	if (mode == RA9530_MODE_TRX)
		dev_warn(chg->dev, "still transmitting after TX_DIS\n");
	else
		dev_info(chg->dev, "transmit stopped (mode 0x%02x)\n", mode);
}

/* --------------------------------------------------------------- telemetry */

static void ra9530_refresh_locked(struct ra9530_chg *chg)
{
	u16 v16;
	u8 b;

	if (!ra9530_get_mode(chg, &b))
		chg->mode = b;
	if (!ra9530_read8(chg, RA9530_REG_TX_DATA, &b))
		chg->tx_data = b;
	if (!ra9530_read8(chg, RA9530_REG_PEN_SOC, &b))
		chg->soc = b;
	if (!ra9530_read8(chg, RA9530_REG_CEP, &b))
		chg->cep = b;
	if (!ra9530_read8(chg, RA9530_REG_RPP, &b))
		chg->rpp = b;
	if (!ra9530_read8(chg, RA9530_REG_REV_TEMP, &b))
		chg->rev_temp = b;
	if (!ra9530_read16(chg, RA9530_REG_REV_IIN, &v16))
		chg->iin = v16;
	if (!ra9530_read16(chg, RA9530_REG_REV_VIN, &v16))
		chg->vin = v16;
	if (!ra9530_read16(chg, RA9530_REG_DIE_TEMP, &v16))
		chg->die_temp = v16;

	/*
	 * 0x0030 is deliberately not read here.  It looks read-to-clear, so
	 * polling it would swallow events before ra9530_irq() ever sees them;
	 * the interrupt handler is the only reader.
	 */
}

static bool ra9530_pen_present(struct ra9530_chg *chg)
{
	/*
	 * Two hall sensors are wired so that they read differently only while the
	 * pen is attached.  With a single sensor described, its asserted state
	 * (per the GPIO polarity in the device tree) means "present".
	 */
	if (!chg->detect[0] || !chg->detect[1])
		return chg->detect[0] ? gpiod_get_value_cansleep(chg->detect[0])
				      : always_on;

	return gpiod_get_value_cansleep(chg->detect[0]) !=
	       gpiod_get_value_cansleep(chg->detect[1]);
}

/* ------------------------------------------------------------ power supply */

static enum power_supply_property ra9530_psy_props[] = {
	POWER_SUPPLY_PROP_PRESENT,
	POWER_SUPPLY_PROP_STATUS,
	POWER_SUPPLY_PROP_CAPACITY,
	POWER_SUPPLY_PROP_MODEL_NAME,
	POWER_SUPPLY_PROP_MANUFACTURER,
};

static int ra9530_psy_get_property(struct power_supply *psy,
				   enum power_supply_property psp,
				   union power_supply_propval *val)
{
	struct ra9530_chg *chg = power_supply_get_drvdata(psy);
	int ret = 0;

	mutex_lock(&chg->lock);

	switch (psp) {
	case POWER_SUPPLY_PROP_PRESENT:
		val->intval = 1;
		break;
	case POWER_SUPPLY_PROP_CAPACITY:
		/* 0xff means the pen has not reported a value yet */
		val->intval = (chg->soc < 0 || chg->soc > RA9530_SOC_FULL) ?
				0 : chg->soc;
		break;
	case POWER_SUPPLY_PROP_STATUS:
		if (!chg->pen_present)
			val->intval = POWER_SUPPLY_STATUS_DISCHARGING;
		else if (chg->charge_full)
			val->intval = POWER_SUPPLY_STATUS_FULL;
		else if (chg->tx_active)
			val->intval = POWER_SUPPLY_STATUS_CHARGING;
		else
			val->intval = POWER_SUPPLY_STATUS_NOT_CHARGING;
		break;
	case POWER_SUPPLY_PROP_MODEL_NAME:
		val->strval = "RA9530 stylus charger";
		break;
	case POWER_SUPPLY_PROP_MANUFACTURER:
		val->strval = "Renesas";
		break;
	default:
		ret = -EINVAL;
		break;
	}

	mutex_unlock(&chg->lock);

	return ret;
}

/* ------------------------------------------------------------------ sysfs */

static int ra9530_attr_refresh(struct ra9530_chg *chg)
{
	int ret;

	mutex_lock(&chg->lock);
	ra9530_refresh_locked(chg);
	ret = 0;
	mutex_unlock(&chg->lock);

	return ret;
}

#define RA9530_ATTR_RO(_name, _fmt, _field, _type)			\
static ssize_t _name##_show(struct device *dev,				\
			    struct device_attribute *attr, char *buf)	\
{									\
	struct ra9530_chg *chg = dev_get_drvdata(dev);			\
	_type val;							\
									\
	if (ra9530_attr_refresh(chg))					\
		return -EIO;						\
	mutex_lock(&chg->lock);						\
	val = chg->_field;						\
	mutex_unlock(&chg->lock);					\
	return sysfs_emit(buf, _fmt, val);				\
}									\
static DEVICE_ATTR_RO(_name)

RA9530_ATTR_RO(mode, "0x%02x\n", mode, u32);
RA9530_ATTR_RO(tx_data, "0x%02x\n", tx_data, u32);
RA9530_ATTR_RO(irq_status, "0x%08x\n", irq_status, u32);
RA9530_ATTR_RO(rpp, "%u\n", rpp, u32);
RA9530_ATTR_RO(cep, "%u\n", cep, u32);
RA9530_ATTR_RO(iin, "%u\n", iin, u32);
RA9530_ATTR_RO(vin, "%u\n", vin, u32);
RA9530_ATTR_RO(rev_temp, "%u\n", rev_temp, u32);
RA9530_ATTR_RO(die_temp, "%u\n", die_temp, u32);

static ssize_t soc_show(struct device *dev, struct device_attribute *attr,
			char *buf)
{
	struct ra9530_chg *chg = dev_get_drvdata(dev);
	int soc;

	if (ra9530_attr_refresh(chg))
		return -EIO;

	mutex_lock(&chg->lock);
	soc = chg->soc;
	mutex_unlock(&chg->lock);

	if (soc < 0 || soc > RA9530_SOC_FULL)
		return sysfs_emit(buf, "invalid\n");

	return sysfs_emit(buf, "%d\n", soc);
}
static DEVICE_ATTR_RO(soc);

static const char * const ra9530_int_names[];

static ssize_t irq_seen_show(struct device *dev, struct device_attribute *attr,
			     char *buf)
{
	struct ra9530_chg *chg = dev_get_drvdata(dev);
	u32 seen;
	int i, n = 0;

	mutex_lock(&chg->lock);
	seen = chg->irq_seen;
	mutex_unlock(&chg->lock);

	n += sysfs_emit(buf, "0x%08x", seen);
	for (i = 0; i < 32; i++) {
		if (!(seen & BIT(i)))
			continue;
		n += sysfs_emit_at(buf, n, " bit%d", i);
		if (ra9530_int_names[i])
			n += sysfs_emit_at(buf, n, "=%s", ra9530_int_names[i]);
	}
	n += sysfs_emit_at(buf, n, "\n");

	return n;
}
static DEVICE_ATTR_RO(irq_seen);

static ssize_t packet_show(struct device *dev, struct device_attribute *attr,
			   char *buf)
{
	struct ra9530_chg *chg = dev_get_drvdata(dev);
	u8 pkt[RA9530_PACKET_LEN];
	int ret;

	mutex_lock(&chg->lock);
	ret = ra9530_read(chg, RA9530_REG_PACKET, pkt, sizeof(pkt));
	mutex_unlock(&chg->lock);

	if (ret)
		return ret;

	return sysfs_emit(buf, "%*phN\n", (int)sizeof(pkt), pkt);
}
static DEVICE_ATTR_RO(packet);

static ssize_t tx_active_show(struct device *dev, struct device_attribute *attr,
			      char *buf)
{
	struct ra9530_chg *chg = dev_get_drvdata(dev);
	bool active;

	mutex_lock(&chg->lock);
	active = chg->tx_active;
	mutex_unlock(&chg->lock);

	return sysfs_emit(buf, "%d\n", active);
}
static DEVICE_ATTR_RO(tx_active);

static ssize_t pen_present_show(struct device *dev,
				struct device_attribute *attr, char *buf)
{
	struct ra9530_chg *chg = dev_get_drvdata(dev);
	bool present;

	mutex_lock(&chg->lock);
	present = chg->pen_present;
	mutex_unlock(&chg->lock);

	return sysfs_emit(buf, "%d\n", present);
}
static DEVICE_ATTR_RO(pen_present);

static ssize_t pen_mac_show(struct device *dev, struct device_attribute *attr,
			    char *buf)
{
	struct ra9530_chg *chg = dev_get_drvdata(dev);
	bool valid;

	mutex_lock(&chg->lock);
	valid = ra9530_mac_plausible(chg->pen_mac);
	if (!valid) {
		/* try once on demand */
		u8 mac[6];

		if (!ra9530_read(chg, RA9530_REG_PEN_MAC, mac, sizeof(mac)) &&
		    ra9530_mac_plausible(mac))
			memcpy(chg->pen_mac, mac, sizeof(mac));
		valid = ra9530_mac_plausible(chg->pen_mac);
	}
	mutex_unlock(&chg->lock);

	if (!valid)
		return sysfs_emit(buf,
			"not reported by this charger variant\n"
			"(use BLE discovery instead: match the pen by name)\n");

	return sysfs_emit(buf, "%pM\n", chg->pen_mac);
}
static DEVICE_ATTR_RO(pen_mac);

static ssize_t enabled_show(struct device *dev, struct device_attribute *attr,
			    char *buf)
{
	struct ra9530_chg *chg = dev_get_drvdata(dev);
	bool on;

	mutex_lock(&chg->lock);
	on = !chg->tx_disabled;
	mutex_unlock(&chg->lock);

	return sysfs_emit(buf, "%d\n", on);
}

static ssize_t enabled_store(struct device *dev, struct device_attribute *attr,
			     const char *buf, size_t count)
{
	struct ra9530_chg *chg = dev_get_drvdata(dev);
	bool on;
	int ret;

	ret = kstrtobool(buf, &on);
	if (ret)
		return ret;

	mutex_lock(&chg->lock);
	chg->tx_disabled = !on;
	if (!on)
		ra9530_tx_disable(chg);
	mutex_unlock(&chg->lock);

	if (on)
		schedule_delayed_work(&chg->monitor, 0);

	return count;
}
static DEVICE_ATTR_RW(enabled);

static ssize_t fod_mw_show(struct device *dev, struct device_attribute *attr,
			   char *buf)
{
	return sysfs_emit(buf, "%u\n", fod_mw);
}
static DEVICE_ATTR_RO(fod_mw);

static struct attribute *ra9530_attrs[] = {
	&dev_attr_mode.attr,
	&dev_attr_tx_data.attr,
	&dev_attr_irq_status.attr,
	&dev_attr_rpp.attr,
	&dev_attr_cep.attr,
	&dev_attr_iin.attr,
	&dev_attr_vin.attr,
	&dev_attr_rev_temp.attr,
	&dev_attr_die_temp.attr,
	&dev_attr_soc.attr,
	&dev_attr_packet.attr,
	&dev_attr_irq_seen.attr,
	&dev_attr_enabled.attr,
	&dev_attr_pen_mac.attr,
	&dev_attr_tx_active.attr,
	&dev_attr_pen_present.attr,
	&dev_attr_fod_mw.attr,
	NULL,
};
ATTRIBUTE_GROUPS(ra9530);

/* -------------------------------------------------------------------- irq */

static const char * const ra9530_int_names[] = {
	[0] = "EPT",
	[1] = "START_DPING",
	[2] = "GET_SS",
	[3] = "GET_ID",
	[4] = "GET_CFG",
	[5] = "GET_PPP",
	[6] = "GET_DPING",
	[7] = "INIT_TX",
	[8] = "GET_BLE",
	[13] = "IDAUTH_OK",
	[15] = "CSP",
};

static void ra9530_log_interrupt(struct ra9530_chg *chg, u32 status)
{
	char bits[128] = "";
	int i, n = 0;

	for (i = 0; i < ARRAY_SIZE(ra9530_int_names); i++) {
		if (!ra9530_int_names[i] || !(status & BIT(i)))
			continue;
		n += scnprintf(bits + n, sizeof(bits) - n, "%s%s",
			       n ? "|" : "", ra9530_int_names[i]);
	}

	dev_dbg(chg->dev, "interrupt 0x%08x (%s)\n", status, bits);
}

static irqreturn_t ra9530_irq(int irq, void *data)
{
	struct ra9530_chg *chg = data;
	u32 status = 0;

	mutex_lock(&chg->lock);

	if (ra9530_read32(chg, RA9530_REG_INT, &status) || !status)
		goto out;

	chg->irq_status = status;
	chg->irq_seen |= status;
	ra9530_log_interrupt(chg, status);

	if (status & RA9530_INT_GET_BLE) {
		u8 mac[6];

		if (!ra9530_read(chg, RA9530_REG_PEN_MAC, mac, sizeof(mac)) &&
		    ra9530_mac_plausible(mac)) {
			if (memcmp(mac, chg->pen_mac, sizeof(mac))) {
				memcpy(chg->pen_mac, mac, sizeof(mac));
				dev_info(chg->dev, "stylus BLE address %pM\n",
					 chg->pen_mac);
			}
		} else {
			/*
			 * Common case on this board: 0x00be is not the address
			 * register.  The address is instead obtained from BLE
			 * discovery (match the pen by name).
			 */
			dev_dbg(chg->dev,
				"0x00be holds no usable BLE address on this variant\n");
		}
	}

	if (status & RA9530_INT_EPT) {
		u16 ept = 0;

		ra9530_read16(chg, RA9530_REG_EPT_TYPE, &ept);
		dev_warn(chg->dev, "end power transfer, EPT type 0x%04x\n", ept);
	}

	/*
	 * Dump the raw proprietary / back channel packet.  The pen's battery
	 * reading travels in one of these; with dynamic debug enabled this shows
	 * exactly which byte it is (and it climbs while the pen charges).
	 */
	if (status & (RA9530_INT_GET_SS | RA9530_INT_GET_ID |
		      RA9530_INT_GET_CFG | RA9530_INT_GET_PPP |
		      RA9530_INT_CSP)) {
		u8 pkt[RA9530_PACKET_LEN];

		if (!ra9530_read(chg, RA9530_REG_PACKET, pkt, sizeof(pkt)))
			dev_dbg(chg->dev, "pen packet: %*phN\n",
				(int)sizeof(pkt), pkt);
	}

	if (status & RA9530_INT_CSP) {
		u8 soc;
		u8 pkt[RA9530_PACKET_LEN];

		/*
		 * The battery packet arrived.  Read the value and, because the
		 * encoding on this customer variant is not fully known, log the
		 * packet that carried it whenever the value changes.
		 */
		if (!ra9530_read8(chg, RA9530_REG_PEN_SOC, &soc)) {
			bool changed = (soc != chg->soc);

			chg->soc = soc;
			if (changed) {
				if (!ra9530_read(chg, RA9530_REG_PACKET, pkt,
						 sizeof(pkt)))
					dev_info(chg->dev,
						 "pen battery %u %% (0x003a, packet %*phN)\n",
						 soc, (int)sizeof(pkt), pkt);
				else
					dev_info(chg->dev, "pen battery %u %% (0x003a)\n",
						 soc);
			}
		}
	}

	/* Clear: write what we read back, then issue the CLR command. */
	ra9530_write32(chg, RA9530_REG_INT_CLEAR, status);
	ra9530_write8(chg, RA9530_REG_TX_CMD,
		      RA9530_TX_FOD_EN | RA9530_TX_CLRINT);

out:
	mutex_unlock(&chg->lock);

	if (chg->psy)
		power_supply_changed(chg->psy);

	return IRQ_HANDLED;
}

/* ---------------------------------------------------------------- monitor */

static void ra9530_monitor_work(struct work_struct *work)
{
	struct ra9530_chg *chg = container_of(to_delayed_work(work),
					      struct ra9530_chg, monitor);
	bool pen;
	int ret = 0;

	mutex_lock(&chg->lock);

	pen = ra9530_pen_present(chg);
	if (pen != chg->pen_present) {
		dev_info(chg->dev, "pen %s\n", pen ? "attached" : "detached");
		chg->pen_present = pen;
		if (!pen) {
			/* a fresh attachment is a new charging session */
			chg->charge_full = false;
			chg->rpp_idle_since = 0;
		}
	}

	ra9530_refresh_locked(chg);

	if (!pen) {
		ra9530_tx_disable(chg);
	} else if (chg->charge_full) {
		/*
		 * Re-check hourly: a pen that is full now may want a top-up later,
		 * and the only way to find out is to offer power again.
		 */
		if (chg->full_since &&
		    time_after(jiffies, chg->full_since +
			       msecs_to_jiffies(RA9530_RECHECK_MS))) {
			dev_info(chg->dev, "re-checking the pen's charge state\n");
			chg->charge_full = false;
			chg->rpp_idle_since = 0;
		} else {
			ra9530_tx_disable(chg);
		}
	} else if (chg->tx_disabled) {
		ra9530_tx_disable(chg);
	} else {
		ret = ra9530_tx_enable(chg);
	}

	/*
	 * Full detection.  Two possible sources:
	 *  - the state of charge, but only on hardware that actually reports it
	 *    (a CSP interrupt must have been seen at least once);
	 *  - otherwise the pen simply stops drawing power.
	 */
	if (pen && chg->tx_active) {
		if (chg->irq_seen & RA9530_INT_CSP) {
			if (chg->soc >= RA9530_SOC_FULL) {
				dev_info(chg->dev, "pen reports full (%d %%)\n",
					 chg->soc);
				chg->charge_full = true;
				chg->full_since = jiffies;
				ra9530_tx_disable(chg);
			}
		} else {
			if (chg->rpp <= RA9530_RPP_IDLE_MAX) {
				if (!chg->rpp_idle_since)
					chg->rpp_idle_since = jiffies;
				else if (time_after(jiffies, chg->rpp_idle_since +
					   msecs_to_jiffies(RA9530_RPP_IDLE_MS))) {
					dev_info(chg->dev,
						 "pen stopped drawing power (rpp=%u), assuming fully charged\n",
						 chg->rpp);
					chg->charge_full = true;
					chg->full_since = jiffies;
					chg->rpp_idle_since = 0;
					ra9530_tx_disable(chg);
				}
			} else {
				chg->rpp_idle_since = 0;
			}
		}
	} else {
		chg->rpp_idle_since = 0;
	}

	mutex_unlock(&chg->lock);

	if (!ret && chg->psy)
		power_supply_changed(chg->psy);

	schedule_delayed_work(&chg->monitor,
			      msecs_to_jiffies(RA9530_MONITOR_MS));
}

/* ------------------------------------------------------------ power mgmt */

static int ra9530_suspend(struct device *dev)
{
	struct ra9530_chg *chg = dev_get_drvdata(dev);

	cancel_delayed_work_sync(&chg->monitor);

	mutex_lock(&chg->lock);
	ra9530_tx_disable(chg);
	mutex_unlock(&chg->lock);

	return 0;
}

static int ra9530_resume(struct device *dev)
{
	struct ra9530_chg *chg = dev_get_drvdata(dev);

	schedule_delayed_work(&chg->monitor, 0);

	return 0;
}

static const struct dev_pm_ops ra9530_pm_ops = {
	SYSTEM_SLEEP_PM_OPS(ra9530_suspend, ra9530_resume)
};

/* ------------------------------------------------------------------ probe */

/*
 * Every one of these pins is optional: platform firmware already leaves the
 * switch and the boost asserted, and the hall sensors only decide *when* to
 * transmit.  A device instantiated by hand (sysfs new_device) has no firmware
 * node at all, and the GPIO core reports that as an error rather than as
 * "absent", so an error here must not fail the probe.
 */
static struct gpio_desc *ra9530_optional_gpio(struct ra9530_chg *chg,
					      const char *con_id, int index,
					      enum gpiod_flags flags)
{
	struct gpio_desc *desc;

	desc = index < 0 ?
		devm_gpiod_get_optional(chg->dev, con_id, flags) :
		devm_gpiod_get_index_optional(chg->dev, con_id, index, flags);

	if (IS_ERR(desc)) {
		dev_warn(chg->dev, "no %s GPIO (%ld), continuing without it\n",
			 con_id, PTR_ERR(desc));
		return NULL;
	}

	return desc;
}

static int ra9530_probe(struct i2c_client *client)
{
	struct ra9530_chg *chg;
	struct power_supply_config psy_cfg = {};
	u16 chip_id = 0;
	u8 rev = 0, customer = 0;
	int ret;

	if (!i2c_check_functionality(client->adapter, I2C_FUNC_I2C)) {
		dev_err(&client->dev, "adapter does not support plain I2C\n");
		return -EOPNOTSUPP;
	}

	chg = devm_kzalloc(&client->dev, sizeof(*chg), GFP_KERNEL);
	if (!chg)
		return -ENOMEM;

	chg->client = client;
	chg->dev = &client->dev;
	chg->soc = -1;
	mutex_init(&chg->lock);
	i2c_set_clientdata(client, chg);

	ret = ra9530_read16(chg, RA9530_REG_CHIP_ID, &chip_id);
	if (ret) {
		dev_err(chg->dev, "cannot read the chip ID: %d\n", ret);
		return ret;
	}

	if (chip_id != RA9530_CHIP_ID) {
		dev_err(chg->dev, "unexpected chip ID 0x%04x\n", chip_id);
		return -ENODEV;
	}

	ra9530_read8(chg, RA9530_REG_CHIP_REV, &rev);
	ra9530_read8(chg, RA9530_REG_CUSTOMER_ID, &customer);
	dev_info(chg->dev, "RA9530 rev %u, customer %u\n", rev, customer);

	/*
	 * Keep the external switch and the boost enabled: the firmware already
	 * leaves them asserted, and driving the switch low resets the chip.
	 * All four lookups are optional (see ra9530_optional_gpio()).
	 */
	chg->switch_gpio = ra9530_optional_gpio(chg, "switch", -1,
						GPIOD_OUT_HIGH);
	chg->boost_gpio = ra9530_optional_gpio(chg, "boost", -1,
					       GPIOD_OUT_HIGH);
	chg->detect[0] = ra9530_optional_gpio(chg, "pen-detect", 0, GPIOD_IN);
	chg->detect[1] = ra9530_optional_gpio(chg, "pen-detect", 1, GPIOD_IN);

	if (!chg->detect[0] || !chg->detect[1])
		dev_warn(chg->dev,
			 "no pen-detect GPIOs described, %s\n",
			 always_on ? "charging unconditionally"
				   : "charging disabled (use always_on=1)");

	chg->irq = client->irq;
	if (chg->irq > 0) {
		snprintf(chg->irq_name, sizeof(chg->irq_name), "%s",
			 dev_name(chg->dev));
		ret = devm_request_threaded_irq(chg->dev, chg->irq, NULL,
						ra9530_irq,
						IRQF_ONESHOT |
						IRQF_TRIGGER_FALLING,
						chg->irq_name, chg);
		if (ret) {
			dev_err(chg->dev, "failed to request IRQ %d: %d\n",
				chg->irq, ret);
			return ret;
		}
	}

	chg->psy_desc.name = RA9530_DRV_NAME;
	chg->psy_desc.type = POWER_SUPPLY_TYPE_BATTERY;
	chg->psy_desc.properties = ra9530_psy_props;
	chg->psy_desc.num_properties = ARRAY_SIZE(ra9530_psy_props);
	chg->psy_desc.get_property = ra9530_psy_get_property;

	psy_cfg.drv_data = chg;
	psy_cfg.fwnode = dev_fwnode(chg->dev);

	chg->psy = devm_power_supply_register(chg->dev, &chg->psy_desc,
					      &psy_cfg);
	if (IS_ERR(chg->psy))
		return dev_err_probe(chg->dev, PTR_ERR(chg->psy),
				     "failed to register the power supply\n");

	INIT_DELAYED_WORK(&chg->monitor, ra9530_monitor_work);

	mutex_lock(&chg->lock);
	ret = ra9530_program_fod(chg);
	mutex_unlock(&chg->lock);
	if (ret)
		dev_warn(chg->dev, "failed to program the FOD threshold: %d\n",
			 ret);

	schedule_delayed_work(&chg->monitor, 0);

	dev_info(chg->dev, "registered, FOD threshold %u mW\n", fod_mw);

	return 0;
}

static void ra9530_remove(struct i2c_client *client)
{
	struct ra9530_chg *chg = i2c_get_clientdata(client);

	cancel_delayed_work_sync(&chg->monitor);

	mutex_lock(&chg->lock);
	ra9530_tx_disable(chg);
	mutex_unlock(&chg->lock);

	/* The switch and boost are left asserted, as the firmware set them. */
}

static const struct of_device_id ra9530_of_match[] = {
	{ .compatible = "renesas,ra9530" },
	{ }
};
MODULE_DEVICE_TABLE(of, ra9530_of_match);

static const struct i2c_device_id ra9530_i2c_id[] = {
	{ "ra9530", 0 },
	{ }
};
MODULE_DEVICE_TABLE(i2c, ra9530_i2c_id);

static struct i2c_driver ra9530_driver = {
	.driver = {
		.name = RA9530_DRV_NAME,
		.of_match_table = ra9530_of_match,
		.pm = pm_ptr(&ra9530_pm_ops),
		.dev_groups = ra9530_groups,
	},
	.probe = ra9530_probe,
	.remove = ra9530_remove,
	.id_table = ra9530_i2c_id,
};
module_i2c_driver(ra9530_driver);

MODULE_AUTHOR("Written for the Xiaomi Book S 12.4 (SC8180X)");
MODULE_DESCRIPTION("Renesas RA9530 wireless power transmitter / stylus charger");
MODULE_LICENSE("GPL");
