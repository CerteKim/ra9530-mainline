#!/usr/bin/env bash
#
# verify-ra9530.sh — 对 Xiaomi Book S 12.4 (SC8180X) 上磁吸笔无线充电 IC
#                    Renesas RA9530 做纯只读探测。
#
# 器件位置: &i2c7 (89c000.i2c, QUP7) 地址 0x3b, chip id 0x9530
# 协议    : 16 位大端寄存器地址 + 数据 (多字节小端)
#
# 本脚本【绝对不写任何寄存器】。只用 i2ctransfer 的读事务。
#
# 用法: sudo ./verify-ra9530.sh

set -u

ADDR=0x3b
BUS=""

if [[ ${EUID} -ne 0 ]]; then
    echo "错误: 需要 root 才能访问 /dev/i2c-*  ->  sudo $0" >&2
    exit 1
fi

command -v i2ctransfer >/dev/null 2>&1 || {
    echo "错误: 缺 i2ctransfer, 先装 i2c-tools (sudo pacman -S i2c-tools)" >&2
    exit 1
}

# ---------------------------------------------------------------- 找总线号
for d in /sys/bus/i2c/devices/i2c-*; do
    [[ -e "$d/of_node" ]] || continue
    node=$(readlink -f "$d/of_node")
    if [[ "$node" == *"i2c@89c000"* ]]; then
        BUS="${d##*-}"
        break
    fi
done

if [[ -z "$BUS" ]]; then
    echo "错误: 没找到 89c000.i2c (&i2c7) 对应的 i2c 总线" >&2
    exit 1
fi

freq=""
if [[ -r "/sys/bus/i2c/devices/i2c-${BUS}/of_node/clock-frequency" ]]; then
    freq=$(od -An -tu4 --endian=big \
           "/sys/bus/i2c/devices/i2c-${BUS}/of_node/clock-frequency" 2>/dev/null \
           | tr -d ' ')
fi

echo "=============================================================="
echo " RA9530 只读探测 (不写任何寄存器)"
echo " 总线: i2c-${BUS}  (${node})"
[[ -n "$freq" ]] && echo " 总线速率: ${freq} Hz"
echo " 地址: ${ADDR}"
echo "=============================================================="
echo

# ---------------------------------------------------------------- 读函数
# i2ctransfer 输出形如 "0x30 0x95"; 数据为小端。
read_bytes() {   # $1=reg(hex)  $2=长度
    i2ctransfer -f -y "$BUS" "w2@${ADDR}" 0x00 "$1" "r$2" 2>&1
}

read16() {       # $1=reg -> 十进制值, 失败回显 ERR
    local raw
    raw=$(read_bytes "$1" 2) || { echo "ERR"; return 1; }
    case "$raw" in
        0x*) ;;
        *)   echo "ERR"; return 1 ;;
    esac
    # shellcheck disable=SC2086
    set -- $raw
    printf '%d' $(( $2 << 8 | $1 ))
}

read8() {
    local raw
    raw=$(read_bytes "$1" 1) || { echo "ERR"; return 1; }
    case "$raw" in
        0x*) ;;
        *)   echo "ERR"; return 1 ;;
    esac
    printf '%d' $(( raw ))
}

show16() { printf '  %-14s (0x%02X) = %s\n' "$1" "$2" "$(read16 "$2")"; }
show8()  { printf '  %-14s (0x%02X) = %s\n' "$1" "$2" "$(read8  "$2")"; }

printf '  %-14s (0x%02X) = %s   <-- 期望 0x9530 小端\n' \
       "CHIP_ID" 0x00 "$(read_bytes 0x00 2)"
show8   "CHIP_REV"       0x02
show8   "CUSTOMER_ID"    0x03

echo
echo "---- 模式与状态 ----"
mode=$(read8 0x4C)
status=$(read16 0x34)

case "$mode" in
    0)   mtext="AC missing (从未被配置过)" ;;
    1)   mtext="WPC Basic Protocol" ;;
    2)   mtext="WPC Extended Protocol" ;;
    3)   mtext="Renesas Proprietary Protocol" ;;
    8)   mtext="*** TX MODE (已经在发射) ***" ;;
    9)   mtext="TX FOD (被异物检测停下)" ;;
    ERR) mtext="(读取失败)" ;;
    *)   mtext="未知值 $(printf '0x%02X' "$mode" 2>/dev/null)" ;;
esac

printf '  %-14s (0x%02X) = %s  %s\n' "SYSTEM_MODE" 0x4C "$mode" "$mtext"
printf '  %-14s (0x%02X) = %s\n' "STATUS" 0x34 "$status"

echo
echo "---- P9412 定义的 TX 寄存器区: RA9530 是否复用? ----"
show8   "TX_CMD"         0x4D
show16  "TXOCP"          0xA0
show16  "TX_FOD_THRSH"   0xD4
show8   "APBSTPING"      0xF0

echo
echo "---- 相关 GPIO 线 (使能脚 11/186, 中断脚 97/101/189) ----"
if command -v gpioinfo >/dev/null 2>&1; then
    if ! gpioinfo 2>/dev/null | grep -E 'line +(11|97|101|186|189):'; then
        echo "  (没列出这 5 条线)"
    fi
else
    echo "  (未装 libgpiod: sudo pacman -S libgpiod)"
fi

echo
echo "---- 总线健康度 ----"
irq=$(grep '89c000' /proc/interrupts | head -1)
if [[ -n "$irq" ]]; then
    printf '  %s\n' "$irq"
    printf '  -> 已发生 I2C 传输次数: %s\n' "$(echo "$irq" | awk '{print $2}')"
else
    echo "  (没找到 89c000.i2c 的中断行)"
fi

arb=$(dmesg 2>/dev/null | grep -c '89c000.i2c: Bus arbitration lost' || true)
echo "  geni_i2c 仲裁丢失报错累计: ${arb} 次"
if [[ "${arb:-0}" -gt 0 ]]; then
    echo "  -> 若本次探测又新增, 说明 1MHz + 密集访问会让 GENI 掉总线,"
    echo "     驱动阶段应把 i2c7 的 clock-frequency 降到 400000。"
fi

echo
echo "---- 刚产生的 i2c 相关 dmesg ----"
dmesg 2>/dev/null | tail -8 | sed 's/^/  /'

echo
echo "done. 把上面全部输出贴回给 agent。"
