#!/usr/bin/env bash
#
# ra9530-catch-ept.sh — 高速轮询，抢在中断消失前把 EPT 错误码读下来
#
# 为什么需要：
#   上一轮（ra9530-tx-go.sh）中断已经是 0x00002081 —— 多出了 bit0 = EPT Type（错误），
#   但脚本每秒才轮询一次 0x0030，等它再去读时中断已自行消失（0x007A 读到 0）。
#   而指南明确要求：一旦收到 EPT Type 中断，AP 必须【立刻】读 Tx EPT Type Register。
#
# 本脚本：
#   1) 走上电时序（两脚低 -> gpio11 高 -> 50ms -> gpio186 高）
#   2) 之后以 ~10ms 间隔同时轮询 0x007A(EPT) / 0x0030(IRQ) / 0x004D(MODE) / 0x007E(TX_STAT)
#      —— 只在数值变化时打印，并带毫秒时间戳
#   3) 一旦看到 bit7 (TX Init Done)：立即按指南清中断，然后【马上】写 TX EN
#   4) 一旦看到 bit0 (EPT Type)：立即记录当时的 0x007A 值并解码
#   5) 结尾打印时间线汇总
#
# 用法: sudo ./ra9530-catch-ept.sh

set -u

ADDR=0x3b
I2C_BUS=""
GPIO_CHIP="gpiochip3"
PIN_EN=11
PIN_BOOST=186
IRQ_PIN=101
TLMM_BASE=""
POLL_MS=${POLL_MS:-10}
DURATION_MS=${DURATION_MS:-4000}

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

rd32() { local a b c d; read -r a b c d <<<"$(i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 "$1" r4 2>/dev/null)"
         [[ "$a" == 0x* && "$d" == 0x* ]] && printf '%u' $(( d<<24|c<<16|b<<8|a )) || printf '0'; }
rd16() { local a b; read -r a b <<<"$(i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 "$1" r2 2>/dev/null)"
         [[ "$a" == 0x* && "$b" == 0x* ]] && printf '%u' $(( b<<8|a )) || printf '0'; }
rd8()  { local a; a=$(i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 "$1" r1 2>/dev/null)
         [[ "$a" == 0x* ]] && printf '%u' "$a" || printf '0'; }
w16()  { i2ctransfer -f -y "$I2C_BUS" "w4@${ADDR}" 0x00 "$1" \
         "$(printf '0x%02x' $(( ($2)      & 0xff )))" \
         "$(printf '0x%02x' $(( ($2 >> 8) & 0xff )))"; }
ms()   { sleep "$(printf '%d.%03d' $(( $1 / 1000 )) $(( $1 % 1000 )))"; }

ept_decode() {   # $1 = 16bit EPT
    local v=$1 out=""
    (( (v>>15)&1 )) && out="$out POCP"
    (( (v>>14)&1 )) && out="$out OTP"
    (( (v>>13)&1 )) && out="$out FOD"
    (( (v>>12)&1 )) && out="$out LVP(低压)"
    (( (v>>11)&1 )) && out="$out OVP(过压)"
    (( (v>>10)&1 )) && out="$out OCP(过流)"
    (( (v>>9)&1  )) && out="$out RPP超时"
    (( (v>>8)&1  )) && out="$out CEP超时"
    (( (v>>7)&1  )) && out="$out 看门狗超时"
    (( (v>>6)&1  )) && out="$out NOI2C超时"
    (( (v>>5)&1  )) && out="$out TX冲突"
    (( (v>>4)&1  )) && out="$out Ping电压异常"
    (( (v>>3)&1  )) && out="$out 认证失败"
    (( (v>>0)&1  )) && out="$out EPT命令"
    [[ -z "$out" ]] && out=" (无位)"
    echo "$out"
}

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

echo "=============================================================="
echo " RA9530 高速轮询抓 EPT (i2c-$I2C_BUS, 间隔 ${POLL_MS}ms, 共 ${DURATION_MS}ms)"
printf ' 总线速率 = %s Hz\n' "$(od -An -tu4 --endian=big /sys/bus/i2c/devices/i2c-$I2C_BUS/of_node/clock-frequency 2>/dev/null | tr -d ' ')"
echo "=============================================================="
gpio_prep "$PIN_EN"; gpio_prep "$PIN_BOOST"

echo
echo "########## 上电时序 ##########"
echo "  两脚低 500ms -> gpio$PIN_EN 高 -> 50ms -> gpio$PIN_BOOST 高"
gpio_set "$PIN_EN" 0; gpio_set "$PIN_BOOST" 0
ms 500
gpio_set "$PIN_EN" 1; ms 50
gpio_set "$PIN_BOOST" 1

echo
echo "########## 高速轮询（只在变化时打印）##########"
t=0; prev_ept=""; prev_irq=""; prev_mode=""; prev_stat=""
did_txen=0; saw_ept=0; txen_t=""

while [[ $t -le $DURATION_MS ]]; do
    ept=$(rd16 0x7a); irq=$(rd32 0x30); mode=$(rd8 0x4d); stat=$(rd8 0x7e)
    if [[ "$ept|$irq|$mode|$stat" != "$prev_ept|$prev_irq|$prev_mode|$prev_stat" ]]; then
        printf '  t=%4dms  EPT=0x%04X  IRQ=0x%08X  MODE=0x%02X  TX_STAT=0x%02X\n' \
            "$t" "$ept" "$irq" "$mode" "$stat"
        prev_ept=$ept; prev_irq=$irq; prev_mode=$mode; prev_stat=$stat
    fi

    # EPT 错误：立刻记录（这是本轮唯一目的）
    if (( (irq>>0)&1 )) && [[ $saw_ept -eq 0 ]]; then
        saw_ept=1
        printf '  >> t=%dms 捕获 EPT Type 中断：0x007A = 0x%04X  ->%s\n' \
            "$t" "$ept" "$(ept_decode "$ept")"
    fi

    # 等到 TX Init Done -> 按指南清中断，然后立刻写 TX EN
    if (( (irq>>7)&1 )) && [[ $did_txen -eq 0 ]]; then
        echo "  >> t=${t}ms 看到 bit7 (TX Init Done)，按指南清中断后立刻写 TX EN"
        b0=$(printf '0x%02x' $((  irq       & 0xff )))
        b1=$(printf '0x%02x' $(( (irq>>8)   & 0xff )))
        b2=$(printf '0x%02x' $(( (irq>>16)  & 0xff )))
        b3=$(printf '0x%02x' $(( (irq>>24)  & 0xff )))
        i2ctransfer -f -y "$I2C_BUS" "w6@${ADDR}" 0x00 0x28 "$b0" "$b1" "$b2" "$b3" 2>/dev/null
        ms 5
        w16 0x7c 0x0002      # CLR Interrupt
        ms 5
        w16 0x7c 0x0001      # TX EN
        did_txen=1; txen_t=$t
    fi
    ms "$POLL_MS"; t=$((t + POLL_MS))
done

echo
echo "########## 时间线 ##########"
printf '  bit7 (TX Init Done) 捕获: %s\n' "$([[ $did_txen -eq 1 ]] && echo "是 (t=${txen_t}ms，已清中断并写 TX EN)" || echo "否")"
printf '  bit0 (EPT Type) 捕获   : %s\n' "$([[ $saw_ept -eq 1 ]] && echo "是" || echo "否")"
printf '  最终状态               : EPT=0x%04X  IRQ=0x%08X  MODE=0x%02X  TX_STAT=0x%02X  Vin=%s\n' \
    "$(rd16 0x7a)" "$(rd32 0x30)" "$(rd8 0x4d)" "$(rd8 0x7e)" \
    "$(i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 0x80 r2 2>/dev/null)"

if [[ "$(rd8 0x4d)" == "4" ]]; then
    echo
    echo "  *** MODE = 0x04，Tx 已使能 —— 笔应开始充电 ***"
    read -r -p "  按 Enter 结束观测..." _ </dev/tty || true
elif [[ $saw_ept -eq 1 ]]; then
    echo
    echo "  拿到了 EPT 错误类型 —— 这就是芯片拒绝完成 Tx 的原因，可按位对症处理"
    echo "  （例如 FOD=异物检测阈值、LVP=低压、OCP=过流、Ping电压异常…）"
else
    echo
    echo "  没抓到 bit0，也没进 0x04。若轮询间隔仍太粗可加大频率："
    echo "    POLL_MS=5 DURATION_MS=6000 sudo ./ra9530-catch-ept.sh"
fi
