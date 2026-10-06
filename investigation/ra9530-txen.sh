#!/usr/bin/env bash
#
# ra9530-txen.sh — 在【不碰 gpio11】的前提下，写 TX EN 让 RA9530 开始发射。
#
# 背景（上一次实验的结论）：
#   gpio11 拉低会让 RA9530 从 I2C 上消失（ENXIO）-> gpio11 = 供电/复位使能，
#   **高有效**，且开机固件已经把它拉高。DT 里标的 GPIO_ACTIVE_LOW 是错的。
#   所以正确做法是：保留 gpio11 高，直接写 TX EN。
#
# 依赖: i2c-tools（GPIO 只读观察用 gpioget --as-is，不改方向）
# 用法: sudo ./ra9530-txen.sh
#
# 依据 Renesas R16UH0023EU0100:
#   写 TX System Command (0x007C) bit0=TX EN -> 等 100ms -> 读 0x004D，0x04 = Tx 已使能
#   中断处理: 读 0x0030 得 m -> 把 m 写回 0x0028 -> 写 0x02 到 0x007C (Clear Interrupt)
#             (5.1.1 注: 清寄存器必须写"与中断寄存器相同的位"才生效)

set -u

ADDR=0x3b
I2C_BUS=""
GPIO_CHIP="gpiochip3"
PIN_EN=11                 # 供电/复位，高有效（本次不碰）
PIN_B=186                 # 待定
IRQ_PIN=101               # 中断 OD2，开漏低有效，下降沿有效
TLMM_BASE=""
MODE_TX=4

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

w16() {
    i2ctransfer -f -y "$I2C_BUS" "w4@${ADDR}" 0x00 "$1" \
        "$(printf '0x%02x' $(( ($2)      & 0xff )))" \
        "$(printf '0x%02x' $(( ($2 >> 8) & 0xff )))"
}

# Tx 侧中断事件（指南 Table 4）
irq_name() {
    case "$1" in
        0)  echo "EPT Type (错误! 读 0x007A，需断电重来)";;
        1)  echo "Start Digital Ping";;
        2)  echo "Signal Strength Packet";;
        3)  echo "Identification Packet Received";;
        4)  echo "Configuration Packet Received";;
        5)  echo "Operation Mode Change";;
        6)  echo "TX Conflict";;
        7)  echo "TX Initialization Done  <-- 开 Tx 的信号";;
        8)  echo "BLE Address Received";;
        13) echo "Proprietary Packet Received";;
        14) echo "EPT Restart Received";;
        15) echo "CSP Packet Received (笔的电量)";;
        16) echo "Pen Authentication packet Received";;
        17) echo "Pen Authentication Pass";;
        *)  echo "reserved/other";;
    esac
}

decode_irq() {
    local v=$1 i
    [[ "$v" == ERR ]] && { echo "  (读取失败)"; return; }
    if [[ "$v" -eq 0 ]]; then echo "  (无 pending 中断)"; return; fi
    for i in 0 1 2 3 4 5 6 7 8 13 14 15 16 17; do
        (( (v >> i) & 1 )) && printf '  bit%-2d %s\n' "$i" "$(irq_name "$i")"
    done
}

irq_bit() {
    local v; v=$(r32 0x30)
    [[ "$v" == ERR ]] && { echo ERR; return; }
    printf '%d' $(( (v >> $1) & 1 ))
}

clear_irq() {   # 按 5.1.1: 读 m -> 写回 0x0028 -> 写 0x02 到 0x007C
    local b; b=$(raw 0x30 4)
    [[ "$b" == 0x* ]] || { echo "  (读中断寄存器失败，跳过清理)"; return 1; }
    # shellcheck disable=SC2086
    set -- $b
    if [[ "$1" == 0x00 && "$2" == 0x00 && "$3" == 0x00 && "$4" == 0x00 ]]; then
        echo "  (中断寄存器本来是 0，无需清理)"
        return 0
    fi
    echo "  把 $b 写回 0x0028 ..."
    i2ctransfer -f -y "$I2C_BUS" "w6@${ADDR}" 0x00 0x28 "$1" "$2" "$3" "$4" || return 1
    sleep 0.05
    echo "  写 0x007C = 0x0002 (Clear Interrupt) ..."
    w16 0x7c 0x0002 || return 1
    sleep 0.05
    printf '  清理后 IRQ = %s\n' "$(h32 0x30)"
}

# ---------------------------------------------------------------- GPIO
gpio_read_line() { gpioget --as-is --numeric -c "$GPIO_CHIP" "$1" 2>/dev/null | tr -dc '01' | tail -c1; }

gpio186_hold() {
    local p="/sys/class/gpio/gpio$(( TLMM_BASE + PIN_B ))"
    if [[ ! -d "$p" ]]; then
        echo "$(( TLMM_BASE + PIN_B ))" > /sys/class/gpio/export 2>/dev/null
        sleep 0.05
        echo high > "$p/direction" 2>/dev/null     # high 避免拉低毛刺
    fi
    echo "$1" > "$p/value" || die "写 gpio$PIN_B value=$1 失败"
}

gpio186_release() {
    local p="/sys/class/gpio/gpio$(( TLMM_BASE + PIN_B ))"
    [[ -d "$p" ]] || return 0
    echo high > "$p/direction" 2>/dev/null
    sleep 0.05
    echo "$(( TLMM_BASE + PIN_B ))" > /sys/class/gpio/unexport 2>/dev/null
    printf '[cleanup] gpio%s 已恢复 high 并释放\n' "$PIN_B"
}
trap gpio186_release EXIT INT TERM

dump() {
    printf '  CHIP_ID (0x0000) = %s\n' "$(raw 0x00 2)"
    printf '  MODE    (0x004D) = %s   <-- 0x04 才是 Tx 已使能\n' "$(h8 0x4d)"
    printf '  IRQ     (0x0030) = %s\n' "$(h32 0x30)"
    decode_irq "$(r32 0x30)"
    printf '  IRQ_EN  (0x0034) = %s\n' "$(h32 0x34)"
    printf '  BATT    (0x003A) = %s\n' "$(h8 0x3a)"
    printf '  EPT     (0x007A) = %s\n' "$(h16 0x7a)"
    printf '  gpio%s=%s  gpio%s=%s  IRQ gpio%s=%s\n' \
        "$PIN_EN" "$(gpio_read_line "$PIN_EN")" \
        "$PIN_B"  "$(gpio_read_line "$PIN_B")" \
        "$IRQ_PIN" "$(gpio_read_line "$IRQ_PIN")"
}

ask() {
    local a
    printf '\n>>> %s\n    继续? [y/N] ' "$1"
    read -r a </dev/tty || die "读输入失败"
    [[ "$a" == "y" || "$a" == "Y" ]] || die "用户中止"
}

echo "=============================================================="
echo " RA9530 写 TX EN（不碰 gpio$PIN_EN）"
echo " i2c-$I2C_BUS   gpio$PIN_EN=供电/复位(高有效)   gpio$PIN_B=待定"
echo "=============================================================="
echo
echo "########## 0. 确认芯片还在（gpio$PIN_EN 应已由上次 cleanup 恢复为高） ##########"
dump

if [[ "$(raw 0x00 2)" != 0x* ]]; then
    echo
    echo "!! 芯片不应答，gpio$PIN_EN 可能没回到高。"
    ask "显式把 gpio$PIN_EN 重新设为输出高，再试一次？"
    p="/sys/class/gpio/gpio$(( TLMM_BASE + PIN_EN ))"
    [[ -d "$p" ]] || echo "$(( TLMM_BASE + PIN_EN ))" > /sys/class/gpio/export 2>/dev/null
    sleep 0.05
    echo high > "$p/direction" || die "无法把 gpio$PIN_EN 设为高"
    sleep 0.3
    dump
    echo "$(( TLMM_BASE + PIN_EN ))" > /sys/class/gpio/unexport 2>/dev/null
fi
[[ "$(raw 0x00 2)" == 0x* ]] || die "芯片始终不应答，需要人工检查 gpio$PIN_EN 与供电"

mode_before=$(h8 0x4d)

# ------------------------------------------------------------ 1. TX Init Done
echo
echo "########## 1. 检查 TX Initialization Done (bit 7) ##########"
txinit=$(irq_bit 7)
echo "  bit7 = $txinit"
if [[ "$txinit" == "1" ]]; then
    echo "  -> 有 Tx 初始化完成中断，按指南先清中断再开 Tx。"
    ask "清中断？"
    clear_irq
else
    echo "  -> 没有该中断。IC 可能不需要等它，先直接写 TX EN 试试。"
fi

# ------------------------------------------------------------ 2. 直接写 TX EN
echo
echo "########## 2. 直接写 TX EN（gpio$PIN_EN 保持高，不动任何 GPIO） ##########"
ask "写 TX System Command (0x007C) bit0 = TX EN？"

w16 0x7c 0x0001 || die "写 0x007C 失败"
echo "  已写 0x007C = 0x0001，等 300ms ..."
sleep 0.3
echo "--- 写 TX EN 之后 ---"
dump

if [[ "$(r8 0x4d)" == "$MODE_TX" ]]; then
    cat <<EOF

==============================================================
 *** 成功: MODE = 0x04，Tx 正在发射 ***
 之前: MODE=$mode_before
 现在检查笔是否开始充电（笔身指示 / 机身温度）。
 按 Enter 结束；gpio$PIN_EN 全程未动。
==============================================================
EOF
    read -r _ </dev/tty
    echo "实验结束。"; exit 0
fi

echo
echo "MODE 没变 0x04。EPT 报错位解析:"
printf '  EPT = %s\n' "$(h16 0x7a)"
cat <<'EOF'
   bit15 POCP  bit14 OTP  bit13 FOD  bit12 LVP  bit11 OVP  bit10 OCP
   bit9  RPP超时 bit8 CEP超时 bit7 看门狗 bit6 AP看门狗 bit5 冲突
EOF

# ------------------------------------------------------------ 3. 只动 gpio186
echo
echo "########## 3. 只把 gpio$PIN_B 拉低（gpio$PIN_EN 仍不动） ##########"
ask "拉低 gpio$PIN_B，再写一次 TX EN？"

gpio186_hold 0
sleep 0.1
echo "--- gpio$PIN_B 拉低后 ---"
dump
echo "  再写一次 TX EN ..."
w16 0x7c 0x0001 || die "写 0x007C 失败"
sleep 0.3
echo "--- 第二次写 TX EN 之后 ---"
dump

if [[ "$(r8 0x4d)" == "$MODE_TX" ]]; then
    echo
    echo "=============================================================="
    echo " *** 成功: MODE = 0x04（gpio$PIN_B 是 Boost / 第二路电源）***"
    echo " 检查笔是否充电。按 Enter 结束（gpio$PIN_B 会恢复 high）。"
    echo "=============================================================="
    read -r _ </dev/tty
else
    printf '\n仍然失败: MODE = %s\n\n' "$(h8 0x4d)"
    echo "下一步方向："
    echo "  - 看上面列出的 pending 中断位（尤其 bit0 = EPT Type）；"
    echo "  - Tx 需要外部 Boost，若 IC 的 PWM 脚没能启动 Boost，可能一直 LVP；"
    echo "  - 也可能要先写 user register（指南 5.4.1 第 3 步）才允许 TX EN。"
fi

echo
echo "实验结束。"
