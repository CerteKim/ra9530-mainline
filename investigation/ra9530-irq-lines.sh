#!/usr/bin/env bash
#
# ra9530-irq-lines.sh — 搞清 SXB 那三根"中断"脚到底是什么
#
# 背景：
#   DSDT 里 SXB 设备有 3 个 GpioInt：101 (Level/ActiveLow)、189 (Edge/ActiveLow)、97 (Edge/ActiveLow)。
#   但 Renesas 只定义了 1 条 IC 中断（OD2/nINT，开漏低有效）—— 也就是 101。
#   那 189 和 97 必然是板上别的信号（笔吸附检测？升压 PG？开关故障？）。
#   实测：101=高(空闲)  189=高  97=低  <-- 97 一直低，很可疑
#
# 本脚本做两件事：
#   A) 叫你拔下/贴上触控笔，看这三根脚有没有跟着变 —— 找出"吸附检测"是哪根、极性如何，
#      以及【笔到底有没有被检测到】
#   B) 切换 gpio11(开关) / gpio186(7V升压)，看这三根脚的反应 —— 找出哪根是升压 PG/故障
#
# 用法: sudo ./ra9530-irq-lines.sh

set -u

ADDR=0x3b
I2C_BUS=""
GPIO_CHIP="gpiochip3"
PIN_EN=11
PIN_BOOST=186
LINES="101 189 97"
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

rd()  { i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 "$1" "r$2" 2>&1; }
gpio_path() { echo "/sys/class/gpio/gpio$(( TLMM_BASE + $1 ))"; }
gpio_prep() {
    local p; p=$(gpio_path "$1")
    [[ -d "$p" ]] || { echo "$(( TLMM_BASE + $1 ))" > /sys/class/gpio/export 2>/dev/null; sleep 0.05; }
    echo high > "$p/direction" 2>/dev/null
}
gpio_set() { echo "$2" > "$(gpio_path "$1")/value" || die "写 gpio$1=$2 失败"; }
gpio_get() { cat "$(gpio_path "$1")/value" 2>/dev/null || echo "?"; }
lvl() { gpioget --as-is --numeric -c "$GPIO_CHIP" "$1" 2>/dev/null | tr -dc '01' | tail -c1; }

snapshot() {  # 打印三根脚 + MODE
    printf '    101=%s  189=%s  97=%s   |  MODE=%s\n' \
        "$(lvl 101)" "$(lvl 189)" "$(lvl 97)" "$(rd 0x4d 1)"
}

restore() {
    local rc=$?
    gpio_prep "$PIN_EN"; gpio_prep "$PIN_BOOST"; sleep 0.05
    printf '\n[cleanup] gpio%s=%s gpio%s=%s\n' \
        "$PIN_EN" "$(gpio_get "$PIN_EN")" "$PIN_BOOST" "$(gpio_get "$PIN_BOOST")"
    local o; for o in "$PIN_EN" "$PIN_BOOST"; do
        echo "$(( TLMM_BASE + o ))" > /sys/class/gpio/unexport 2>/dev/null
    done
    exit $rc
}
trap restore EXIT INT TERM

watch() {   # $1=说明 $2=秒数
    local t prev="" cur
    printf '\n--- %s（观察 %ds，只在变化时打印）---\n' "$1" "$2"
    for ((t = 1; t <= $2; t++)); do
        cur="101=$(lvl 101) 189=$(lvl 189) 97=$(lvl 97) MODE=$(rd 0x4d 1)"
        if [[ "$cur" != "$prev" ]]; then
            printf '  t=%2ds  %s\n' "$t" "$cur"
            prev=$cur
        fi
        sleep 1
    done
    [[ -z "$prev" ]] || true
}

echo "=============================================================="
echo " RA9530 三根中断脚定位 (i2c-$I2C_BUS)"
echo "   DSDT: 101=GpioInt(Level,Low) 189=GpioInt(Edge,Low) 97=GpioInt(Edge,Low)"
echo "=============================================================="
gpio_prep "$PIN_EN"; gpio_prep "$PIN_BOOST"

echo
echo "########## 当前状态 ##########"
snapshot

echo
echo "########## A. 笔吸附检测 ##########"
echo "  请【把触控笔从机身上拿开】，保持拿开"
read -r -p "  拿开后按 Enter 开始观察..." _ </dev/tty || true
watch "笔已拿开" 10
echo
echo "  现在请【把触控笔贴回机身】"
read -r -p "  贴回后按 Enter 开始观察..." _ </dev/tty || true
watch "笔已贴回" 10

echo
echo "########## B. 开关 / 升压 对这三根脚的影响 ##########"
echo "  (先确保两脚都高)"
gpio_set "$PIN_EN" 1; gpio_set "$PIN_BOOST" 1; sleep 0.3
snapshot

echo
echo "  -> 关掉 7V 升压 (gpio$PIN_BOOST=0)"
gpio_set "$PIN_BOOST" 0; sleep 0.4
snapshot
echo "  -> 打开 7V 升压 (gpio$PIN_BOOST=1)"
gpio_set "$PIN_BOOST" 1; sleep 0.4
snapshot

echo
echo "  -> 关掉开关 (gpio$PIN_EN=0)  [芯片会消失，MODE 读不到]"
gpio_set "$PIN_EN" 0; sleep 0.5
printf '    101=%s  189=%s  97=%s\n' "$(lvl 101)" "$(lvl 189)" "$(lvl 97)"
echo "  -> 打开开关 (gpio$PIN_EN=1)"
gpio_set "$PIN_EN" 1; sleep 0.5
snapshot

echo
echo "=============================================================="
echo " 怎么读："
echo "  * 若拔/贴笔时某根脚翻转 -> 那就是【吸附检测】，其电平/边沿告诉我们笔是否被检测到"
echo "  * 若关升压时某根脚翻转   -> 那是【升压 PG 或故障】信号"
echo "  * 若三根脚全程纹丝不动   -> 它们与吸附/升压都无关（或笔根本没被检测）"
echo "=============================================================="
