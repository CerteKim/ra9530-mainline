#!/usr/bin/env bash
#
# ra9530-reboot-state.sh — 芯片状态能否跨热重启存活？以及跨重启的寄存器快照比对
#
# 用途（两个实验共用）：
#
#   实验一：热重启是否保留芯片 SRAM
#       sudo ./ra9530-reboot-state.sh mark  before
#       sudo reboot                     # 热重启（不是关机再开机！）
#       sudo ./ra9530-reboot-state.sh check before
#     -> 若标记 0xDEADBEEF 还在，说明芯片未在引导阶段被断电 => 可以做实验二
#
#   实验二：看 Windows 把芯片留在什么状态（关键实验）
#       1) 在 Linux:  sudo ./ra9530-reboot-state.sh mark  linux
#       2) 重启进 Windows，把笔吸上，确认它在充电（笔活过来）
#       3) Windows 里「开始 -> 重启」（热重启，不要关机！）进 Linux
#       4) 立刻:      sudo ./ra9530-reboot-state.sh check linux
#     -> 输出会列出所有与基线不同的寄存器；重点看 MODE(0x4D) 是不是 0x04
#
# 用法:
#   sudo ./ra9530-reboot-state.sh mark  <名字>
#   sudo ./ra9530-reboot-state.sh check <名字>

set -u

ADDR=0x3b
I2C_BUS=""
STATE_DIR="$(dirname "$(readlink -f "$0")")"

die() { printf '\n!! %s\n' "$*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die "需要 root: sudo $0 <mark|check> <名字>"
MODE_ARG=${1:-}; NAME=${2:-}
[[ "$MODE_ARG" == "mark" || "$MODE_ARG" == "check" ]] || die "用法: sudo $0 <mark|check> <名字>"
[[ -n "$NAME" ]] || die "请给个名字，例如 before / linux"

for d in /sys/bus/i2c/devices/i2c-*; do
    [[ -e "$d/of_node" ]] || continue
    [[ "$(readlink -f "$d/of_node")" == *"i2c@89c000"* ]] && I2C_BUS="${d##*-}"
done
[[ -n "$I2C_BUS" ]] || die "没找到 89c000.i2c (&i2c7)"

rd()  { i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 "$1" "r$2" 2>/dev/null; }
rd8() { local a; a=$(rd "$1" 1); echo "${a:-??}"; }
rd16(){ local a b; read -r a b <<<"$(rd "$1" 2)"; [[ "$a" == 0x* ]] && printf '0x%s%s' "${b#0x}" "${a#0x}" || echo "??"; }
rd32(){ local a b c d; read -r a b c d <<<"$(rd "$1" 4)"
        [[ "$a" == 0x* && "$d" == 0x* ]] && printf '0x%s%s%s%s' "${d#0x}" "${c#0x}" "${b#0x}" "${a#0x}" || echo "??"; }
wr()  { i2ctransfer -f -y "$I2C_BUS" "w$((2 + $# - 1))@${ADDR}" 0x00 "$@"; }

# 要快照的寄存器（覆盖身份/状态/中断/Tx 参数/FOD）
REGS="0x0000:2   0x0002:1   0x0003:1   0x0028:4   0x0030:4   0x0034:4
      0x003a:1   0x004d:1   0x0050:8   0x0058:8   0x007a:2   0x007c:2
      0x007e:1   0x0080:2   0x0082:2   0x0084:2   0x00d2:1   0x00e0:2
      0x00e2:2   0x00e4:1   0x00e8:2   0x00ec:2   0x00f8:2   0x00fa:2
      0x00fc:2   0x0108:2  0x0114:2  0x0118:2"

snapshot() {   # $1 = 文件名
    : > "$1"
    for spec in $REGS; do
        r=${spec%%:*}; n=${spec##*:}
        printf '%s\t%s\n' "$r" "$(rd "$r" "$n")" >> "$1"
    done
}

FILE_MARK="$STATE_DIR/.ra9530-state-$NAME.txt"
FILE_SNAP="$STATE_DIR/.ra9530-snapshot-$NAME.txt"
MARKER='0xde 0xad 0xbe 0xef'

echo "=============================================================="
printf ' RA9530 跨重启状态 %s    (i2c-%s, %s Hz, 名字=%s)\n' "$MODE_ARG" "$I2C_BUS" \
  "$(od -An -tu4 --endian=big /sys/bus/i2c/devices/i2c-$I2C_BUS/of_node/clock-frequency 2>/dev/null | tr -d ' ')" "$NAME"
echo "=============================================================="

# 芯片在不在
if [[ "$(rd8 0x4d)" == "??" ]]; then
    die "芯片无应答 —— gpio11 (开关) 是不是被拉低了？"
fi

if [[ "$MODE_ARG" == "mark" ]]; then
    echo
    echo "把标记写入 0x0050（私有数据缓冲，安全）：DE AD BE EF"
    wr 0x50 $MARKER
    sleep 0.05
    printf '  写回读 = %s\n' "$(rd 0x50 8)"
    printf '  MODE = %s\n' "$(rd8 0x4d)"
    snapshot "$FILE_SNAP"
    printf '  已保存 %d 个寄存器快照 -> %s\n' "$(wc -l < "$FILE_SNAP")" "$FILE_SNAP"
    echo
    echo "下一步：sudo reboot（热重启，别关机）"
    echo "        重启后：sudo $0 check $NAME"
else
    echo
    printf '0x0050 现状        : %s\n' "$(rd 0x50 8)"
    printf '  MODE             : %s\n' "$(rd8 0x4d)"
    printf '  TX_STAT (0x007E) : %s\n' "$(rd8 0x7e)"
    printf '  IRQ    (0x0030)  : %s\n' "$(rd32 0x30)"
    printf '  IRQ_EN (0x0034)  : %s\n' "$(rd32 0x34)"
    echo
    if [[ -f "$FILE_MARK" ]]; then
        prev=$(cat "$FILE_MARK")
        [[ "$(rd 0x50 8)" == "$prev" ]] && echo "  >>> 标记仍在（与上次记录一致）" || echo "  >>> 标记已变（上次: $prev）"
    fi
    cur=$(rd 0x50 8)
    if [[ "$cur" == "0xde 0xad 0xbe 0xef 0x00 0x00 0x00 0x00" ]]; then
        echo "  >>> *** 0xDEADBEEF 完好：芯片 SRAM 跨过了这次重启（未被断电）***"
    else
        echo "  >>> 标记不在（内容: $cur）→ 芯片在引导阶段被断电/复位了"
    fi

    if [[ -f "$FILE_SNAP" ]]; then
        echo
        echo "########## 与基线快照的差异 ##########"
        diffout=$(diff "$FILE_SNAP" <(snapshot /dev/stdout) 2>/dev/null || true)
        printf '%s\n' "$diffout" | sed 's/^/  /'
        if [[ -z "$diffout" ]]; then
            echo "  （完全一致 —— 所有被观测的寄存器都和基线相同）"
        fi
        echo
        echo "  重点核对：0x004d 若为 0x04，说明芯片被留在了 TRx（正在发射）状态"
    else
        echo "  （没找到基线快照 $FILE_SNAP，无法比对）"
    fi
fi
