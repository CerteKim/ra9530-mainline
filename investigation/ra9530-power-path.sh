#!/usr/bin/env bash
#
# ra9530-power-path.sh — 判定 gpio11 到底是"芯片电源"还是"I2C 总线开关"
#
# 为什么关键：
#   之前看到 gpio11 拉低后 IC 从 I2C 上消失（ENXIO），就断定它是电源。
#   但 I2C 总线开关/隔离器会让现象完全一样。
#   而这两者后果截然不同：
#     * 若是电源   -> 我们的翻转就是一次真正的 VOUT 上电事件（手册说可触发 GP2 自动使能）
#     * 若是总线开关 -> 芯片从未掉电，"VOUT 上电时 GP2 已高"这个条件从未被满足过
#
# 判据（写标记法）：
#   往 0x0050（RW 私有包缓冲）写 DE AD BE EF，然后制造一次 gpio11 低->高：
#     读回仍是 DE AD BE EF -> 芯片没掉电 -> gpio11 不是电源（是总线/使能开关）
#     读回变成 00 00 00 00 -> 芯片复位过 -> gpio11 是电源
#
# 同时看 gpio186 是否会改变 Vin/Vrect（若 Vin 掉下来，说明 186 在电源路径上）。
#
# 用法: sudo ./ra9530-power-path.sh

set -u

ADDR=0x3b
I2C_BUS=""
GPIO_CHIP="gpiochip3"
PIN_A=11
PIN_B=186
TLMM_BASE=""

die() { printf '\n!! %s\n' "$*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die "需要 root: sudo $0"

for d in /sys/bus/i2c/devices/i2c-*; do
    [[ -e "$d/of_node" ]] || continue
    [[ "$(readlink -f "$d/of_node")" == *"i2c@89c000"* ]] && I2C_BUS="${d##*-}"
done
[[ -n "$I2C_BUS" ]] || die "没找到 89c000.i2c (&i2c7)"
for c in /sys/class/gpio/gpiochip*; do
    [[ "$(cat "$c/label" 2>/dev/null)" == "3100000.pinctrl" ]] && TLMM_BASE=$(cat "$c/base")
done
[[ -n "$TLMM_BASE" ]] || die "没找到 TLMM sysfs 基址"

raw() { i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 "$1" "r$2" 2>&1; }
h8()  { local o; o=$(raw "$1" 1); [[ "$o" == 0x* ]] && printf '0x%02X' "$o" || printf 'FAIL'; }
mv()  { local a b; read -r a b <<<"$(raw "$1" 2)"
        [[ "$a" == 0x* && "$b" == 0x* ]] && printf '%dmV' $(( b<<8 | a )) || printf 'FAIL'; }

gpio_path() { echo "/sys/class/gpio/gpio$(( TLMM_BASE + $1 ))"; }
gpio_prep() {
    local p; p=$(gpio_path "$1")
    [[ -d "$p" ]] || { echo "$(( TLMM_BASE + $1 ))" > /sys/class/gpio/export 2>/dev/null; sleep 0.05; }
    echo high > "$p/direction" 2>/dev/null
}
gpio_set() { echo "$2" > "$(gpio_path "$1")/value" || die "写 gpio$1=$2 失败"; }
gpio_get() { cat "$(gpio_path "$1")/value" 2>/dev/null || echo "?"; }

restore() {
    local rc=$?
    gpio_prep "$PIN_A"; gpio_prep "$PIN_B"; sleep 0.05
    printf '\n[cleanup] gpio%s=%s gpio%s=%s\n' "$PIN_A" "$(gpio_get "$PIN_A")" "$PIN_B" "$(gpio_get "$PIN_B")"
    local o; for o in "$PIN_A" "$PIN_B"; do
        echo "$(( TLMM_BASE + o ))" > /sys/class/gpio/unexport 2>/dev/null
    done
    exit $rc
}
trap restore EXIT INT TERM

echo "=============================================================="
echo " RA9530 电源路径判定 (i2c-$I2C_BUS)"
echo "   gpio$PIN_A = 电源 还是 I2C 总线开关？"
echo "   gpio$PIN_B 是否影响 Vin？"
echo "=============================================================="
gpio_prep "$PIN_A"; gpio_prep "$PIN_B"

echo
echo "########## 0. 基线 ##########"
printf '  CHIP_ID=%s  MODE=%s  TX_STAT=%s\n' "$(raw 0x00 2)" "$(h8 0x4d)" "$(h8 0x7e)"
printf '  Vin=%s  Vrect=%s\n' "$(mv 0x80)" "$(mv 0x82)"
printf '  0x0050 (前 4 字节) = %s\n' "$(raw 0x50 4)"

echo
echo "########## 1. 写标记 DE AD BE EF 到 0x0050 ##########"
i2ctransfer -f -y "$I2C_BUS" "w6@${ADDR}" 0x00 0x50 0xde 0xad 0xbe 0xef || die "写 0x0050 失败"
sleep 0.05
marker=$(raw 0x50 4)
printf '  读回 = %s\n' "$marker"
[[ "$marker" == "0xde 0xad 0xbe 0xef" ]] || die "标记没写进去（写路径异常），测试无效"

echo
echo "########## 2. gpio$PIN_B 拉低，看 Vin 是否变化 ##########"
gpio_set "$PIN_B" 0
sleep 0.3
printf '  gpio%s=0 ->  Vin=%s  Vrect=%s  MODE=%s\n' "$PIN_B" "$(mv 0x80)" "$(mv 0x82)" "$(h8 0x4d)"
gpio_set "$PIN_B" 1
sleep 0.2
printf '  gpio%s=1 ->  Vin=%s  Vrect=%s  MODE=%s\n' "$PIN_B" "$(mv 0x80)" "$(mv 0x82)" "$(h8 0x4d)"

echo
echo "########## 3. 关键：gpio$PIN_A 低 600ms 再拉高，然后读回标记 ##########"
echo "  (期间芯片可能从 I2C 消失，属正常)"
gpio_set "$PIN_A" 0
sleep 0.6
printf '  低电平期间 CHIP_ID = %s\n' "$(raw 0x00 2)"
gpio_set "$PIN_A" 1
sleep 0.5

printf '  CHIP_ID=%s  MODE=%s  TX_STAT=%s\n' "$(raw 0x00 2)" "$(h8 0x4d)" "$(h8 0x7e)"
printf '  Vin=%s  Vrect=%s\n' "$(mv 0x80)" "$(mv 0x82)"
marker2=$(raw 0x50 4)
printf '  标记 0x0050 读回 = %s\n' "$marker2"

echo
echo "=============================================================="
if [[ "$marker2" == "0xde 0xad 0xbe 0xef" ]]; then
    cat <<EOF
 判定：**gpio$PIN_A 不是芯片电源**（标记存活，芯片没有复位/掉电）。
       现象"拉低后 I2C 消失"只能说明它是**总线开关 / I2C 通路使能**。
       => 芯片自开机以来从未真正掉电过，VOUT 一直是 64 开机固件留下的状态，
          "VOUT 上电时 GP2 已高"这个自动使能条件从未被满足。
          我们此前所有"断电重启"实验都不是真正的上电事件。
EOF
else
    cat <<EOF
 判定：**gpio$PIN_A 是芯片电源**（标记丢失，芯片复位过；读回 = $marker2）。
       => 我们的低->高确实制造了真正的上电事件，但芯片仍不进 TRx。
          那么自动使能路径本身在这块板上不通，只能靠 0x007C 软命令，
          而软命令被忽略 -> 需要另找原因（GP2 电平 / 固件侧配置）。
EOF
fi
echo "=============================================================="
