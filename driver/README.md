# RA9530 stylus charger driver (Xiaomi Book S 12.4)

A Linux driver for the Renesas RA9530 wireless power transmitter used as the
magnetic stylus charger on the Xiaomi Book S 12.4 (`xiaomi,book-12.4`, SC8180X).

This is the Linux counterpart of the Windows UMDF driver (`wtSXBCharger.dll`)
for the ACPI device `Device (SXB)`, `_HID = "TXRA9530"`.  See
[../ra9530-upstream-report.md](../notes/ra9530-upstream-report.md) for the full
investigation, and [../ra9530-stylus-charger.md](../notes/ra9530-stylus-charger.md)
for the lab notes.

## Why this needed a driver at all

Nothing enables the charger by itself:

| State | Pen charges? |
|---|---|
| UEFI firmware setup (no OS) | no |
| Windows | yes — its UMDF driver does it |
| Linux, before this driver | no |

The chip is controlled **entirely over I2C**; the `GP2/TX_EN` pin of the
reference design is not involved.  Two details are easy to get wrong:

1. **The TX command register is `0x0076`, not `0x007C`.**  The Renesas
   evaluation manual lists `0x007C` for the TX block, but on this silicon that
   block is offset by six bytes.  Writes to `0x007C` are accepted and read back,
   yet the chip never acts on them — which makes the block look permanently
   dead.
2. **The reverse-mode FOD threshold (`0x0092`/`0x0093`) must be programmed
   before TX is enabled.**  On this board both read `0x00` after reset.  With
   the threshold unset the chip still reports "TRx" and the receiver still
   answers the digital ping, but the output is clamped to essentially nothing:
   the pen charges at 0 %.

Purely over I2C, the sequence is:

```sh
i2ctransfer -y 1 w3@0x3b 0x00 0x92 0xf4     # FOD = 500 mW
i2ctransfer -y 1 w3@0x3b 0x00 0x93 0x01
i2ctransfer -y 1 w3@0x3b 0x00 0x76 0x21     # TX_EN | TX_FOD_EN
```

After that `0x004D` reads `0x04` (TRx) and `0x00A6` (RPP, the power the pen
reports receiving) becomes non-zero.  The pen is then charging; the die
temperature rises from ~30 °C to ~39 °C.

## Layout

| File | Purpose |
|---|---|
| `ra9530-charger.c` | the driver |
| `Makefile` | Kbuild, works out-of-tree and in-tree |
| `Kconfig` | in-tree symbol |
| `renesas,ra9530.yaml` | devicetree binding |
| `ra9530.dtsi` | ready-to-paste device tree node |
| `install-dt.sh` | patches the DTB in `/boot` with `fdtput` (no kernel rebuild) |
| `build.sh` | builds the module |

## Build and load

Out-of-tree against the running kernel:

```sh
./build.sh                                   # or: make
sudo insmod ./ra9530-charger.ko
dmesg | grep -i ra9530
```

If `/lib/modules/$(uname -r)/build` is missing, point it at the source tree:

```sh
KDIR=~/aarch64-packages/linux-surface/src/kernel ./build.sh
```

In-tree: copy the files to `drivers/power/supply/`, add
`obj-$(CONFIG_RA9530_CHARGER) += ra9530-charger.o` to that Makefile and the
Kconfig entry, then enable `CONFIG_RA9530_CHARGER`.

## Device tree

Either paste `ra9530.dtsi` into
`arch/arm64/boot/dts/qcom/sc8180x-xiaomi-book-12.4.dts` and rebuild, or patch
the installed blob directly (no rebuild, no risk to the tree):

```sh
sudo ./install-dt.sh          # backs the DTB up first
sudo reboot
```

Two things the node gets right that the existing commented-out stub does not:

* `&i2c7` is set to **400 kHz**, which is what the platform firmware declares
  (`0x00061A80`); the in-tree value of 1 MHz makes the bus marginal.
* **no `pinctrl-0`**: the firmware already leaves all five pins muxed as plain
  GPIOs with correct bias and drive settings, and the stub referenced a
  `txra9530_int_default` label that does not exist anywhere in the tree.

The driver does not depend on the pen-detect GPIOs: the firmware leaves the
switch and boost asserted, so the charger works without them.  Without them,
pass `always_on=1` to charge unconditionally.

## Behaviour

* On probe the chip ID is verified (`0x9530`), the reverse FOD threshold is
  programmed and the power supply is registered.
* A work item polls every 5 s: pen attach/detach (two hall sensors compared),
  the pen's state of charge, and the telemetry below.  Transmit is enabled when
  a pen is attached and stopped when it leaves or reports a full battery
  (100 %, resuming below 95 %, matching the vendor behaviour).
* The chip interrupt is handled on a falling edge; interrupts are logged at
  debug level and the system interrupt register is cleared in the documented
  way (write the value back to `0x0028`, then `TX_FOD_EN | TX_CLRINT` to
  `0x0076`).
* Suspend stops transmitting, resume restarts the monitor.

### Module parameters

| Parameter | Default | Meaning |
|---|---|---|
| `fod_mw` | 0 | override for the reverse-mode FOD threshold; 0 (the default) takes it from the device tree (`renesas,fod-mw`), falling back to 500 mW |
| `always_on` | 0 | transmit even when no pen-detect GPIOs are present |

The threshold itself comes from the device tree
(`renesas,fod-mw`, described in the binding); the module parameter is only an
override for experiments.

### Power supply

`/sys/class/power_supply/ra9530-charger/` exposes the **pen's** battery
(capacity + status), which is what the Windows driver reads too.

### Debug attributes

`mode`, `tx_data`, `irq_status`, `irq_seen`, `rpp`, `cep`, `iin`, `vin`,
`rev_temp`, `die_temp`, `soc`, `packet`, `tx_active`, `pen_present`, `pen_mac`
(informational; not usable on this variant), `fod_mw` (the effective
threshold, whether it came from the device tree or the parameter), and the writable
`enabled` — all under the device, e.g.

```sh
cat /sys/bus/i2c/devices/1-003b/rpp        # received power the pen reports
cat /sys/bus/i2c/devices/1-003b/pen_present
```

`rpp` (register `0x00A6`) is the most useful one: it is non-zero exactly while
power is being delivered to the pen.

## Known limitations / TODO

* **This hardware never reports the pen's state of charge through the charger.**
  Decisive evidence — the cumulative interrupt bitmap (`irq_seen`) after a full
  charging session:

  ```
  0x0000213f bit0=EPT bit1=START_DPING bit2=GET_SS bit3=GET_ID bit4=GET_CFG
             bit5=GET_PPP bit8=GET_BLE bit13=IDAUTH_OK
  ```

  The pen completes the whole WPC handshake (signal strength, identification,
  configuration, **ID authentication success**, even handing over its BLE
  address) but **never sends a CSP packet** — bit 15 is absent, so `0x003A`
  can never update.  The address is right; there is simply nothing to read.
  Consequently the charge-limit logic cannot work from the charger and the
  `capacity` attribute stays 0.

  **The pen's battery is available in Linux from another source:** the
  touchscreen controller reports it over HID, and the kernel's generic HID
  battery support exposes it as

  ```
  /sys/class/power_supply/hid-0018:4858:121A.0003-battery/capacity
  ```

  (observed at 25 %, and it does change).  This is almost certainly where
  Windows gets its pen battery figure from as well.

  **So the split is: the driver provides a switch, userspace owns the policy.**

  ```sh
  # stop / allow charging on demand (e.g. from a script watching the HID battery)
  echo 0 | sudo tee /sys/bus/i2c/devices/1-003b/enabled
  echo 1 | sudo tee /sys/bus/i2c/devices/1-003b/enabled
  ```

  Without a policy the pen simply keeps charging, which is harmless: the chip's
  own OVP/OCP/OTP protections stay active and the die temperature sits at a
  steady 38–39 °C.

  **Update (measured on hardware):** the pen's own BLE Battery Service is the
  accurate source.  Once the pen is bonded, BlueZ exposes it as
  `org.bluez.Battery1`, e.g.

  ```sh
  busctl --system get-property org.bluez \
      /org/bluez/hci0/dev_XX_XX_XX_XX_XX_XX org.bluez.Battery1 Percentage
  ```

  (the BLE address is a rotating random address — match the pen by name, not by
  address).  Note also that a **fully charged pen still reports `rpp` ≈ 30**, so
  the `rpp`-based "stopped drawing" heuristic above does *not* trigger on this
  stylus; a percentage-driven policy is the one that works here.  The companion
  scripts in the parent directory (`ra9530-pen-battery.sh`,
  `ra9530-charge-policy.sh`) do exactly that on top of the writable `enabled`
  attribute.
* **`pen_mac` is not usable on this hardware.**  The charger raises `GET_BLE`
  and the sibling driver reads the stylus address from `0x00be`, but this
  variant returns `00:00:00:00:93:00` there, and the back-channel packet carries
  only three matching bytes.  The driver validates the value (Bluetooth address
  type bits plus a non-zero OUI) and reports "not reported by this charger
  variant" rather than emitting a bogus address.  Get the address from BLE
  discovery and match the pen by name — nothing in the driver depends on it.
* Pen attach/detach is polled at 5 s rather than interrupt-driven; the two hall
  sensors could be used as wake sources instead.
* Only `TX_DIS` (bit 2 of `0x0076`) is used to stop transmitting.  The vendor
  driver additionally issues a `TXMODE_EXIT` command code (`BIT(9)`) to the
  command register `0x004E`; that path is untested on this hardware.
* No `TX OCP` / minimum-frequency configuration is done; the chip's defaults
  together with the FOD threshold proved sufficient (die temperature stable at
  39 °C while charging).

## References

* `nik012003/idtp9418-mainline` — <https://github.com/nik012003/idtp9418-mainline>
  Driver for the IDT P9418 in the Xiaomi Pad 5 (same pen, sibling chip).  Its
  register map is the one that matches this hardware, and it is where the FOD
  requirement and the two-hall-sensor trick come from.
* `kernel/google-modules/bms` (`p9221_chip.c`, `ra9530_chip_tx_mode()`) —
  Google's Pixel driver, which has explicit RA9530 support but uses P9412
  register addresses.
* Renesas: RA9530/RA9520 Stylus Application AP Design Guide (R16UH0023EU0100)
  and RA953-R Evaluation Kit Manual (R16UH0022EU0200).
