#!/usr/bin/env bash
#
# ra9530-soc-hunt.sh — 用实验找出"笔的电量"到底在哪个寄存器/哪个字节
#
# 思路：
#   笔正在充电 -> 它的电量读数应当随时间【缓慢上升】。
#   所以：把一批候选寄存器（以及 0x0050~0x005F 那 16 字节包体）周期性读出来，
#   哪个值在 0..100 之间、并且随时间往上爬 —— 它就是候选。
#
#   预期参照：0x003A（同族驱动里的 REG_CHG_STATUS，我们当前读到的恒为 0x00）。
#   若 0x003A 始终不动、而别的字节在爬，说明这颗客户定制版的电量在别处。
#
# 注意：脚本【故意不读 0x0030】—— 那个中断寄存器很可能是"读即清"，
#       多读会把驱动的中断事件吃掉。
#
# 用法:
#   sudo ./ra9530-soc-hunt.sh                       # 默认 30 分钟，每 60 秒一轮
#   DURATION=3600 INTERVAL=30 sudo ./ra9530-soc-hunt.sh
#
# 建议同时把笔吸在机身上让它一直充。

set -u

ADDR=0x3b
I2C_BUS=""
DURATION=${DURATION:-1800}
INTERVAL=${INTERVAL:-60}

# 候选单字节寄存器
REGS_1="0x0002 0x0003 0x003a 0x003c 0x003d 0x003e 0x0040 0x0046 0x004b 0x004d
        0x0074 0x0078 0x00a2 0x00a4 0x00a5 0x00a6 0x007a"
# 候选 16 位（小端）
REGS_2="0x0044 0x006e 0x0070 0x0080 0x0082 0x0084 0x00e0 0x00e2"
PKT_REG=0x0050
PKT_LEN=16

die() { printf '\n!! %s\n' "$*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die "需要 root: sudo $0"
for d in /sys/bus/i2c/devices/i2c-*; do
    [[ -e "$d/of_node" ]] || continue
    [[ "$(readlink -f "$d/of_node")" == *"i2c@89c000"* ]] && I2C_BUS="${d##*-}"
done
[[ -n "$I2C_BUS" ]] || die "没找到 89c000.i2c (&i2c7)"

r1() { local a err; a=$(i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 "$1" r1 2>&1)
       if [[ "$a" == 0x* ]]; then printf '%d' "$a"; return; fi
       # 首次失败时把真实错误打出来，别再让它变成一串 -1
       if [[ ${warned:-0} -eq 0 ]]; then
           warned=1
           printf '\n!! 读 %s 失败：%s\n' "$1" "$a" >&2
           printf '   若提示 busy / marked used，请确认用的是 i2ctransfer -f（驱动占用该地址时必须）\n' >&2
       fi
       echo -1; }
r2() { local a b; read -r a b <<<"$(i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 "$1" r2 2>/dev/null)"
       [[ "$a" == 0x* && "$b" == 0x* ]] && printf '%d' $(( 0x${b#0x}*256 + 0x${a#0x} )) || echo -1; }
rpkt() { i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 0x50 r16 2>/dev/null; }

declare -A prev1 prev2
round=0
echo "=============================================================="
echo " RA9530 电量猎手   $(date '+%F %T')"
printf ' 时长 %ds / 每 %ds 一轮；笔请一直吸在机身上\n' "$DURATION" "$INTERVAL"
echo "=============================================================="

t=0
while [[ $t -le $DURATION ]]; do
    round=$((round + 1))
    show_all=0
    [[ $round -eq 1 || $((round % 10)) -eq 1 ]] && show_all=1

    printf '\n---------- t=%4ds  第 %d 轮%s ----------\n' "$t" "$round" \
        "$([[ $show_all -eq 1 ]] && echo "（完整）" || echo "（只显示变化）")"

    changed=0
    for r in $REGS_1; do
        v=$(r1 "$r")
        p=${prev1[$r]:-NA}
        mark=""
        if [[ "$v" != "$p" && "$p" != "NA" ]]; then
            mark="$([[ "$v" -gt "$p" ]] && echo " ↑上升" || echo " ↓下降")"
            changed=1
        fi
        if [[ $show_all -eq 1 || -n "$mark" ]]; then
            star=""; [[ "$v" -ge 0 && "$v" -le 100 ]] && star=" *候选(0-100)"
            printf '   %-8s = %4s%s%s\n' "$r" "$v" "$star" "$mark"
        fi
        prev1[$r]=$v
    done

    for r in $REGS_2; do
        v=$(r2 "$r")
        p=${prev2[$r]:-NA}
        mark=""
        if [[ "$v" != "$p" && "$p" != "NA" ]]; then
            mark="$([[ "$v" -gt "$p" ]] && echo " ↑上升" || echo " ↓下降")"
            changed=1
        fi
        if [[ $show_all -eq 1 || -n "$mark" ]]; then
            printf '   %-8s = %4s (16bit)%s\n' "$r" "$v" "$mark"
        fi
        prev2[$r]=$v
    done

    # 包体逐字节（每轮都打，这是最可疑的地方）
    pkt=$(rpkt)
    printf '   0x0050~0x005F 包体: '
    i=0
    for b in $pkt; do
        d=$((b))
        printf '%s:%d ' "$(printf '5%x' "$i")" "$d"
        i=$((i + 1))
    done
    echo

    if [[ $show_all -eq 0 && $changed -eq 1 ]]; then
        echo "   （以上为本轮发生变化的值）"
    fi

    sleep "$INTERVAL"; t=$((t + INTERVAL))
done

echo
echo "=============================================================="
echo " 汇总：所有【在 0..100 之间且上升过】的单字节寄存器"
echo "=============================================================="
echo "  0x003A 若始终为 0，而别的项在上升，请把整段输出贴回来 ——"
echo "  我们在包体里找那个稳定的、缓慢增长的字节。"
