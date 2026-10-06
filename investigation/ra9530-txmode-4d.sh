#!/usr/bin/env bash
#
# ra9530-txmode-4d.sh — 按 Google Pixel 驱动的方式使能 Tx
#
# 依据：kernel/google-modules/bms, p9221_chip.c  ra9530_chip_tx_mode()
#   #define P9412_TX_CMD_REG          0x4D
#   #define P9412_TX_CMD_TX_MODE_EN   BIT(7)   (= 0x80)
#   #define P9XXX_SYS_OP_MODE_TX_MODE 0x08     (进入 Tx 后的模式值)
#   #define RA9530_PLIM_REG           0x2F0
#   #define RA9530_PLIM_900MA         0x384
#
#   流程（与驱动一致）：
#     1. write_16(0x2F0, 0x384)      // ping 阶段电流限值 900mA（先做，失败不致命）
#     2. write_8 (0x004D, 0x80)      // ★ Tx 模式使能（注意：单字节写！）
#     3. 轮询 0x004D，等待其变为 0x08
#
# 注意：确认线圈上只有手写笔，不要放金属异物（Tx 会真的开始发射）。
#
# 用法: sudo ./ra9530-txmode-4d.sh

set -u

ADDR=0x3b
I2C_BUS=""
WAIT_MS=${WAIT_MS:-3000}

die() { printf '\n!! %s\n' "$*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die "需要 root: sudo $0"
for d in /sys/bus/i2c/devices/i2c-*; do
    [[ -e "$d/of_node" ]] || continue
    [[ "$(readlink -f "$d/of_node")" == *"i2c@89c000"* ]] && I2C_BUS="${d##*-}"
done
[[ -n "$I2C_BUS" ]] || die "没找到 89c000.i2c (&i2c7)"

rd()   { i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 "$1" "r$2" 2>/dev/null; }
rd8()  { local a; a=$(rd "$1" 1); echo "${a:-??}"; }
rd16() { local a b; read -r a b <<<"$(rd "$1" 2)"; [[ "$a" == 0x* && "$b" == 0x* ]] && printf '%d' $(( ${b#0x}*0 + 0x${b#0x}*256 )) 2>/dev/null; }
wr8()  { i2ctransfer -f -y "$I2C_BUS" "w3@${ADDR}" 0x00 "$1" "$(printf '0x%02x' $(( $2 & 0xff )))" 2>&1; }
wr16() { i2ctransfer -f -y "$I2C_BUS" "w4@${ADDR}" 0x00 "$1" \
         "$(printf '0x%02x' $(( $2 & 0xff )))" "$(printf '0x%02x' $(( ($2>>8) & 0xff )))" 2>&1; }
rda16() { local a b; read -r a b <<<"$(rd "$1" 2)"; [[ "$a" == 0x* && "$b" == 0x* ]] && printf '%d' $(( 0x${b#0x}*256 + 0x${a#0x} )); }
ms()   { sleep "$(printf '%d.%03d' $(( $1 / 1000 )) $(( $1 % 1000 )))"; }

echo "=============================================================="
printf ' RA9530 Tx 使能（写 0x004D = 0x80）  i2c-%s  %s Hz\n' "$I2C_BUS" \
  "$(od -An -tu4 --endian=big /sys/bus/i2c/devices/i2c-$I2C_BUS/of_node/clock-frequency 2>/dev/null | tr -d ' ')"
echo "=============================================================="

echo
echo "########## 0. 基线 ##########"
printf '  CHIP_ID   = %s\n' "$(rd 0x0000 2)"
printf '  MODE(4D)  = %s     <- 期望写完后变成 0x08\n' "$(rd8 0x4d)"
printf '  TX_STAT   = %s\n' "$(rd8 0x7e)"
printf '  IRQ(30)   = %s\n' "$(rd 0x0030 4)"
printf '  Vin(80)   = %s\n' "$(rd 0x0080 2)"
printf '  PLIM(2F0) = %s   (试试高区寄存器现在能不能访问)\n' "$(rd 0x02f0 2)"

echo
echo "########## 1. 写 PLIM(0x2F0) = 0x0384 (900mA) ##########"
out=$(wr16 0x02f0 0x0384); echo "  $out"
ms 20
printf '  回读 = %s\n' "$(rd 0x02f0 2)"

echo
echo "########## 2. ★ 写 0x004D = 0x80（Tx 模式使能，单字节）##########"
out=$(wr8 0x4d 0x80); echo "  $out"
ms 20

echo
echo "########## 3. 轮询 0x004D，等待 0x08 ##########"
t=0; seen=0
while [[ $t -lt $WAIT_MS ]]; do
    m=$(rd8 0x4d)
    printf '  t=%4dms  MODE=%s  TX_STAT=%s  IRQ=%s\n' "$t" "$m" "$(rd8 0x7e)" "$(rd 0x0030 4)" | sed 's/0x00 0x00 0x00 0x00/0/'
    if [[ "$m" == "0x08" || "$m" == "8" ]]; then seen=1; break; fi
    ms 100; t=$((t + 100))
done

echo
echo "########## 结果 ##########"
m=$(rd8 0x4d)
if [[ "$seen" -eq 1 ]]; then
    echo "  *** 成功！MODE = 0x08 = TX Mode —— 芯片正在发射 ***"
    echo
    echo "  按驱动的后续步骤，还可以配置（可选）："
    echo "    0x00A0 = TX OCP (过流保护，驱动用 1400mA)"
    echo "    0x00D4 = Tx FOD 阈值 (异物检测，驱动用 1600mW)"
    echo "    0x0094 = 最低频率 (120kHz)"
    echo
    echo "  现在把笔吸在机身上，用手轻触屏幕看它能不能唤醒/画线。"
else
    echo "  MODE  = $m  (未变成 0x08)"
    echo "  TX_STAT = $(rd8 0x7e)"
    echo
    echo "  若 0x004D 写不进去或模式不变，可再试这些变体："
    echo "    - 16 位写: i2ctransfer -f -y $I2C_BUS w4@$ADDR 0x00 0x4d 0x80 0x00"
    echo "    - 其它可能的值: 0x08 / 0x80|0x08 = 0x88"
    echo "    - 先按老流程走上电时序（两脚低->gpio11 高->50ms->gpio186 高）再写"
fi
