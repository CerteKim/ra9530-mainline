#!/usr/bin/env bash
#
# install-dt.sh — 把 RA9530 笔充电器的设备树节点写进 DTB
#
# 用 fdtput 直接改 /boot 下的扁平设备树，**不需要重编内核/设备树**。
# 会自动备份为 <dtb>.orig-ra9530。
#
#   sudo ./install-dt.sh            # 安装节点（幂等，可重复执行）
#   sudo ./install-dt.sh --revert   # 从备份还原
#
# 硬件事实（取自本机实测）：
#   i2c7 = /soc@0/geniqup@8c0000/i2c@89c000 （从设备 0x3b）
#   TLMM = /soc@0/pinctrl@3100000 （phandle 动态查询，本机为 53，#interrupt-cells = 2）
#   gpio11 = 开关(高有效)   gpio186 = 7V 升压(高有效)
#   gpio97 / gpio189 = 两个霍尔（读数不同即视为笔已吸附）
#   gpio101 = 芯片 INT（开漏、低有效、空闲高）→ 下降沿

set -euo pipefail

DTBS=(
	/boot/dtb/linux-mibook/qcom/sc8180x-xiaomi-book-12.4.dtb
	/boot/dtb/linux-mibook/qcom/sc8180x-xiaomi-book-12.4-oc.dtb
)
I2C=/soc@0/geniqup@8c0000/i2c@89c000
NODE=$I2C/charger@3b
TLMM=/soc@0/pinctrl@3100000
BAK=.orig-ra9530

# DTB_TEST=<path> 可在任意副本上试跑：不需要 root，也不碰 /boot
if [[ -n "${DTB_TEST:-}" ]]; then
	DTBS=( "$DTB_TEST" )
else
	[[ ${EUID} -eq 0 ]] || { echo "需要 root: sudo $0" >&2; exit 1; }
fi
command -v fdtput >/dev/null || { echo "缺少 fdtput（pacman -S dtc）" >&2; exit 1; }

if [[ "${1:-}" == "--revert" ]]; then
	for d in "${DTBS[@]}"; do
		[[ -f "$d$BAK" ]] || continue
		cp "$d$BAK" "$d"
		echo "已还原 $d"
	done
	exit 0
fi

for d in "${DTBS[@]}"; do
	[[ -f "$d" ]] || continue
	echo "=== $d ==="

	[[ -f "$d$BAK" ]] || { cp "$d" "$d$BAK"; echo "  已备份 -> $d$BAK"; }

	# fdtget 输出的是【十进制】，而 fdtput -t x 把参数当【十六进制】解析，
	# 所以必须先转换：53(dec) -> "0x35"。若直接写 0x53 就变成 83，
	# 那正好是 /smp2p-mpss/slave-kernel 的 phandle —— 内核会去错误的节点找
	# #gpio-cells / 中断域，报 "could not get #gpio-cells for .../slave-kernel"
	# 以及 "failed to get the switch GPIO (-EINVAL)"。
	ph_dec=$(fdtget "$d" "$TLMM" phandle)
	ph=$(printf '0x%x' "$ph_dec")
	echo "  TLMM phandle = $ph_dec (dec) = $ph (hex)"

	cf=$(fdtget "$d" "$I2C" clock-frequency 2>/dev/null || echo 0)
	if [[ "$cf" != "400000" ]]; then
		fdtput -t i "$d" "$I2C" clock-frequency 400000
		echo "  i2c7 速率: $cf -> 400000"
	else
		echo "  i2c7 速率: 400000（已正确）"
	fi

	if fdtget -l "$d" "$I2C" 2>/dev/null | grep -qx "charger@3b"; then
		fdtput -r "$d" "$NODE"	# -r 是删节点（-d 只能删属性）
		echo "  已删除旧节点（保证幂等）"
	fi

	fdtput -c "$d" "$NODE"
	fdtput -t s "$d" "$NODE" compatible          "renesas,ra9530"
	fdtput -t x "$d" "$NODE" reg                 0x3b
	fdtput -t x "$d" "$NODE" switch-gpios        "$ph" 0x0b 0
	fdtput -t x "$d" "$NODE" boost-gpios         "$ph" 0xba 0
	fdtput -t x "$d" "$NODE" pen-detect-gpios    "$ph" 0x61 1 "$ph" 0xbd 1
	fdtput -t x "$d" "$NODE" interrupts-extended "$ph" 0x65 2
	fdtput -t i "$d" "$NODE" renesas,fod-mw      500

	echo "  写入结果:"
	for p in compatible reg switch-gpios boost-gpios pen-detect-gpios \
		 interrupts-extended renesas,fod-mw; do
		printf '    %-20s %s\n' "$p" "$(fdtget "$d" "$NODE" "$p" 2>&1)"
	done
done

cat <<'EOF'

完成。注意：

  * gpio 三元组的含义是 <&tlmm 引脚号 标志>，标志 0 = ACTIVE_HIGH、1 = ACTIVE_LOW。
  * 节点里没有 pinctrl-0 —— 固件已把这五个脚都配成普通 GPIO 且偏置/驱动能力正确，
    树上原来那个 pinctrl 标签（txra9530_int_default）根本不存在，不需要它。

接下来：
  1) ./build.sh                       # 编译模块
  2) sudo reboot                      # 让新 DTB 生效
  3) sudo insmod ./ra9530-charger.ko  # 加载
  4) dmesg | grep -i ra9530
     cat /sys/class/power_supply/ra9530-charger/{status,capacity}
     cat /sys/class/power_supply/ra9530-charger/rpp     # 非 0 = 笔在收功率

还原：sudo ./install-dt.sh --revert
EOF
