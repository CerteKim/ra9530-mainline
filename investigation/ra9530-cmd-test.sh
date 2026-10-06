#!/usr/bin/env bash
#
# ra9530-cmd-test.sh — 判别 0x007C 命令接口是否"活着"
#
# 依据：Tx System Command Register (0x007C) 的每一位都是
#       "AP writes 1 ... Chip clears the bit after processing the command."
#       也就是：只要芯片【处理】了命令，该位就会被自动清零。
#
# 判据：
#   写入某个命令位后读回：
#     读到 0x0000  -> 芯片处理并清除了该位（命令接口活）
#     读到 0x0001  -> 位一直挂着，芯片根本没处理
#
# 我们此前只测过 bit0 (TX EN)，它一直挂着。本脚本把 bit1/bit2/bit3/bit4 都试一遍：
#   bit0 = TX EN        开始 digital ping
#   bit1 = CLR Interrupt 清中断
#   bit2 = TX DIS       关闭 Tx
#   bit3 = TX BC        发送私有包
#   bit4 = TX WD        使能看门狗
#
# 结论解读：
#   * 只有 bit0 不自清除，其它位正常 -> 命令接口活着，**恰好 TX EN 被拒绝**
#     => 几乎可以确定是 GP2/TX_EN 引脚为低造成的门控
#   * 所有位都不自清除 -> 整个命令接口是死的
#     => Tx 通路被更底层禁用（客户固件 / GP2 常态为低），软命令路线不通
#
# 用法: sudo ./ra9530-cmd-test.sh

set -u

ADDR=0x3b
I2C_BUS=""
GPIO_CHIP="gpiochip3"
PIN_EN=11
PIN_BOOST=186
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
w16() { i2ctransfer -f -y "$I2C_BUS" "w4@${ADDR}" 0x00 "$1" \
        "$(printf '0x%02x' $(( ($2)      & 0xff )))" \
        "$(printf '0x%02x' $(( ($2 >> 8) & 0xff )))"; }
ms()  { sleep "$(printf '%d.%03d' $(( $1 / 1000 )) $(( $1 % 1000 )))"; }

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

cmd_bit_name() {
    case "$1" in
        0) echo "TX EN        (开始 digital ping)";;
        1) echo "CLR Interrupt(清中断)";;
        2) echo "TX DIS       (关闭 Tx)";;
        3) echo "TX BC        (发送私有包)";;
        4) echo "TX WD        (使能看门狗)";;
    esac
}

echo "=============================================================="
echo " RA9530 命令接口活性测试 (i2c-$I2C_BUS)  —— 0x007C 是否自清除"
echo "=============================================================="
gpio_prep "$PIN_EN"; gpio_prep "$PIN_BOOST"

echo
echo "########## 上电时序（Switch -> Boost）##########"
gpio_set "$PIN_EN" 0; gpio_set "$PIN_BOOST" 0
ms 500
gpio_set "$PIN_EN" 1; ms 50
gpio_set "$PIN_BOOST" 1; ms 200
printf '  Vin = %s   MODE = %s   TX_STAT = %s\n' "$(rd 0x80 2)" "$(rd 0x4d 1)" "$(rd 0x7e 1)"

alive=0; dead=0
echo
echo "########## 逐位测试 0x007C ##########"
for bit in 0 1 2 3 4; do
    v=$(( 1 << bit ))
    printf '\n--- bit%d = 0x%04X  %s ---\n' "$bit" "$v" "$(cmd_bit_name "$bit")"
    # 每个用例前先确保命令寄存器是空的
    if [[ "$(rd 0x7c 2)" != "0x00 0x00" ]]; then
        echo "  (命令寄存器残留，先写 0 清掉)"
        w16 0x7c 0x0000 2>/dev/null
        ms 20
    fi
    w16 0x7c "$v" || { echo "  写失败"; continue; }
    printf '  立刻读回 0x007C = %s\n' "$(rd 0x7c 2)"
    ms 20;  printf '  +20ms  = %s\n' "$(rd 0x7c 2)"
    ms 80;  printf '  +100ms = %s\n' "$(rd 0x7c 2)"
    after=$(rd 0x7c 2)
    if [[ "$after" == "0x00 0x00" ]]; then
        echo "  => 已被芯片清除：命令接口对这个位是【活的】"
        alive=$((alive + 1))
    else
        echo "  => 位一直挂着：芯片【没有处理】这个命令"
        dead=$((dead + 1))
    fi
    printf '  MODE=%s  TX_STAT=%s  EPT=%s\n' "$(rd 0x4d 1)" "$(rd 0x7e 1)" "$(rd 0x7a 2)"
    ms 20
done

echo
echo "########## 汇总 ##########"
printf '  被清除的命令位: %d 个    一直挂着的: %d 个\n' "$alive" "$dead"
echo
if [[ $dead -eq 0 ]]; then
    echo " 结论：命令接口完全正常（所有位都会被处理）。"
elif [[ "$(rd 0x7c 2)" == "0x00 0x00" || $alive -gt 0 ]]; then
    echo " 结论：命令接口【部分活着】—— 有些命令被处理，有些被忽略。"
    echo "       如果只有 bit0 (TX EN) 被忽略，那基本就是 GP2/TX_EN 引脚为低造成的门控。"
else
    echo " 结论：命令接口【完全没反应】—— 整个 0x007C 都没被处理。"
    echo "       说明芯片的 Tx 通路被更底层地禁用（客户固件配置 / GP2 常态为低），"
    echo "       单纯靠 I2C 软命令无法打开 Tx。"
fi
echo
echo "备注：bit0(TX EN) 之前多次测试都是写了不清，本次结果可与之对照。"
