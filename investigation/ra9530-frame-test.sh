#!/usr/bin/env bash
#
# ra9530-frame-test.sh — 验证 RA9530 的 I2C 写事务是否需要 CmdByte/CmdFlag 帧尾
#
# 动机（Design Guide R16UH0023EU0100 Figure 7/8）：
#   I2C 读/写事务的字节流是：
#     Slave(0x3B) + 2 字节寄存器地址 + DataByte_0..3 + CmdByte_0/1 + CmdFlag_0/1
#   我们一直只发「2 字节地址 + 2 字节数据」，寄存器内容确实被更新（读回一致），
#   但芯片从不【处理】这条命令（0x007C 的位永不自清除）。
#   假设：芯片用帧尾的 CmdFlag 区分「数据写入」与「命令触发」。
#
# 本脚本做两件事：
#   A) 结构探测：以 8 字节长度读 0x0050 / 0x0058 / 0x007C / 0x007E，
#      看看 Data/Cmd/Flag 各字段长什么样（读是零风险的）
#   B) 帧长试验：对 0x007C 用不同帧长（2 / 4 / 8 字节负载）写入 TX EN 位，
#      看哪一种能让芯片【处理】它（判据：该位被自动清零）
#
# 注意：0x007C 之后跟着 0x007E（TX Status，只读）。按帧长写入会自增到只读寄存器，
#       手册不建议写只读寄存器；这里用 0 填充，风险很低，但请知悉。
#
# 用法: sudo ./ra9530-frame-test.sh

set -u

ADDR=0x3b
I2C_BUS=""

die() { printf '\n!! %s\n' "$*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die "需要 root: sudo $0"
for d in /sys/bus/i2c/devices/i2c-*; do
    [[ -e "$d/of_node" ]] || continue
    [[ "$(readlink -f "$d/of_node")" == *"i2c@89c000"* ]] && I2C_BUS="${d##*-}"
done
[[ -n "$I2C_BUS" ]] || die "没找到 89c000.i2c (&i2c7)"

rd() { i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 "$1" "r$2" 2>&1; }

echo "=============================================================="
printf ' RA9530 I2C 帧格式探测 (i2c-%s，速率 %s Hz)\n' "$I2C_BUS" \
  "$(od -An -tu4 --endian=big /sys/bus/i2c/devices/i2c-$I2C_BUS/of_node/clock-frequency 2>/dev/null | tr -d ' ')"
echo "=============================================================="

echo
echo "########## A. 以 8 字节长度读各寄存器（看结构）##########"
for r in 0x0050 0x0058 0x007A 0x007C 0x007E 0x0030; do
    printf '  0x%s : %s\n' "$r" "$(rd "$r" 8)"
done
echo
echo "  说明：若 Cmd/Flag 字段有固定模式（例如尾部出现非零值），就说明帧尾是有意义的。"

echo
echo "########## B. 帧长试验：写 0x007C = TX EN，看哪种帧能让芯片处理 ##########"
try_frame() {   # $1=描述  $2... = 负载字节
    local desc=$1; shift
    local n=$#
    # 先归零
    i2ctransfer -f -y "$I2C_BUS" "w4@${ADDR}" 0x00 0x7c 0x00 0x00 2>/dev/null
    sleep 0.02
    printf '\n--- %s（负载 %d 字节）---\n' "$desc" "$n"
    if ! i2ctransfer -f -y "$I2C_BUS" "w$((2 + n))@${ADDR}" 0x00 0x7c "$@"; then
        echo "    写入失败"
        return
    fi
    printf '    立即读回(2B) = %s\n' "$(rd 0x7c 2)"
    sleep 0.05
    printf '    +50ms 读回(2B)= %s    8B = %s\n' "$(rd 0x7c 2)" "$(rd 0x7c 8)"
    printf '    MODE=%s  TX_STAT=%s  IRQ=%s\n' "$(rd 0x4d 1)" "$(rd 0x7e 1)" "$(rd 0x30 4)"
}

echo
echo "  基线（当前 0x007C）: $(rd 0x7c 2)"

# ① 我们一直用的帧：2 字节负载
try_frame "我们一直用的：只有 2 字节数据" 0x01 0x00

# ② 4 字节负载（Data + 2 个尾字节）
try_frame "4 字节负载（数据 + 2 个 0）" 0x01 0x00 0x00 0x00

# ③ 8 字节负载（Data×4 + Cmd×2 + Flag×2，全 0 尾）
try_frame "8 字节负载（图 8 的完整帧，尾部全 0）" 0x01 0x00 0x00 0x00 0x00 0x00 0x00 0x00

# ④ 8 字节负载，尾部用 0xFF（万一是"任意非零即命令"）
try_frame "8 字节负载（尾部 0xFF）" 0x01 0x00 0xff 0xff 0xff 0xff 0xff 0xff

# ⑤ 8 字节负载，CmdFlag 用常见"写使能"花样
try_frame "8 字节负载（尾部 0x00 0x00 0x00 0x01）" 0x01 0x00 0x00 0x00 0x00 0x00 0x00 0x01

echo
echo "########## 判读 ##########"
echo "  * 若某一种帧写完后 0x007C 读回变成 0x00 0x00 -> 芯片【处理了】该命令 => 找到正确帧格式"
echo "  * 若全部读回仍带着 bit0（0x01 0x00）  -> 帧尾不是原因，芯片拒绝处理该命令另有其因"
echo
echo "  提示：若上面 A 段里 0x007C 的 8 字节读回在尾部有非零模式，请一并贴出来。"
