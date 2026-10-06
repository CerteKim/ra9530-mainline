#!/usr/bin/env bash
#
# ra9530-txparams.sh — 读全 RA9530 的 Tx 参数寄存器，判断"芯片是不是根本没被配置"。
#
# 背景：
#   * MODE(0x004D) = 0x80 = "Back Powered"，Tx 未使能
#   * TX Status(0x007E) bit1 = 0 -> 芯片不 ready，所以 0x007C 的 TX EN 不被受理
#   * VOUT 供电 7044mV（TRx 需 7-9V，达标）、结温 33C、I2C 写入已验证可靠
#   * gpio186 上升沿 / gpio11 断电重启都无效 -> gpio186 不是 GP2/TX_EN
#
# 本脚本要回答：Tx 参数寄存器（ping/阈值/频率）是否为空？
#   若为空 -> 芯片从未被配置过 Tx，需要先写这些参数（或找回固件里的默认值）
#   若非空 -> 参数没问题，卡点在别处（GP2 / EEPROM 里 TRx 被禁用 等）
#
# 另外做一次 0x007C 的"写后立即读回"：
#   自清除寄存器若读到 bit0=1，说明写落地了但芯片没处理；
#   若立即读到 0，说明或没写进去、或被立刻清掉。
#
# 依赖: i2c-tools；用法: sudo ./ra9530-txparams.sh

set -u

ADDR=0x3b
I2C_BUS=""

die() { printf '\n!! %s\n' "$*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die "需要 root: sudo $0"
command -v i2ctransfer >/dev/null || die "缺 i2ctransfer"

for d in /sys/bus/i2c/devices/i2c-*; do
    [[ -e "$d/of_node" ]] || continue
    [[ "$(readlink -f "$d/of_node")" == *"i2c@89c000"* ]] && I2C_BUS="${d##*-}"
done
[[ -n "$I2C_BUS" ]] || die "没找到 89c000.i2c (&i2c7)"

raw() { i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 "$1" "r$2" 2>&1; }

val() {  # $1=reg $2=len -> 十进制 或 ERR
    local reg=$1 len=$2 b
    b=$(raw "$reg" "$len")
    [[ "$b" == 0x* ]] || { echo ERR; return; }
    # shellcheck disable=SC2086
    set -- $b
    case "$len" in
        1) printf '%d' "$1" ;;
        2) printf '%d' $(( $2 << 8 | $1 )) ;;
        4) printf '%d' $(( $4 << 24 | $3 << 16 | $2 << 8 | $1 )) ;;
    esac
}

# reg:len:name
TABLE="
0x004D:1:System Operating Mode
0x007E:1:TX Status
0x007A:2:Tx EPT Type
0x007C:2:TX System Command
0x0080:2:Vin (mV)
0x0082:2:Vrect (mV)
0x0084:2:Die Temperature (C)
0x0086:2:Operating Frequency
0x0088:2:Digital Ping Frequency
0x00B0:2:Tx Manufacturer Code
0x00B3:1:TX Guaranteed Power
0x00B6:1:TX WPC Revision ID
0x00B7:1:Re-Negotiation Status
0x00D2:1:Q-FACTOR
0x00D3:1:Signal Strength Packet
0x00E0:2:Ping Interval
0x00E2:2:Ping Frequency
0x00E4:1:Ping Duty Setting
0x00E8:2:Over Voltage Threshold
0x00EC:2:Low Voltage Threshold
0x00F8:2:FOD Low Segment Threshold
0x00FA:2:FOD High Segment Threshold
0x00FC:2:FOD Segment Threshold
0x0108:2:Over Current Threshold
0x0114:2:Min Operating Freq in FB
0x0116:2:Min Operating Freq in HB
0x0118:2:Max Operating Frequency
0x011A:1:Minimum Duty
0x0156:2:TX DC Power
0x0182:2:Operating Frequency (shadows)
0x018C:1:Operating Duty-Cycle
"

echo "=============================================================="
echo " RA9530 Tx 参数寄存器全扫 (i2c-$I2C_BUS)"
echo "=============================================================="
echo
printf '  %-30s %-8s %-8s %s\n' "寄存器" "地址" "长度" "值"
echo "  --------------------------------------------------------------------"

zeros=0
total=0
while IFS=: read -r reg len name; do
    [[ -z "${reg:-}" ]] && continue
    v=$(val "$reg" "$len")
    total=$((total + 1))
    if [[ "$v" == "0" ]]; then
        zeros=$((zeros + 1))
        printf '  %-30s %-8s %-8s %s   <-- 0\n' "$name" "$reg" "$len" "$v"
    else
        printf '  %-30s %-8s %-8s %s\n' "$name" "$reg" "$len" "$v"
    fi
done <<< "$TABLE"

echo
echo "  $zeros / $total 个寄存器为 0"

# ------------------------------------------------------------------ 写后立即读回
echo
echo '########## 0x007C 写后立即读回（区分「没写进去」和「写了被忽略」） ##########'
printf '  写前 0x007C = %s\n' "$(raw 0x7c 2)"
printf '  写前 0x007E = %s\n' "$(raw 0x7e 1)"

i2ctransfer -f -y "$I2C_BUS" "w4@${ADDR}" 0x00 0x7c 0x01 0x00 || die "写 0x007C 失败"
r1=$(raw 0x7c 2)
r2=$(raw 0x7e 1)
r3=$(raw 0x4d 1)
printf '  写完立刻读     0x007C = %s\n' "$r1"
printf '  写完立刻读     0x007E = %s\n' "$r2"
printf '  写完立刻读     0x004D = %s\n' "$r3"

sleep 0.3
printf '  300ms 后读     0x007C = %s\n' "$(raw 0x7c 2)"
printf '  300ms 后读     0x007E = %s\n' "$(raw 0x7e 1)"
printf '  300ms 后读     0x004D = %s\n' "$(raw 0x4d 1)"

cat <<'EOF'

判读:
  * 0x007C 立刻读回 0x01 0x00 -> 写进去了，但芯片没处理（不 ready / 被禁用）
  * 0x007C 立刻读回 0x00 0x00 -> 要么没写进去，要么芯片立刻清了（自清除）
  * 大量 Tx 参数寄存器 = 0     -> 芯片从未被配置过 Tx，这才是根因方向
EOF
