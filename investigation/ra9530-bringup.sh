#!/usr/bin/env bash
#
# ra9530-bringup.sh — 把 Xiaomi Book S 12.4 的磁吸笔无线充电 IC (Renesas RA9530)
#                     分阶段拉进 Tx 模式。
#
#   !! 会真的给充电线圈上电 !!  请先把笔吸在机身上，跑的时候留意温度。
#
# 每一步都要人工确认；任何阶段退出都会把两根使能脚恢复成 high（关闭）。
#
# 依赖: i2c-tools；GPIO 走 sysfs（CONFIG_GPIO_SYSFS=y）
# 用法: sudo ./ra9530-bringup.sh
#
# 依据: Renesas R16UH0023EU0100 "RA9530/RA9520 Stylus Application AP Design Guide"
#   笔吸附 -> 开 Switch IC -> 等 5ms -> Boost 软启动 -> 等 "Tx Init Done" 中断
#          -> 写 TX System Command(0x007C) bit0 = TX EN -> 等 100ms
#          -> 读 System Operating Mode(0x004D)，== 0x04 才算成功
#
# 本板未知: gpio11 / gpio186 哪个是 Switch IC、哪个是 Boost，所以逐个试。
#
# GPIO 安全细节（已核对 drivers/gpio/gpiolib-sysfs.c）:
#   direction 写 "out" 或 "low" 都会【先拉低】-> 上电毛刺，禁用！
#   direction 写 "high" 是原子地设为输出高，无毛刺，用它做初始化和恢复。

set -u

ADDR=0x3b
I2C_BUS=""
TLMM_BASE=""

PIN_A=11                # 两个使能脚候选；DT 里标 GPIO_ACTIVE_LOW -> 拉低 = 使能
PIN_B=186
IRQ_PIN=101             # RA9530 中断 (OD2, 开漏/低有效)

MODE_TX=0x04            # System Operating Mode 的 Tx 已使能值

die() { printf '\n!! %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "需要 root: sudo $0"
command -v i2ctransfer >/dev/null || die "缺 i2ctransfer (i2c-tools)"
[[ -w /sys/class/gpio/export ]] || die "sysfs GPIO 不可用"

# ---------------------------------------------------------------- 定位
for d in /sys/bus/i2c/devices/i2c-*; do
    [[ -e "$d/of_node" ]] || continue
    [[ "$(readlink -f "$d/of_node")" == *"i2c@89c000"* ]] && I2C_BUS="${d##*-}"
done
[[ -n "$I2C_BUS" ]] || die "没找到 89c000.i2c (&i2c7)"

for c in /sys/class/gpio/gpiochip*; do
    if [[ "$(cat "$c/label" 2>/dev/null)" == "3100000.pinctrl" ]]; then
        TLMM_BASE=$(cat "$c/base")
    fi
done
[[ -n "$TLMM_BASE" ]] || die "没找到 TLMM (3100000.pinctrl) 的 sysfs 基址"

# ---------------------------------------------------------------- GPIO (sysfs)
gpio_path() { echo "/sys/class/gpio/gpio$(( TLMM_BASE + $1 ))"; }

gpio_export() {   # $1=offset -> 导出并原子地设为输出高（关闭态）
    local p; p=$(gpio_path "$1")
    if [[ ! -d "$p" ]]; then
        echo "$(( TLMM_BASE + $1 ))" > /sys/class/gpio/export 2>/dev/null
        sleep 0.05
    fi
    echo high > "$p/direction" || die "设置 gpio$1 direction=high 失败"
}

gpio_export_in() {   # $1=offset -> 只作为输入观察，不驱动
    local p; p=$(gpio_path "$1")
    if [[ ! -d "$p" ]]; then
        echo "$(( TLMM_BASE + $1 ))" > /sys/class/gpio/export 2>/dev/null
        sleep 0.05
    fi
    echo in > "$p/direction" 2>/dev/null
}

gpio_set() {      # $1=offset $2=0|1
    echo "$2" > "$(gpio_path "$1")/value" || die "写 gpio$1 value=$2 失败"
}

gpio_get() { cat "$(gpio_path "$1")/value" 2>/dev/null || echo "?"; }

restore_gpios() {
    local o
    for o in "$PIN_A" "$PIN_B"; do
        gpio_export "$o"          # high，无毛刺
    done
    sleep 0.05
    printf '[cleanup] gpio%s=%s gpio%s=%s (high = 关闭)\n' \
        "$PIN_A" "$(gpio_get "$PIN_A")" "$PIN_B" "$(gpio_get "$PIN_B")"
    # 释放，避免以后内核驱动 request 时 EBUSY（释放后焊盘保持最后电平=high）
    for o in "$PIN_A" "$PIN_B" "$IRQ_PIN"; do
        echo "$(( TLMM_BASE + o ))" > /sys/class/gpio/unexport 2>/dev/null
    done
}

cleanup() {
    local rc=$?
    if [[ ${KEEP_ON:-0} -ne 1 ]]; then
        restore_gpios
    else
        printf '[cleanup] KEEP_ON=1，保持 gpio%s=%s gpio%s=%s 不动\n' \
            "$PIN_A" "$(gpio_get "$PIN_A")" "$PIN_B" "$(gpio_get "$PIN_B")"
    fi
    exit $rc
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- I2C
xb() { i2ctransfer -f -y "$I2C_BUS" "w2@${ADDR}" 0x00 "$1" "r$2" 2>&1; }

r8() {
    local a; a=$(xb "$1" 1) || return 1
    [[ "$a" == 0x* ]] || return 1
    printf '%d' "$a"
}
r16() {
    local a b; read -r a b <<<"$(xb "$1" 2)" || return 1
    [[ "$a" == 0x* && "$b" == 0x* ]] || return 1
    printf '%d' $(( b << 8 | a ))
}
r32() {
    local a b c d; read -r a b c d <<<"$(xb "$1" 4)" || return 1
    [[ "$a" == 0x* && "$b" == 0x* && "$c" == 0x* && "$d" == 0x* ]] || return 1
    printf '%d' $(( d << 24 | c << 16 | b << 8 | a ))
}
w16() {   # $1=reg $2=value(10进制)
    i2ctransfer -f -y "$I2C_BUS" "w4@${ADDR}" 0x00 "$1" \
        "$(printf '0x%02x' $(( ($2)      & 0xff )))" \
        "$(printf '0x%02x' $(( ($2 >> 8) & 0xff )))"
}

# 状态指纹：MODE + 中断 + EPT + IC 中断脚电平
fingerprint() {
    printf '%s|%s|%s|%s' "$(r8 0x4d)" "$(r32 0x30)" "$(r16 0x7a)" "$(gpio_get "$IRQ_PIN")"
}

dump() {
    printf '  CHIP_ID(0x0000) = %s\n' "$(xb 0x00 2)"
    printf '  MODE   (0x004D) = 0x%02X    <-- 0x%02X 才是 Tx 已使能\n' "$(r8 0x4d)" "$MODE_TX"
    printf '  IRQ    (0x0030) = 0x%08X\n' "$(r32 0x30)"
    printf '  IRQ_EN (0x0034) = 0x%08X\n' "$(r32 0x34)"
    printf '  BATT   (0x003A) = 0x%02X\n' "$(r8 0x3a)"
    printf '  EPT    (0x007A) = 0x%04X\n' "$(r16 0x7a)"
    printf '  gpio%s=%s  gpio%s=%s  IRQ gpio%s=%s\n' \
        "$PIN_A" "$(gpio_get "$PIN_A")" "$PIN_B" "$(gpio_get "$PIN_B")" \
        "$IRQ_PIN" "$(gpio_get "$IRQ_PIN")"
}

ask() {
    local a
    printf '\n>>> %s\n    继续? [y/N] ' "$1"
    read -r a </dev/tty || die "无法读取输入"
    [[ "$a" == "y" || "$a" == "Y" ]] || die "用户中止"
}

echo "=============================================================="
echo " RA9530 分阶段上电实验 —— 会给线圈真正上电"
echo " i2c-$I2C_BUS   使能脚 gpio$PIN_A / gpio$PIN_B   中断 gpio$IRQ_PIN"
echo " 请确认触控笔已吸在机身上；跑的过程留意机身温度"
echo "=============================================================="

gpio_export "$PIN_A"
gpio_export "$PIN_B"
gpio_export_in "$IRQ_PIN"       # 只读观察 IC 中断脚（开漏，空闲高）

# ------------------------------------------------------------ Stage 0
echo
echo "########## Stage 0: 上电前基线（只读） ##########"
dump
base_fp=$(fingerprint)
ask "基线是否正常（chip id 应为 0x30 0x95，MODE 应为 0x80 之类而非 0x04）？"

# ------------------------------------------------------------ Stage A
echo
echo "########## Stage A: 只把 gpio$PIN_A 拉低 ##########"
gpio_set "$PIN_A" 0
sleep 0.2
dump
fp_a=$(fingerprint)

a_effect=0
[[ "$fp_a" != "$base_fp" ]] && a_effect=1

if [[ $a_effect -eq 1 ]]; then
    echo
    echo "*** gpio$PIN_A 有效果：状态指纹变了 ***"
    ask "再把 gpio$PIN_B 也拉低（模拟 Switch 先开、Boost 后开）？"
    gpio_set "$PIN_B" 0
    sleep 0.05
    echo "--- 两根都拉低 ---"
    dump
else
    echo
    echo "gpio$PIN_A 拉低后看不出变化。"
    echo "########## Stage B: 恢复 gpio$PIN_A，只拉低 gpio$PIN_B ##########"
    gpio_set "$PIN_A" 1
    sleep 0.05
    gpio_set "$PIN_B" 0
    sleep 0.2
    dump
    fp_b=$(fingerprint)

    if [[ "$fp_b" != "$base_fp" ]]; then
        echo
        echo "*** gpio$PIN_B 有效果 ***"
        ask "再把 gpio$PIN_A 也拉低？"
        gpio_set "$PIN_A" 0
        sleep 0.05
        echo "--- 两根都拉低 ---"
        dump
    else
        echo
        echo "!!! 单独拉低任一使能脚都没有可观测变化。"
        echo "    可能: 两根都要拉低 / 这两根不是使能脚 / 外部 Switch 或 Boost 不在这条路上。"
        ask "两根同时拉低继续试？（Boost 可能空载启动，风险略高）"
        gpio_set "$PIN_A" 0
        gpio_set "$PIN_B" 0
        sleep 0.2
        dump
    fi
fi

# ------------------------------------------------------------ Stage C
echo
echo "########## Stage C: 清中断（可选，按指南要求） ##########"
echo "  写 1 到 System Interrupt Clear(0x0028)，再写 0x007C bit1 = CLR Interrupt"
if [[ "$(r32 0x30)" != "0" ]]; then
    ask "当前中断寄存器非 0，先清一次？"
    i2ctransfer -f -y "$I2C_BUS" "w6@${ADDR}" 0x00 0x28 0xff 0xff 0xff 0xff \
        || echo "  (写 0x0028 失败)"
    sleep 0.05
    w16 0x7c 0x0002 || echo "  (写 0x007C CLR 失败)"
    sleep 0.05
    echo "--- 清中断后 ---"
    dump
fi

# ------------------------------------------------------------ Stage D
echo
echo "########## Stage D: 写 TX EN，真正开始发射 ##########"
ask "写 TX System Command (0x007C) bit0 = TX EN？"

w16 0x7c 0x0001 || die "写 0x007C 失败"
echo "  已写 0x007C = 0x0001，等 250ms ..."
sleep 0.25
echo "--- 写 TX EN 之后 ---"
dump

mode=$(r8 0x4d)
echo
if [[ "$mode" == "$(printf '%d' $((MODE_TX)))" ]]; then
    cat <<EOF

==============================================================
 *** 成功: MODE = 0x04，Tx 正在发射 ***
 现在检查笔是否开始充电（笔身电量指示 / 机身温度）。
 想观察多久都行，按 Enter 结束观测；结束时会把两根使能脚恢复 high 关闭。
==============================================================
EOF
    read -r _ </dev/tty
else
    printf ' 失败: MODE = 0x%02X，期望 0x%02X\n' "$mode" "$MODE_TX"
    printf ' EPT Type (0x007A) = 0x%04X\n' "$(r16 0x7a)"
    cat <<'EOF'
 EPT 位含义:
   bit15 POCP   bit14 OTP    bit13 FOD    bit12 LVP   bit11 OVP   bit10 OCP
   bit9  RPP超时 bit8  CEP超时 bit7  看门狗  bit6  AP看门狗 bit5 冲突
 可能原因:
   - gpio11/gpio186 与 Switch IC / Boost 的对应关系猜错了
   - 外部 Switch 或 Boost 根本没被这两根脚控制
   - 还需要先写某个 user register（指南 5.4.1 第 3 步，可选）
   - EPT 里有 FOD/OCP 位 -> 线圈检测异常
EOF
fi

echo
echo "实验结束。"
