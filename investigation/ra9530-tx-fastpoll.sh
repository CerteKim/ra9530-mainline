#!/usr/bin/env bash
#
# ra9530-tx-fastpoll.sh — 毫秒级轮询，抓 Tx 是否"启动过又退回去"
#
# 线索：
#   * gpio11 = IC 使能/电源（写标记法已证实：拉低后标记丢失=芯片复位）
#   * gpio186 = 7V 升压使能（实测 Vin 3793mV <-> 6998mV）
#   * 标准上电顺序 = 两脚低 -> gpio11 高 -> 50ms -> gpio186 高（正是指南 5.4.1 第 1 步）
#   * 该顺序之后会出现 IRQ bit7 (TX Initialization Done) + bit13 (Proprietary Packet Received)
#     bit13 说明线圈被驱动过、笔回话了 => Tx 很可能短暂启动后超时/FOD 退回
#   * 之前每次都在 300ms 后才读 MODE，可能正好错过那个窗口
#
# 本脚本：上电 -> 100ms 后写 TX EN -> 之后以 20ms 间隔连续读 MODE/TX_STAT 共数秒，
#         一旦发现离开 0x80 立刻记录；一旦从 0x04 退回，立刻读 EPT(0x007A) 与 IRQ(0x0030)。
#
# 注意：轮询期间【不读 0x0030】，避免万一它是 read-to-clear 把中断吃掉。
#
# 用法: sudo ./ra9530-tx-fastpoll.sh

set -u

ADDR=0x3b
I2C_BUS=""
GPIO_CHIP="gpiochip3"
PIN_EN=11        # Switch IC / IC 使能
PIN_BOOST=186    # 7V 升压使能
IRQ_PIN=101
TLMM_BASE=""
POLL_MS=${POLL_MS:-20}
DURATION_MS=${DURATION_MS:-5000}
TXEN_AT_MS=${TXEN_AT_MS:-100}

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

# 快速单字节读（不做格式校验，尽量省时间）
rd() { i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 "$1" "r1" 2>/dev/null; }
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

ms() {  # 毫秒级 sleep（纯 bash 格式化，避免每次 fork awk）
    sleep "$(printf '%d.%03d' $(( $1 / 1000 )) $(( $1 % 1000 )))"
}

dump_full() {
    echo "    寄存器全景:"
    echo "      MODE     = $(rd 0x4d)"
    echo "      TX_STAT  = $(rd 0x7e)"
    echo "      EPT      = $(i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 0x7a r2 2>/dev/null)"
    echo "      IRQ      = $(i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 0x30 r4 2>/dev/null)"
    echo "      BATT     = $(rd 0x3a)"
    echo "      PropData = $(i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 0x58 r8 2>/dev/null)"
    echo "      Vin      = $(i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 0x80 r2 2>/dev/null)"
    echo "      INT脚    = $(gpioget --as-is --numeric -c "$GPIO_CHIP" "$IRQ_PIN" 2>/dev/null | tr -dc '01' | tail -c1)"
}

echo "=============================================================="
echo " RA9530 毫秒级轮询抓 Tx 窗口"
echo "  gpio$PIN_EN=Switch/使能  gpio$PIN_BOOST=7V升压"
echo "  轮询 ${POLL_MS}ms x ${DURATION_MS}ms，TX EN 在 ${TXEN_AT_MS}ms 写入"
echo "=============================================================="
gpio_prep "$PIN_EN"; gpio_prep "$PIN_BOOST"

echo
echo "########## 上电时序（指南 5.4.1 第 1 步）##########"
echo "  两脚低 500ms -> gpio$PIN_EN 高 -> 50ms -> gpio$PIN_BOOST 高"
gpio_set "$PIN_EN" 0; gpio_set "$PIN_BOOST" 0
ms 500
gpio_set "$PIN_EN" 1
ms 50
gpio_set "$PIN_BOOST" 1
echo "  上电完成，Vin 应为 ~7000mV，当前 = $(i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 0x80 r2 2>/dev/null)"

echo
echo "########## 开始轮询 ##########"
t=0
prev_mode=""; prev_stat=""
txen_done=0; saw04=0; tx_start=0
while [[ $t -le $DURATION_MS ]]; do
    mode=$(rd 0x4d)
    stat=$(rd 0x7e)
    if [[ -n "$mode" && ( "$mode" != "$prev_mode" || "$stat" != "$prev_stat" ) ]]; then
        printf '  t=%4dms  MODE=%s  TX_STAT=%s\n' "$t" "$mode" "$stat"
        prev_mode=$mode; prev_stat=$stat
        if [[ "$mode" == "0x04" ]]; then
            saw04=1; tx_start=$t
            echo "    *** MODE = 0x04：TRx 启动了！***"
        elif [[ $saw04 -eq 1 && "$mode" != "0x04" ]]; then
            echo "    *** 从 0x04 退回 $mode（t=$t，持续约 $((t - tx_start))ms）—— 立即抓现场： ***"
            dump_full
            saw04=2
        fi
    fi
    if [[ $txen_done -eq 0 && $t -ge $TXEN_AT_MS ]]; then
        printf '  t=%4dms  写 TX EN (0x007C=0x0001)\n' "$t"
        w16 0x7c 0x0001
        txen_done=1
    fi
    ms "$POLL_MS"
    t=$((t + POLL_MS))
done

echo
echo "########## 轮询结束，最终状态 ##########"
dump_full

echo
echo "=============================================================="
if [[ $saw04 -eq 2 ]]; then
    echo " 结论：Tx **确实启动过又退回了**。上面 'EPT' 与 'IRQ' 就是退回的原因。"
    echo "       EPT 位含义: bit15 POCP bit14 OTP bit13 FOD bit12 LVP bit11 OVP"
    echo "                   bit10 OCP bit9 RPP超时 bit8 CEP超时 bit7 看门狗"
    echo "                   bit6 NOI2C超时 bit5 TX冲突 bit4 ping电压 bit0 EPT CMD"
elif [[ $saw04 -eq 1 ]]; then
    echo " 结论：Tx 已启动并**保持**在 0x04 —— 应该正在充电！"
else
    echo " 结论：轮询期间 MODE 从未离开 0x80。Tx 没有启动（不是「启动后回退」）。"
    echo "       那么 TX EN 确实被忽略；剩下最可能的就是 GP2/TX_EN 引脚为低（板上未上拉），"
    echo "       或芯片客户固件不允许该路径 —— 需要在 Windows 侧做对照实验确认。"
fi
echo "=============================================================="
