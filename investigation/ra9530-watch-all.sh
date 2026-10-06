#!/usr/bin/env bash
#
# ra9530-watch-all.sh — 一次性覆盖三个之前漏掉的地方
#
# 之前三次踩的坑：
#   1) 从没在【上电时序之前】读基线 -> 无法判断中断是新产生的还是之前残留的
#   2) 从没在【上电时序进行中】轮询 -> EPT 发生在时序期间(几 ms~几百 ms 内)，
#      等时序做完再读，0x007A 已经归零
#   3) 写完 TX EN 只等 300ms -> 而这颗芯片的 ping 间隔配置是 11000ms，
#      上一轮脚本结束后下一轮开头看到挂着的 0x2081，很可能就是那个迟到的反应
#
# 本脚本：
#   阶段0 上电前基线
#   阶段1 「两脚低」期间轮询
#   阶段2 gpio11 拉高后轮询 300ms（~10ms 间隔）
#   阶段3 gpio186 拉高（VOUT 上电）后连续轮询 1500ms —— 抓 TX Init Done / EPT / 笔的包 / 0x04
#   阶段4 收到 TX Init Done 就按指南清中断并写 TX EN，然后【盯 30 秒】
#   全程只打印变化，带毫秒时间戳
#
# 用法:
#   sudo ./ra9530-watch-all.sh
#   WATCH_MS=60000 sudo ./ra9530-watch-all.sh    # 第4阶段盯 60 秒

set -u

ADDR=0x3b
I2C_BUS=""
GPIO_CHIP="gpiochip3"
PIN_EN=11
PIN_BOOST=186
TLMM_BASE=""
FAST_MS=${FAST_MS:-10}
POST_MS=${POST_MS:-1500}
WATCH_MS=${WATCH_MS:-30000}

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
         [[ "$a" == 0x* && "$d" == 0x* ]] && printf '%u' $(( d<<24|c<<16|b<<8|a )) || printf '999'; }
rd16() { local a b; read -r a b <<<"$(i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 "$1" r2 2>/dev/null)"
         [[ "$a" == 0x* && "$b" == 0x* ]] && printf '%u' $(( b<<8|a )) || printf '999'; }
rd8()  { local a; a=$(i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 "$1" r1 2>/dev/null)
         [[ "$a" == 0x* ]] && printf '%u' "$a" || printf '999'; }
w16()  { i2ctransfer -f -y "$I2C_BUS" "w4@${ADDR}" 0x00 "$1" \
         "$(printf '0x%02x' $(( ($2)      & 0xff )))" \
         "$(printf '0x%02x' $(( ($2 >> 8) & 0xff )))"; }
ms()   { sleep "$(printf '%d.%03d' $(( $1 / 1000 )) $(( $1 % 1000 )))"; }

irq_name() {
    case "$1" in
        0) echo "EPT错误";; 1) echo "DigitalPing";; 2) echo "信号强度包";; 3) echo "ID包";;
        4) echo "配置包";; 5) echo "模式变化";; 6) echo "TX冲突";; 7) echo "TX初始化完成";;
        8) echo "BLE地址";; 13) echo "收到笔的私有包";; 14) echo "EPT重启";;
        15) echo "*** 收到笔的电量包(CSP) ***";; 16) echo "认证包";; 17) echo "认证通过";;
        *) echo "other";;
    esac
}
ept_decode() {
    local v=$1 out=""
    (( (v>>15)&1 )) && out="$out POCP"
    (( (v>>14)&1 )) && out="$out OTP(过温)"
    (( (v>>13)&1 )) && out="$out FOD(异物)"
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
    (( (v>>0)&1  )) && out="$out EPT命令(来自笔)"
    [[ -z "$out" ]] && out=" (全 0：芯片报 EPT 但类型寄存器为空)"
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

PREV=""; SAW04=0; SAWEPT=0; EPTVAL=""; DIDTXEN=0; TXENT=""
poll_once() {   # $1 = 时间戳 ms
    local t=$1 ept irq mode stat
    ept=$(rd16 0x7a); irq=$(rd32 0x30); mode=$(rd8 0x4d); stat=$(rd8 0x7e)
    [[ "$mode" == "999" ]] && return 0
    if [[ "$ept|$irq|$mode|$stat" != "$PREV" ]]; then
        printf '  t=%6dms  EPT=0x%04X  IRQ=0x%08X  MODE=0x%02X  TX_STAT=0x%02X\n' \
            "$t" "$ept" "$irq" "$mode" "$stat"
        PREV="$ept|$irq|$mode|$stat"
    fi
    if [[ "$mode" == "4" && $SAW04 -eq 0 ]]; then
        SAW04=1; printf '  >> t=%dms  *** MODE = 0x04，Tx 正在发射！***\n' "$t"
    fi
    if (( (irq>>0)&1 )) && [[ $SAWEPT -eq 0 ]]; then
        SAWEPT=1; EPTVAL=$ept
        printf '  >> t=%dms  EPT 中断出现，此刻 0x007A=0x%04X ->%s\n' "$t" "$ept" "$(ept_decode "$ept")"
    fi
    return 0
}

clear_and_txen() {
    local m; m=$(rd32 0x30)
    if [[ "$m" != "0" && "$m" != "999" ]]; then
        local b0 b1 b2 b3
        b0=$(printf '0x%02x' $((  m       & 0xff ))); b1=$(printf '0x%02x' $(( (m>>8)  & 0xff )))
        b2=$(printf '0x%02x' $(( (m>>16)  & 0xff ))); b3=$(printf '0x%02x' $(( (m>>24) & 0xff )))
        echo "  >> 清中断：写 0x0028 = $b0 $b1 $b2 $b3，再写 0x7C = 0x0002"
        i2ctransfer -f -y "$I2C_BUS" "w6@${ADDR}" 0x00 0x28 "$b0" "$b1" "$b2" "$b3" 2>/dev/null
        ms 5; w16 0x7c 0x0002; ms 5
    fi
    echo "  >> 写 TX EN：0x007C = 0x0001"
    w16 0x7c 0x0001
    DIDTXEN=1
}

echo "=============================================================="
echo " RA9530 全阶段监视 (i2c-$I2C_BUS)"
printf ' 总线速率 = %s Hz   快速轮询 %sms   上电后监视 %dms   写TXEN后监视 %dms\n' \
  "$(od -An -tu4 --endian=big /sys/bus/i2c/devices/i2c-$I2C_BUS/of_node/clock-frequency 2>/dev/null | tr -d ' ')" \
  "$FAST_MS" "$POST_MS" "$WATCH_MS"
echo "=============================================================="
gpio_prep "$PIN_EN"; gpio_prep "$PIN_BOOST"

echo
echo "########## 阶段 0：上电前基线（这是之前一直缺的）##########"
poll_once 0
printf '  gpio%s=%s  gpio%s=%s   Vin=%s\n' "$PIN_EN" "$(gpio_get "$PIN_EN")" \
    "$PIN_BOOST" "$(gpio_get "$PIN_BOOST")" "$(i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 0x80 r2 2>/dev/null)"

echo
echo "########## 阶段 1：两脚拉低 500ms ##########"
gpio_set "$PIN_EN" 0; gpio_set "$PIN_BOOST" 0
t=0; while [[ $t -lt 500 ]]; do poll_once $t; ms 50; t=$((t + 50)); done

echo
echo "########## 阶段 2：gpio$PIN_EN 拉高，轮询 300ms ##########"
gpio_set "$PIN_EN" 1
t=0; while [[ $t -lt 300 ]]; do poll_once $t; ms "$FAST_MS"; t=$((t + FAST_MS)); done

echo
echo "########## 阶段 3：gpio$PIN_BOOST 拉高（VOUT 上电），轮询 ${POST_MS}ms ##########"
gpio_set "$PIN_BOOST" 1
t=0; while [[ $t -lt $POST_MS ]]; do
    poll_once $t
    ms "$FAST_MS"; t=$((t + FAST_MS))
done

echo
echo "########## 阶段 4：清中断 + 写 TX EN，然后盯 ${WATCH_MS}ms ##########"
clear_and_txen
t=0
while [[ $t -lt $WATCH_MS ]]; do
    poll_once $t
    # 中途若又出现中断，再清一次（指南 5.1.1 建议尽快清）
    irq=$(rd32 0x30)
    if [[ "$irq" != "0" && "$irq" != "999" ]]; then
        printf '  >> t=%dms 又出现中断 0x%08X，按指南清掉\n' "$t" "$irq"
        clear_and_txen
    fi
    ms 50; t=$((t + 50))
done

echo
echo "########## 汇总 ##########"
printf '  上电完成后是否出现 MODE=0x04 : %s\n' "$([[ $SAW04 -eq 1 ]] && echo "是" || echo "否")"
printf '  是否捕获 EPT 中断           : %s\n' "$([[ $SAWEPT -eq 1 ]] && echo "是，0x007A=0x$EPTVAL" || echo "否")"
printf '  最终                          : EPT=0x%04X IRQ=0x%08X MODE=0x%02X TX_STAT=0x%02X\n' \
    "$(rd16 0x7a)" "$(rd32 0x30)" "$(rd8 0x4d)" "$(rd8 0x7e)"
if [[ $SAW04 -eq 1 ]]; then
    echo
    echo "  *** Tx 真的启动了！笔应该开始充电。***"
elif [[ $SAWEPT -eq 1 && "$EPTVAL" != "0" ]]; then
    echo
    echo "  EPT 类型非 0 —— 这就是芯片中止 Tx 的具体原因，可按位对症处理。"
elif [[ $SAWEPT -eq 1 ]]; then
    echo
    echo "  EPT 中断出现了但类型寄存器是 0：芯片报了 EPT 事件却没给出原因位。"
    echo "  结合 bit13「收到笔的私有包」，很可能是【笔自己发了 EPT】。"
else
    echo
    echo "  既没进 0x04，也没抓到 EPT 中断。"
fi
