#!/usr/bin/env bash
#
# ra9530-txready.sh — 找出让 RA9530 进入 "TX ready" 的条件，再开 Tx。
#
# 上次结论:
#   MODE(0x004D) = 0x80 = "Back Powered"，芯片由 VOUT 供电但 Tx 未使能。
#   写 0x007C bit0 (TX EN) 毫无反应（MODE/IRQ/EPT 全不变）。
#
# 新线索（RA953-R Evaluation Kit Manual R16UH0022EU0200）:
#   * GP2/TX_EN (芯片第 10 脚): "If GP2 is pulled up by VDDIO, TRx mode starts
#     working automatically when external power is connected to the VOUT pin."
#   * "TRx Mode Auto-Enable: The RA9530-R enters into TRx mode automatically if
#     GP2 level is high WHEN Vout is powered by external power or AP."
#        -> 触发条件是「VOUT 上电时 GP2 已经是高」，也就是需要一次边沿/上电事件
#   * TX Status Register (0x007E) bit1 = "TX ready: chip is ready and wait for
#     TX_EN command"  <-- 只有 ready 了，0x007C 的 TX EN 才会被受理
#   * 厂商 Windows 驱动 (wtSXBCharger.dll) 从来不写 0x7C，只用
#     0x28/0x30/0x34/0x3a/0x4d/0x50/0x58 -> 说明本板 TX 使能走的是硬件 GP2 路线
#
# 本板推断（本脚本要验证）:
#   gpio11  = VOUT 供电/主使能，高有效（拉低 -> IC 从 I2C 消失，已实测）
#   gpio186 = GP2/TX_EN，高有效
#
# 依赖: i2c-tools；用法: sudo ./ra9530-txready.sh

set -u

ADDR=0x3b
I2C_BUS=""
GPIO_CHIP="gpiochip3"
PIN_VOUT=11
PIN_TXEN=186
IRQ_PIN=101
TLMM_BASE=""
MODE_TX=4
DUMP_ONLY=0
[[ "${1:-}" == "--dump-only" ]] && DUMP_ONLY=1

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

r8()  { local o; o=$(raw "$1" 1); [[ "$o" == 0x* ]] && printf '%d' "$o" || printf 'ERR'; }
r16() { local a b; read -r a b <<<"$(raw "$1" 2)"
        [[ "$a" == 0x* && "$b" == 0x* ]] && printf '%d' $(( b << 8 | a )) || printf 'ERR'; }
r32() { local a b c d; read -r a b c d <<<"$(raw "$1" 4)"
        [[ "$a" == 0x* && "$b" == 0x* && "$c" == 0x* && "$d" == 0x* ]] \
            && printf '%d' $(( d << 24 | c << 16 | b << 8 | a )) || printf 'ERR'; }
h8()  { local v; v=$(r8  "$1"); [[ "$v" == ERR ]] && printf 'READ-FAIL' || printf '0x%02X' "$v"; }
h16() { local v; v=$(r16 "$1"); [[ "$v" == ERR ]] && printf 'READ-FAIL' || printf '0x%04X' "$v"; }
h32() { local v; v=$(r32 "$1"); [[ "$v" == ERR ]] && printf 'READ-FAIL' || printf '0x%08X' "$v"; }

w16() { i2ctransfer -f -y "$I2C_BUS" "w4@${ADDR}" 0x00 "$1" \
        "$(printf '0x%02x' $(( ($2)      & 0xff )))" \
        "$(printf '0x%02x' $(( ($2 >> 8) & 0xff )))"; }
w8()  { i2ctransfer -f -y "$I2C_BUS" "w3@${ADDR}" 0x00 "$1" \
        "$(printf '0x%02x' $(( $2 & 0xff )))"; }

mode_str() {
    case "$1" in
        0x80) echo "Back Powered (由 VOUT 供电，Tx 未使能)";;
        0x04) echo "*** TRx Mode (正在发射) ***";;
        0x09) echo "Extended WPC Mode";;
        0x01) echo "Basic WPC Mode";;
        0x00) echo "AC Missing";;
        READ-FAIL) echo "(芯片不应答)";;
        *) echo "Reserved";;
    esac
}

txstat_str() {   # $1 = h8 的结果
    local s=$1 v
    if [[ "$s" == READ-FAIL ]]; then echo "(读取失败)"; return; fi
    v=$(r8 0x7e)
    [[ "$v" == ERR ]] && { echo "(读取失败)"; return; }
    local out=""
    (( (v >> 1) & 1 )) && out="$out [bit1 TX ready]"
    (( (v >> 3) & 1 )) && out="$out [bit3 TX transfer]"
    [[ -z "$out" ]] && out=" bit1=0 -> 还未 ready"
    echo "$out"
}

# ---------------------------------------------------------------- GPIO (sysfs)
gpio_path() { echo "/sys/class/gpio/gpio$(( TLMM_BASE + $1 ))"; }

gpio_prepare() {   # 导出并原子设为输出高（避开 direction=out 会拉低的坑）
    local p; p=$(gpio_path "$1")
    if [[ ! -d "$p" ]]; then
        echo "$(( TLMM_BASE + $1 ))" > /sys/class/gpio/export 2>/dev/null
        sleep 0.05
    fi
    echo high > "$p/direction" 2>/dev/null
}

gpio_set() { echo "$2" > "$(gpio_path "$1")/value" || die "写 gpio$1=$2 失败"; }
gpio_get() { cat "$(gpio_path "$1")/value" 2>/dev/null || echo "?"; }

restore() {
    local rc=$?
    gpio_prepare "$PIN_VOUT"; gpio_prepare "$PIN_TXEN"
    sleep 0.05
    printf '[cleanup] gpio%s=%s(供电)  gpio%s=%s(TX_EN)\n' \
        "$PIN_VOUT" "$(gpio_get "$PIN_VOUT")" "$PIN_TXEN" "$(gpio_get "$PIN_TXEN")"
    local o; for o in "$PIN_VOUT" "$PIN_TXEN"; do
        echo "$(( TLMM_BASE + o ))" > /sys/class/gpio/unexport 2>/dev/null
    done
    exit $rc
}
trap restore EXIT INT TERM

dump() {
    printf '  CHIP_ID  (0x0000) = %s\n' "$(raw 0x00 2)"
    local m; m=$(h8 0x4d)
    printf '  MODE     (0x004D) = %s  %s\n' "$m" "$(mode_str "$m")"
    local s; s=$(h8 0x7e)
    printf '  TX_STAT  (0x007E) = %s %s\n' "$s" "$(txstat_str "$s")"
    printf '  IRQ      (0x0030) = %s\n' "$(h32 0x30)"
    printf '  IRQ_EN   (0x0034) = %s\n' "$(h32 0x34)"
    printf '  EPT      (0x007A) = %s\n' "$(h16 0x7a)"
    printf '  Vin      (0x0080) = %s mV\n' "$(h16 0x80)"
    printf '  Vrect    (0x0082) = %s mV\n' "$(h16 0x82)"
    printf '  DieTemp  (0x0084) = %s C\n' "$(h16 0x84)"
    printf '  gpio%s=%s(供电)  gpio%s=%s(TX_EN)  IRQ gpio%s=%s\n' \
        "$PIN_VOUT" "$(gpio_get "$PIN_VOUT")" "$PIN_TXEN" "$(gpio_get "$PIN_TXEN")" \
        "$IRQ_PIN" "$(gpioget --as-is --numeric -c "$GPIO_CHIP" "$IRQ_PIN" 2>/dev/null | tr -dc '01' | tail -c1)"
}

ask() {
    local a
    printf '\n>>> %s\n    继续? [y/N] ' "$1"
    read -r a </dev/tty || die "读输入失败"
    [[ "$a" == "y" || "$a" == "Y" ]] || die "用户中止"
}

echo "=============================================================="
echo " RA9530 探测 TX ready 条件（i2c-$I2C_BUS）"
echo " gpio$PIN_VOUT=推断为 VOUT 供电   gpio$PIN_TXEN=推断为 GP2/TX_EN"
echo "=============================================================="
echo

gpio_prepare "$PIN_VOUT"
gpio_prepare "$PIN_TXEN"

echo "########## 0. 基线 ##########"
dump
[[ "$(raw 0x00 2)" == 0x* ]] || die "芯片不应答，先检查 gpio$PIN_VOUT 是否为高"
[[ $DUMP_ONLY -eq 1 ]] && { echo; echo "(--dump-only，结束)"; exit 0; }

# ------------------------------------------------------------ 1. 证明 I2C 写有效
echo
echo "########## 1. 写/读回测试：证明我们的 I2C 写真的落地（写 0x0050） ##########"
printf '  写前 0x0050 = %s\n' "$(raw 0x50 4)"
i2ctransfer -f -y "$I2C_BUS" "w6@${ADDR}" 0x00 0x50 0xa5 0x5a 0xa5 0x5a || die "写 0x0050 失败"
sleep 0.02
printf '  写后 0x0050 = %s   <- 应出现 0xa5 0x5a 0xa5 0x5a\n' "$(raw 0x50 4)"
i2ctransfer -f -y "$I2C_BUS" "w6@${ADDR}" 0x00 0x50 0x00 0x00 0x00 0x00 2>/dev/null
printf '  已还原 0x0050\n'

# ------------------------------------------------------------ 2. TX ready?
echo
echo "########## 2. 当前 TX Status (0x007E) ##########"
txs=$(r8 0x7e)
if [[ "$txs" == ERR ]]; then
    echo "  读取失败"
else
    printf '  值 = 0x%02X   bit1(TX ready) = %d   bit3(TX transfer) = %d\n' \
        "$txs" $(( (txs >> 1) & 1 )) $(( (txs >> 3) & 1 ))
fi

# ------------------------------------------------------------ 3. GP2 上升沿
echo
echo "########## 3. 给 gpio$PIN_TXEN (GP2/TX_EN) 一个上升沿 ##########"
echo "  理由: 触发条件是「VOUT 已上电时 GP2 变高」，开机时可能顺序不对，错过了一次。"
ask "gpio$PIN_TXEN 拉低 250ms 再拉高？"
gpio_set "$PIN_TXEN" 0
sleep 0.25
gpio_set "$PIN_TXEN" 1
sleep 0.5
echo "--- gpio$PIN_TXEN 上升沿之后 ---"
dump

if [[ "$(r8 0x4d)" == "$MODE_TX" ]]; then
    cat <<EOF

==============================================================
 *** 成功: MODE = 0x04，TRx 正在发射 ***
 触发条件是 GP2/TX_EN 的上升沿。现在检查笔是否开始充电。
 按 Enter 结束（gpio 会恢复为高 = 使能状态）。
==============================================================
EOF
    read -r _ </dev/tty
    echo "结束。"; exit 0
fi

# ------------------------------------------------------------ 4. VOUT 断电重启
echo
echo "########## 4. 让 IC 在 GP2 已高的状态下重新上电 ##########"
echo "  gpio$PIN_VOUT 拉低 400ms 再拉高（= 拔掉/插上 VOUT 供电）。"
echo "  期间芯片会从 I2C 上消失，读失败是正常的。"
ask "执行 gpio$PIN_VOUT 断电重启（gpio$PIN_TXEN 保持高）？"
gpio_set "$PIN_VOUT" 0
sleep 0.4
printf '  (断电中) CHIP_ID = %s\n' "$(raw 0x00 2)"
gpio_set "$PIN_VOUT" 1
sleep 0.8
echo "--- 重新上电之后 ---"
dump

if [[ "$(r8 0x4d)" == "$MODE_TX" ]]; then
    cat <<EOF

==============================================================
 *** 成功: MODE = 0x04，TRx 正在发射 ***
 触发条件是「VOUT 上电时 GP2 已高」，gpio$PIN_VOUT = VOUT 供电、
 gpio$PIN_TXEN = GP2/TX_EN 的推断成立。
==============================================================
EOF
    read -r _ </dev/tty
    echo "结束。"; exit 0
fi

# ------------------------------------------------------------ 5. ready 了再写命令
echo
echo "########## 5. 若已 ready，再写一次 TX EN ##########"
txs=$(r8 0x7e)
if [[ "$txs" != ERR ]] && (( (txs >> 1) & 1 )); then
    echo "  bit1 TX ready = 1，再写 0x007C = 0x0001"
    w16 0x7c 0x0001
    sleep 0.3
    dump
else
    echo "  bit1 TX ready 仍为 0 —— 芯片不接受 TX_EN 的原因就在这里。"
    echo "  即：MODE 仍是 Back Powered，说明 0x007C 这条软命令路线在本板无效，"
    echo "  Tx 使能只能靠 GP2/TX_EN 硬件脚（与厂商驱动从不写 0x7C 一致）。"
    echo "  下一步应确认 gpio$PIN_TXEN 究竟是不是 GP2/TX_EN —— 若它其实是别的功能，"
    echo "  真正接 GP2 的可能是另一根脚或固定上拉。"
fi

echo
echo "结束。"
