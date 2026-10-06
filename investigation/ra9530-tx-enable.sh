#!/usr/bin/env bash
#
# ra9530-tx-enable.sh — 用三个参考实现的做法，逐一尝试使能 Tx
#
# 参考来源：
#   [A] kernel/google-modules/bms  p9221_chip.c  ra9530_chip_tx_mode()
#       —— Google Pixel 上【专为 RA9530 写的】代码，权威性最高
#         #define P9412_TX_CMD_REG         0x4D
#         #define P9412_TX_CMD_TX_MODE_EN  BIT(7)   // = 0x80
#         #define RA9530_PLIM_REG          0x2F0
#         #define RA9530_PLIM_900MA        0x384
#         #define P9XXX_SYS_OP_MODE_TX_MODE 0x08
#         流程: write_16(0x2F0,0x384) -> write_8(0x4D,0x80) -> 等 0x4D 变 0x08
#
#   [B] github.com/nik012003/idtp9418-mainline   (P9418，小米平板在用)
#         #define REG_TX_CMD   0x0076
#         #define REG_TX_DATA  0x0078
#         #define TX_EN        BIT(0)
#         #define TX_FOD_EN    BIT(5)
#         流程: write_8(0x76, TX_EN|TX_FOD_EN=0x21) -> 读 0x78 看 BIT(0)，重试 3 次
#
#   [C] Renesas 评估手册的 TX 寄存器表（我们之前一直照它做，但没成功）
#         TX System Command 0x007C bit0 = TX EN
#
# 三个的差别正好是"寄存器地址到底在哪"，所以一次性全试，看哪个能让芯片真的进 Tx。
#
# 前置条件（本脚本会自己确保）：gpio11 开关 = 高、gpio186 升压 = 高、笔已吸附。
# 用法: sudo ./ra9530-tx-enable.sh

set -u

ADDR=0x3b
I2C_BUS=""
GPIO_CHIP_LABEL="3100000.pinctrl"
PIN_EN=11
PIN_BOOST=186
TLMM_BASE=""
RETRIES=3

die() { printf '\n!! %s\n' "$*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die "需要 root: sudo $0"
for d in /sys/bus/i2c/devices/i2c-*; do
    [[ -e "$d/of_node" ]] || continue
    [[ "$(readlink -f "$d/of_node")" == *"i2c@89c000"* ]] && I2C_BUS="${d##*-}"
done
[[ -n "$I2C_BUS" ]] || die "没找到 89c000.i2c (&i2c7)"
for c in /sys/class/gpio/gpiochip*; do
    [[ "$(cat "$c/label" 2>/dev/null)" == "$GPIO_CHIP_LABEL" ]] && TLMM_BASE=$(cat "$c/base")
done

rd()   { i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 "$1" "r$2" 2>/dev/null; }
rd8()  { local a; a=$(rd "$1" 1); echo "${a:-??}"; }
hex8() { printf '0x%02x' "$1"; }
wr8()  { i2ctransfer -f -y "$I2C_BUS" "w3@${ADDR}" 0x00 "$1" "$(hex8 $(( $2 & 0xff )))" 2>&1; }
wr16() { i2ctransfer -f -y "$I2C_BUS" "w4@${ADDR}" 0x00 "$1" "$(hex8 $(( $2 & 0xff )))" "$(hex8 $(( ($2>>8) & 0xff )))" 2>&1; }
ms()   { sleep "$(printf '%d.%03d' $(( $1 / 1000 )) $(( $1 % 1000 )))"; }

gpio_path() { echo "/sys/class/gpio/gpio$(( TLMM_BASE + $1 ))"; }
gpio_prep() { local p; p=$(gpio_path "$1")
    [[ -d "$p" ]] || { echo "$(( TLMM_BASE + $1 ))" > /sys/class/gpio/export 2>/dev/null; sleep 0.05; }
    echo high > "$p/direction" 2>/dev/null; }
gpio_set() { echo "$2" > "$(gpio_path "$1")/value" 2>/dev/null; }
gpio_get() { cat "$(gpio_path "$1")/value" 2>/dev/null || echo "?"; }
restore() { local rc=$?
    gpio_prep "$PIN_EN"; gpio_prep "$PIN_BOOST"; sleep 0.05
    printf '\n[cleanup] gpio%s=%s gpio%s=%s\n' "$PIN_EN" "$(gpio_get "$PIN_EN")" "$PIN_BOOST" "$(gpio_get "$PIN_BOOST")"
    local o; for o in "$PIN_EN" "$PIN_BOOST"; do echo "$(( TLMM_BASE + o ))" > /sys/class/gpio/unexport 2>/dev/null; done
    exit $rc; }
trap restore EXIT INT TERM

status_line() { printf '    MODE(4D)=%s  0x76=%s  0x78=%s  0x7C=%s  0x7E=%s  IRQ(30)=%s\n' \
    "$(rd8 0x4d)" "$(rd8 0x76)" "$(rd8 0x78)" "$(rd 0x7c 2)" "$(rd8 0x7e)" "$(rd 0x30 4)"; }
is_tx() { local m; m=$(rd8 0x4d); [[ "$m" == "0x08" || "$m" == "0x8" || "$m" == "8" ]]; }

echo "=============================================================="
printf ' RA9530 Tx 使能三条路线对比   i2c-%s  %s Hz\n' "$I2C_BUS" \
  "$(od -An -tu4 --endian=big /sys/bus/i2c/devices/i2c-$I2C_BUS/of_node/clock-frequency 2>/dev/null | tr -d ' ')"
echo "  参考: [A] Google ra9530_chip_tx_mode  [B] nik012003/idtp9418  [C] Renesas 评估手册"
echo "=============================================================="

SUCCESS=""
gpio_prep "$PIN_EN"; gpio_prep "$PIN_BOOST"
gpio_set "$PIN_EN" 1; gpio_set "$PIN_BOOST" 1
ms 100
printf '  gpio%s=%s gpio%s=%s (开关/升压应为 1)  芯片ID=%s\n' \
    "$PIN_EN" "$(gpio_get "$PIN_EN")" "$PIN_BOOST" "$(gpio_get "$PIN_BOOST")" "$(rd 0x0000 2)"

echo
echo "########## 寄存器结构速览（0x74 ~ 0x7F，看两个芯片的地址如何对映）##########"
printf '  0x74..0x77 = %s\n' "$(rd 0x0074 4)"
printf '  0x78..0x7B = %s\n' "$(rd 0x0078 4)"
printf '  0x7C..0x7F = %s\n' "$(rd 0x007c 4)"
echo
echo "########## 基线 ##########"; status_line

try_and_poll() {   # $1=标签 $2=描述
    echo
    echo "########## $1 ##########"
    echo "  $2"
    local i=0
    while [[ $i -lt $RETRIES ]]; do
        i=$((i + 1))
        printf '  --- 第 %d/%d 次 ---\n' "$i" "$RETRIES"
        "$3"     # 通过函数名执行写入动作
        ms 50
        status_line
        if is_tx; then echo "  *** MODE = 0x08 = TX Mode，成功！***"; return 0; fi
        if [[ "$(rd8 0x78)" == "0x01" ]]; then echo "  *** 0x78 bit0 = 1（P9418 驱动判据），可能已启动 ***"; return 0; fi
    done
    return 1
}

# ---------- [A] Google 的 RA9530 实现 ----------
act_A() {
    wr16 0x02f0 0x0384 >/dev/null   # PLIM 900mA（高区寄存器，可能失败，不致命）
    wr8  0x4d   0x80                # ★ Tx 模式使能
}
if try_and_poll "[A] Google ra9530_chip_tx_mode：写 0x4D = 0x80" \
   "先 0x2F0=0x0384(PLIM)，再单字节写 0x4D=0x80，然后等 0x4D 变成 0x08" act_A; then
    SUCCESS="A（0x4D = 0x80）"
fi

# ---------- [B] nik012003 的 P9418 实现 ----------
if [[ -z "${SUCCESS:-}" ]]; then
act_B() { wr8 0x76 0x21; }          # TX_EN|TX_FOD_EN
if try_and_poll "[B] nik012003/idtp9418（P9418 路线）：写 0x76 = 0x21" \
   "写 0x0076 = TX_EN|TX_FOD_EN (0x21)，然后看 0x78 的 bit0" act_B; then
    SUCCESS="B（0x76 = 0x21）"
fi
fi

# ---------- [C] Renesas 手册路线 ----------
if [[ -z "${SUCCESS:-}" ]]; then
act_C() { wr16 0x007c 0x0001; }     # 手册：TX System Command bit0 = TX EN
if try_and_poll "[C] Renesas 评估手册：写 0x7C = 0x0001" \
   "这是我们之前一直用的写法（16 位）" act_C; then
    SUCCESS="C（0x7C = 0x0001）"
fi
fi

echo
echo "=============================================================="
if [[ -n "${SUCCESS:-}" ]]; then
    echo " 结果：路线 $SUCCESS 成功，芯片进入 Tx。"
    echo
    echo " 接下来：把笔吸上，用手轻触屏幕看它是否被唤醒/能画线。"
    echo " 若要复刻成驱动，可参照 Google 的 ra9530_chip_tx_mode() 顺序，并补上："
    echo "   - FOD 阈值（本芯片在 0xF8/0xFA/0xFC，已配置为 -100mW 档）"
    echo "   - TX OCP / 最低频率限制"
    echo "   - 退出 Tx：chip_set_cmd(P9412_CMD_TXMODE_EXIT = BIT(9)) 写 COM 寄存器 0x4E"
else
    echo " 三条路线都没能进入 Tx。"
    echo " 最后状态："; status_line
    echo
    echo " 可继续尝试的方向："
    echo "   1) 先走上电时序（两脚低->gpio11 高->50ms->gpio186 高）再写 0x4D=0x80"
    echo "   2) 0x4D 用 16 位写： w4 0x00 0x4d 0x80 0x00"
    echo "   3) 命令寄存器 0x4E(COM)：参照 p9221 的 chip_set_cmd，写 16 位命令码"
    echo "      （P9412_CMD_TXMODE_EXIT = BIT(9) 是退出Tx；进入Tx的命令码需查 p9221_chip.c）"
fi
