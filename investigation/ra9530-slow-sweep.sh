#!/usr/bin/env bash
#
# ra9530-slow-sweep.sh — 慢速版：每个状态保持十几秒，并每秒轮询一次寄存器。
#
# 为什么重做：
#   厂商 Windows 驱动的寄存器足迹（0x28/0x30/0x34/0x3A/0x4D/0x50/0x58）表明它
#   **只做监控与通信，从不写 0x7C（TX EN）**。也就是说 Windows 下打开 Tx 的是
#   **固件/EC 自己**。若真如此，它的响应可能是【秒级】（EC 轮询周期），
#   而之前所有实验每组只等 300–600ms，很可能全都读得太早。
#
# 本脚本：对每个状态保持 15 秒，每秒读一次 MODE / TX_STAT，任何变化立刻打印。
#
# 用法: sudo ./ra9530-slow-sweep.sh

set -u

ADDR=0x3b
I2C_BUS=""
GPIO_CHIP="gpiochip3"
PIN_A=11
PIN_B=186
IRQ_PIN=101
TLMM_BASE=""
HOLD=${HOLD:-15}          # 每个状态保持多少秒，可用 HOLD=30 加长

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
w16() { i2ctransfer -f -y "$I2C_BUS" "w4@${ADDR}" 0x00 "$1" \
        "$(printf '0x%02x' $(( ($2)      & 0xff )))" \
        "$(printf '0x%02x' $(( ($2 >> 8) & 0xff )))"; }

gpio_path() { echo "/sys/class/gpio/gpio$(( TLMM_BASE + $1 ))"; }
gpio_prep() {
    local p; p=$(gpio_path "$1")
    [[ -d "$p" ]] || { echo "$(( TLMM_BASE + $1 ))" > /sys/class/gpio/export 2>/dev/null; sleep 0.05; }
    echo high > "$p/direction" 2>/dev/null
}
gpio_set() { echo "$2" > "$(gpio_path "$1")/value" || die "写 gpio$1=$2 失败"; }
gpio_get() { cat "$(gpio_path "$1")/value" 2>/dev/null || echo "?"; }
irq_line() { gpioget --as-is --numeric -c "$GPIO_CHIP" "$IRQ_PIN" 2>/dev/null | tr -dc '01' | tail -c1; }

restore() {
    local rc=$?
    gpio_prep "$PIN_A"; gpio_prep "$PIN_B"
    sleep 0.05
    printf '\n[cleanup] gpio%s=%s gpio%s=%s\n' "$PIN_A" "$(gpio_get "$PIN_A")" "$PIN_B" "$(gpio_get "$PIN_B")"
    local o; for o in "$PIN_A" "$PIN_B"; do
        echo "$(( TLMM_BASE + o ))" > /sys/class/gpio/unexport 2>/dev/null
    done
    exit $rc
}
trap restore EXIT INT TERM

# 保持某个状态 HOLD 秒，每秒轮询
watch() {   # $1=描述
    local t m s prev_m="" prev_s="" changed=0
    printf '\n--- 保持: %s（%d 秒，每秒轮询）---\n' "$1" "$HOLD"
    for ((t = 1; t <= HOLD; t++)); do
        m=$(h8 0x4d); s=$(h8 0x7e)
        if [[ "$m" != "$prev_m" || "$s" != "$prev_s" ]]; then
            printf '  t=%2ds  MODE=%s  TX_STAT=%s  IRQ=%s  gpio101=%s\n' \
                "$t" "$m" "$s" "$(raw 0x30 4)" "$(irq_line)"
            prev_m=$m; prev_s=$s; changed=1
        fi
        if [[ "$m" == "0x04" ]]; then
            echo
            echo "  *** MODE = 0x04 —— TRx 已使能！ ***"
            echo "  再写一次 TX EN 并观察："
            w16 0x7c 0x0001; sleep 1
            printf '  MODE=%s TX_STAT=%s\n' "$(h8 0x4d)" "$(h8 0x7e)"
            read -r -p "  按 Enter 结束（会恢复 GPIO）..." _ </dev/tty || true
            return 1
        fi
        sleep 1
    done
    [[ $changed -eq 0 ]] && printf '  （%d 秒内没有任何变化）\n' "$HOLD"
    return 0
}

echo "=============================================================="
echo " RA9530 慢速状态枚举（i2c-$I2C_BUS，每组保持 ${HOLD}s）"
echo " 请保持触控笔吸在机身上；注意机身温度"
echo "=============================================================="
gpio_prep "$PIN_A"; gpio_prep "$PIN_B"
printf '\n起始: MODE=%s TX_STAT=%s gpio%s=%s gpio%s=%s\n' \
    "$(h8 0x4d)" "$(h8 0x7e)" "$PIN_A" "$(gpio_get "$PIN_A")" "$PIN_B" "$(gpio_get "$PIN_B")"

ok=1
# 1) 只把 gpio186 拉低并久等（若它是给 EC/固件的“开始充电”请求，需要时间响应）
gpio_set "$PIN_B" 0
watch "gpio$PIN_B = 0（请求充电？）" || ok=0
# 2) 恢复 186，改把 gpio11 拉低久等
if [[ $ok -eq 1 ]]; then
    gpio_set "$PIN_B" 1; sleep 0.2
    gpio_set "$PIN_A" 0
    watch "gpio$PIN_A = 0" || ok=0
fi
# 3) 复位后两脚都高，长等（若固件需要“稳定态若干秒”才动作）
if [[ $ok -eq 1 ]]; then
    gpio_set "$PIN_A" 1; sleep 0.2
    watch "两脚都高（静止态）" || ok=0
fi
# 4) 两脚都低再都高，然后长等
if [[ $ok -eq 1 ]]; then
    gpio_set "$PIN_A" 0; gpio_set "$PIN_B" 0; sleep 0.5
    gpio_set "$PIN_A" 1; sleep 0.05; gpio_set "$PIN_B" 1
    watch "两脚低→高之后" || ok=0
fi

echo
if [[ $ok -eq 1 ]]; then
    echo "结论：即使给到秒级响应时间，这两根 AP GPIO 也无法让芯片离开 0x80。"
    echo "      基本可以确认：Tx 使能由固件/EC 掌控，而不是 AP（我们）能直接触发的。"
else
    echo "结论：命中了！见上方输出。"
fi
