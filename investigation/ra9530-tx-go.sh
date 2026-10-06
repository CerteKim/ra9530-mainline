#!/usr/bin/env bash
#
# ra9530-tx-go.sh — 完整走一遍 Renesas 指南的开 Tx 流程。
#
# 上一轮的关键发现：慢速扫描里 "两脚都低 -> gpio11 高 -> 50ms -> gpio186 高"
# 之后出现了：
#     IRQ(0x0030) = 0x00002080   (bit7 = TX Initialization Done, bit13 = Proprietary Packet Received)
#     INT 脚 (gpio101) 拉低
# 也就是说芯片确实完成了 Tx 初始化 —— 但当时脚本没有接着 "清中断 + 写 TX EN"，
# 中断一直挂着，芯片因此在中断未清的状态下不接受新命令
# （这解释了之前单独写 0x7C 为何完全无效）。
#
# 本脚本按指南 5.1.1 + 5.4.1 的完整顺序来：
#   1) 触发时序进入 Tx 初始化
#   2) 等到 TX Initialization Done 中断
#   3) 读 0x0030 得 m -> 把 m 写回 0x0028 -> 写 0x0002 到 0x007C (Clear Interrupt)
#   4) 校验 0x0030 == 0 且 INT 脚回到高
#   5) 写 0x0001 到 0x007C (TX EN)
#   6) 等 100ms -> 读 0x004D，0x04 = TRx 已使能
#
# 用法: sudo ./ra9530-tx-go.sh

set -u

ADDR=0x3b
I2C_BUS=""
GPIO_CHIP="gpiochip3"
PIN_A=11
PIN_B=186
IRQ_PIN=101
TLMM_BASE=""

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

# ---------------------------------------------------------------- I2C
raw() { i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 "$1" "r$2" 2>&1; }
r32() { local a b c d; read -r a b c d <<<"$(raw "$1" 4)"
        [[ "$a" == 0x* && "$b" == 0x* && "$c" == 0x* && "$d" == 0x* ]] \
          && printf '%d' $(( d<<24 | c<<16 | b<<8 | a )) || printf 'ERR'; }
h8()  { local o; o=$(raw "$1" 1); [[ "$o" == 0x* ]] && printf '0x%02X' "$o" || printf 'FAIL'; }
w16() { i2ctransfer -f -y "$I2C_BUS" "w4@${ADDR}" 0x00 "$1" \
        "$(printf '0x%02x' $(( ($2)      & 0xff )))" \
        "$(printf '0x%02x' $(( ($2 >> 8) & 0xff )))"; }

irq_name() {
    case "$1" in
        0)  echo "EPT Type (错误)";;
        1)  echo "Start Digital Ping";;
        2)  echo "Signal Strength Packet";;
        3)  echo "Identification Packet Received";;
        4)  echo "Configuration Packet Received";;
        5)  echo "Operation Mode Change";;
        6)  echo "TX Conflict";;
        7)  echo "*** TX Initialization Done ***";;
        8)  echo "BLE Address Received";;
        13) echo "Proprietary Packet Received";;
        14) echo "EPT Restart Received";;
        15) echo "CSP Packet Received (笔的电量)";;
        16) echo "Pen Authentication packet Received";;
        17) echo "Pen Authentication Pass";;
        *)  echo "reserved";;
    esac
}

show_irq() {
    local v b
    v=$(r32 0x30)
    if [[ "$v" == ERR ]]; then echo "  IRQ: 读失败"; return 1; fi
    printf '  IRQ (0x0030) = 0x%08X\n' "$v"
    [[ "$v" -eq 0 ]] && { echo "    (无 pending 中断)"; return 1; }
    for b in 0 1 2 3 4 5 6 7 8 13 14 15 16 17; do
        (( (v >> b) & 1 )) && printf '    bit%-2d %s\n' "$b" "$(irq_name "$b")"
    done
    return 0
}

irq_bits() { local v; v=$(r32 0x30); [[ "$v" == ERR ]] && echo ERR || printf '%d' "$v"; }

# ---------------------------------------------------------------- GPIO
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
    printf '\n[cleanup] gpio%s=%s gpio%s=%s  INT脚=%s\n' \
        "$PIN_A" "$(gpio_get "$PIN_A")" "$PIN_B" "$(gpio_get "$PIN_B")" "$(irq_line)"
    local o; for o in "$PIN_A" "$PIN_B"; do
        echo "$(( TLMM_BASE + o ))" > /sys/class/gpio/unexport 2>/dev/null
    done
    exit $rc
}
trap restore EXIT INT TERM

# ---------------------------------------------------------------- 触发时序
trigger() {
    echo "  时序: 两脚都低 0.5s -> gpio$PIN_A 高 -> 50ms -> gpio$PIN_B 高"
    gpio_set "$PIN_A" 0; gpio_set "$PIN_B" 0
    sleep 0.5
    gpio_set "$PIN_A" 1; sleep 0.05
    gpio_set "$PIN_B" 1
}

wait_irq() {   # 最多等 $1 秒
    local t v
    for ((t = 1; t <= $1; t++)); do
        v=$(irq_bits)
        if [[ "$v" != ERR && "$v" != "0" ]]; then
            printf '  t=%ds 出现中断: 0x%08X\n' "$t" "$v"
            return 0
        fi
        sleep 1
    done
    return 1
}

echo "=============================================================="
echo " RA9530 完整开 Tx 流程（i2c-$I2C_BUS）"
echo " 笔请吸在机身上；注意机身温度"
echo "=============================================================="
gpio_prep "$PIN_A"; gpio_prep "$PIN_B"

echo
echo "########## 0. 当前状态 ##########"
printf '  MODE=%s  TX_STAT=%s  INT脚=%s\n' "$(h8 0x4d)" "$(h8 0x7e)" "$(irq_line)"
show_irq || true

# ---------------------------------------------------------------- 1. 触发 + 等中断
echo
echo "########## 1. 触发 Tx 初始化 ##########"
trigger
if ! wait_irq 10; then
    echo "  第一次没等到中断，再试一次..."
    trigger
    wait_irq 10 || die "触发后仍无中断（芯片没进 Tx 初始化）"
fi

echo
echo "--- 中断详情 ---"
show_irq || true
printf '  INT 脚 = %s\n' "$(irq_line)"
printf '  MODE=%s  TX_STAT=%s\n' "$(h8 0x4d)" "$(h8 0x7e)"

echo
echo "  顺便看看私有包(0x0058, 8 字节): $(raw 0x58 8)"

# ---------------------------------------------------------------- 2. 清中断
echo
echo "########## 2. 清中断（指南 5.1.1：把读到的 m 原样写回 0x0028，再写 0x02 到 0x007C） ##########"
mval=$(r32 0x30)
if [[ "$mval" == ERR || "$mval" == "0" ]]; then
    echo "  (无需清理)"
else
    # 小端拆字节
    b0=$(printf '0x%02x' $((  mval        & 0xff )))
    b1=$(printf '0x%02x' $(( (mval >> 8)  & 0xff )))
    b2=$(printf '0x%02x' $(( (mval >> 16) & 0xff )))
    b3=$(printf '0x%02x' $(( (mval >> 24) & 0xff )))
    echo "  写 $b0 $b1 $b2 $b3 到 0x0028 ..."
    i2ctransfer -f -y "$I2C_BUS" "w6@${ADDR}" 0x00 0x28 "$b0" "$b1" "$b2" "$b3" || die "写 0x0028 失败"
    sleep 0.05
    echo "  写 0x007C = 0x0002 (Clear Interrupt) ..."
    w16 0x7c 0x0002 || die "写 0x007C CLR 失败"
    sleep 0.05
fi
echo "--- 清理后 ---"
show_irq || true
printf '  INT 脚 = %s\n' "$(irq_line)"

# ---------------------------------------------------------------- 3. 写 TX EN
echo
echo "########## 3. 写 TX EN (0x007C = 0x0001) ##########"
sleep 0.05
w16 0x7c 0x0001 || die "写 TX EN 失败"
echo "  已写，等待 300ms ..."
sleep 0.3

echo "--- 写 TX EN 之后 ---"
echo "  寄存器全景："
printf '    CHIP_ID  = %s\n' "$(raw 0x00 2)"
printf '    MODE     = %s   <-- 0x04 才是 TRx 已使能\n' "$(h8 0x4d)"
printf '    TX_STAT  = %s\n' "$(h8 0x7e)"
printf '    EPT      = %s\n' "$(raw 0x7a 2)"
printf '    Vin      = %s\n' "$(raw 0x80 2)"
printf '    BATT     = %s\n' "$(h8 0x3a)"
show_irq || true
printf '    INT 脚   = %s\n' "$(irq_line)"

echo
if [[ "$(h8 0x4d)" == "0x04" ]]; then
    cat <<'EOF'
==============================================================
 *** 成功!!! MODE = 0x04，TRx 正在发射 ***
 现在检查笔是否开始充电（笔身指示 / 机身温度）。
 按 Enter 结束观测（退出时会把两根脚恢复 high）。
==============================================================
EOF
    read -r _ </dev/tty
else
    cat <<'EOF'
还没到 0x04。看上面的中断位与 EPT：
  - 若 0x0030 仍有 pending 位 -> 清中断可能没生效，需要把清中断流程再走一遍
  - 若出现 bit0(EPT Type) -> 读 0x007A 看具体错误
  - 若 TX_STAT bit1 (TX ready) 变 1 -> 芯片已 ready，再写一次 TX EN
EOF
fi
echo
echo "结束。"
