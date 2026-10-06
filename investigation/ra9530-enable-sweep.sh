#!/usr/bin/env bash
#
# ra9530-enable-sweep.sh — 枚举 gpio11 / gpio186 的时序组合，盯 TX ready 位。
#
# 为什么还要试：
#   1. 手册说 TRx 自动使能的条件是「VOUT 上电时 GP2/TX_EN 为高」。这是【边沿事件】，
#      不是电平。之前只试过「gpio186 高 + gpio11 断电重启」和「gpio186 单独升降沿」，
#      从没试过 **gpio186 低 + gpio11 断电重启**（如果板上 GP2 是反相的，这才是对的）。
#   2. 两个引脚的先后顺序也没穷尽。
#
# 判据：读 System Operating Mode(0x004D) 与 TX Status(0x007E)。
#       MODE == 0x04 = TRx 已使能（笔应开始充电）。
#
# 安全：两根脚都在 SXB 设备的资源列表里（注册表 LogConf 已确认 2 个 GpioIo），
#       全部操作可逆；脚本退出时一律恢复成 high（开机固件留下的状态）。
#
# 用法: sudo ./ra9530-enable-sweep.sh
#       sudo ./ra9530-enable-sweep.sh --quick   # 只跑最可能的两组

set -u

ADDR=0x3b
I2C_BUS=""
GPIO_CHIP="gpiochip3"
PIN_A=11         # 供电/使能（拉低会让芯片从 I2C 消失）
PIN_B=186        # 角色未知
IRQ_PIN=101
TLMM_BASE=""

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

die() { printf '\n!! %s\n' "$*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die "需要 root: sudo $0"
command -v i2ctransfer >/dev/null || die "缺 i2ctransfer"

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
r8()  { local o; o=$(raw "$1" 1); [[ "$o" == 0x* ]] && printf '%d' "$o" || printf 'ERR'; }
h8()  { local v; v=$(r8 "$1"); [[ "$v" == ERR ]] && printf 'READ-FAIL' || printf '0x%02X' "$v"; }
w16() { i2ctransfer -f -y "$I2C_BUS" "w4@${ADDR}" 0x00 "$1" \
        "$(printf '0x%02x' $(( ($2)      & 0xff )))" \
        "$(printf '0x%02x' $(( ($2 >> 8) & 0xff )))"; }

gpio_path() { echo "/sys/class/gpio/gpio$(( TLMM_BASE + $1 ))"; }
gpio_prep() {
    local p; p=$(gpio_path "$1")
    [[ -d "$p" ]] || { echo "$(( TLMM_BASE + $1 ))" > /sys/class/gpio/export 2>/dev/null; sleep 0.05; }
    echo high > "$p/direction" 2>/dev/null   # high 避免 direction=out 的拉低毛刺
}
gpio_set() { echo "$2" > "$(gpio_path "$1")/value" || die "写 gpio$1=$2 失败"; }
gpio_get() { cat "$(gpio_path "$1")/value" 2>/dev/null || echo "?"; }

restore() {
    local rc=$?
    gpio_prep "$PIN_A"; gpio_prep "$PIN_B"
    sleep 0.05
    printf '\n[cleanup] gpio%s=%s gpio%s=%s (恢复 high)\n' \
        "$PIN_A" "$(gpio_get "$PIN_A")" "$PIN_B" "$(gpio_get "$PIN_B")"
    local o; for o in "$PIN_A" "$PIN_B"; do
        echo "$(( TLMM_BASE + o ))" > /sys/class/gpio/unexport 2>/dev/null
    done
    exit $rc
}
trap restore EXIT INT TERM

state() {
    local m s
    m=$(h8 0x4d); s=$(h8 0x7e)
    printf '     MODE=%s  TX_STAT=%s  IRQ=%s\n' "$m" "$s" "$(raw 0x30 4)"
    if [[ "$m" == "0x04" ]]; then
        echo "     *** MODE = 0x04，TRx 已使能！ ***"
        return 0
    fi
    return 1
}

found=0

run_case() {   # $1=描述  $2=函数名
    echo
    echo "=============================================================="
    echo " 用例: $1"
    echo "=============================================================="
    gpio_prep "$PIN_A"; gpio_prep "$PIN_B"
    "$2"
    sleep 0.3
    if state; then
        found=1
        echo
        echo ">>> 命中！再写一次 TX EN 确认："
        w16 0x7c 0x0001
        sleep 0.3
        state || true
        echo
        read -r -p "按 Enter 结束观测（会把两根脚恢复 high）..." _ </dev/tty || true
        return 1     # 让调用方停止
    fi
    # 本用例结束，恢复到 high
    gpio_set "$PIN_A" 1; gpio_set "$PIN_B" 1
    sleep 0.1
    return 0
}

# --- 用例定义（trap 会在退出时统一恢复）---

case_gp2_low_vout_cycle() {
    echo "  gpio$PIN_B=0（若板上 GP2 反相，这才是“TX_EN 有效”态）"
    gpio_set "$PIN_B" 0
    sleep 0.2
    echo "  然后 gpio$PIN_A: 1 -> 0 (600ms，让 7V 轨真正掉电) -> 1"
    gpio_set "$PIN_A" 0
    sleep 0.6
    gpio_set "$PIN_A" 1
    sleep 0.5
}

case_pin_b_edge_only() {
    echo "  gpio$PIN_B: 1 -> 0 (600ms) -> 1"
    gpio_set "$PIN_B" 0; sleep 0.6; gpio_set "$PIN_B" 1; sleep 0.5
}

case_gp2_high_vout_cycle() {
    echo "  gpio$PIN_B=1，gpio$PIN_A: 1 -> 0 (600ms) -> 1"
    gpio_set "$PIN_B" 1
    gpio_set "$PIN_A" 0; sleep 0.6; gpio_set "$PIN_A" 1; sleep 0.5
}

case_vout_then_txen() {
    echo "  gpio$PIN_B=0；gpio$PIN_A 断电重启后，再把 gpio$PIN_B 拉高"
    gpio_set "$PIN_B" 0
    gpio_set "$PIN_A" 0; sleep 0.6; gpio_set "$PIN_A" 1
    sleep 0.3
    gpio_set "$PIN_B" 1
    sleep 0.5
}

case_both_low_then_txen_first() {
    echo "  两根都拉低 600ms -> 先 gpio$PIN_B=1 -> 50ms -> gpio$PIN_A=1"
    gpio_set "$PIN_A" 0; gpio_set "$PIN_B" 0
    sleep 0.6
    gpio_set "$PIN_B" 1; sleep 0.05; gpio_set "$PIN_A" 1
    sleep 0.5
}

case_both_low_then_vout_first() {
    echo "  两根都拉低 600ms -> 先 gpio$PIN_A=1 -> 50ms -> gpio$PIN_B=1"
    gpio_set "$PIN_A" 0; gpio_set "$PIN_B" 0
    sleep 0.6
    gpio_set "$PIN_A" 1; sleep 0.05; gpio_set "$PIN_B" 1
    sleep 0.5
}

echo "=============================================================="
echo " RA9530 使能时序枚举（i2c-$I2C_BUS，引脚 gpio$PIN_A / gpio$PIN_B）"
echo " 笔请吸在机身上；留意机身温度"
echo "=============================================================="
gpio_prep "$PIN_A"; gpio_prep "$PIN_B"
echo
echo "起始状态："; state || true

if [[ $QUICK -eq 1 ]]; then
    run_case "gpio${PIN_B} 低 + gpio${PIN_A} 断电重启" case_gp2_low_vout_cycle || true
    [[ $found -eq 0 ]] && { run_case "gpio${PIN_B} 单独升降沿" case_pin_b_edge_only || true; }
else
    for c in gp2_low_vout_cycle pin_b_edge_only gp2_high_vout_cycle \
             vout_then_txen both_low_then_txen_first both_low_then_vout_first; do
        [[ $found -eq 1 ]] && break
        run_case "$c" "case_$c" || true
    done
fi

echo
if [[ $found -eq 1 ]]; then
    echo "结论：找到了能进 TRx 的时序（见上方命中的用例）。"
else
    echo "结论：以上时序都无法让 MODE 变成 0x04。"
    echo "      说明 Tx 使能不在这两根 AP GPIO 的时序里 —— 需要 DSDT 看"
    echo "      SXB 设备引用的 PowerResource / _ON 方法，以及 Resource Hub 的作用。"
fi
