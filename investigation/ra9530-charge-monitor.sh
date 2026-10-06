#!/usr/bin/env bash
#
# ra9530-charge-monitor.sh — 设好反向 FOD 后保持 Tx，并监视【功率是否真的流过去】
#
# 关键更正（相对上一版）：开 Tx 之前必须设置反向模式 FOD 阈值。
#   依据 nik012003/idtp9418-mainline（同款笔、可用）：
#       #define REVERSE_FOD 500                     // 500 mW
#       idt_set_reverse_fod()  ->  写 REG_FOD_LOW(0x0092)/REG_FOD_HIGH(0x0093)
#       di->bus.write(di, REG_TX_CMD, TX_EN | TX_FOD_EN);   // 0x0076 = 0x21
#   FOD 阈值没设好 -> 芯片判定功率损耗异常 -> 把功率压到接近 0
#   -> 现象正是"协商成功(bit2 信号强度包)但笔电量一直是 0"。
#
# 本脚本每周期打印：
#   时间 MODE 0x78 IRQ 中断位 笔电量SOC IIN(反向电流) VIN(反向电压) 反向温度 结温 HID
#   —— IIN 是判断"功率有没有真的输出去"的关键：非 0 就说明在充电。
#
# 用法:
#   sudo ./ra9530-charge-monitor.sh
#   DURATION=1800 INTERVAL=10 sudo ./ra9530-charge-monitor.sh
#   FOD_MW=1000 sudo ./ra9530-charge-monitor.sh        # 换一个 FOD 阈值（默认 500）

set -u

ADDR=0x3b
I2C_BUS=""
GPIO_CHIP_LABEL="3100000.pinctrl"
PIN_EN=11
PIN_BOOST=186
TLMM_BASE=""
DURATION=${DURATION:-600}
INTERVAL=${INTERVAL:-5}
FOD_MW=${FOD_MW:-500}

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
rd16le() {   # 小端 16 位，返回十进制
    local a b; read -r a b <<<"$(rd "$1" 2)"
    if [[ "$a" == 0x* && "$b" == 0x* ]]; then printf '%d' $(( 0x${b#0x}*256 + 0x${a#0x} ))
    else printf '?'; fi; }
wr8()  { i2ctransfer -f -y "$I2C_BUS" "w3@${ADDR}" 0x00 "$1" "$(printf '0x%02x' $(( $2 & 0xff )))" 2>&1; }
ms()   { sleep "$(printf '%d.%03d' $(( $1 / 1000 )) $(( $1 % 1000 )))"; }

gpio_path() { echo "/sys/class/gpio/gpio$(( TLMM_BASE + $1 ))"; }
gpio_prep() { local p; p=$(gpio_path "$1")
    [[ -d "$p" ]] || { echo "$(( TLMM_BASE + $1 ))" > /sys/class/gpio/export 2>/dev/null; sleep 0.05; }
    echo high > "$p/direction" 2>/dev/null; }
gpio_set() { echo "$2" > "$(gpio_path "$1")/value" 2>/dev/null; }
gpio_get() { cat "$(gpio_path "$1")/value" 2>/dev/null || echo "?"; }

cleanup() { local rc=$?
    gpio_prep "$PIN_EN"; gpio_prep "$PIN_BOOST"; sleep 0.05
    printf '\n[cleanup] gpio%s=%s gpio%s=%s  最终 MODE=%s（Tx 保持开启）\n' \
      "$PIN_EN" "$(gpio_get "$PIN_EN")" "$PIN_BOOST" "$(gpio_get "$PIN_BOOST")" "$(rd8 0x4d)"
    local o; for o in "$PIN_EN" "$PIN_BOOST"; do
        echo "$(( TLMM_BASE + o ))" > /sys/class/gpio/unexport 2>/dev/null; done
    exit $rc; }
trap cleanup EXIT INT TERM

irq_text() {   # 位定义取自 idtp9418 的 TRX 表
    local v=$1 s=""
    (( (v>>15)&1 )) && s="$s CSP(笔电量)"
    (( (v>>13)&1 )) && s="$s ID认证OK"
    (( (v>>8)&1  )) && s="$s BLE地址"
    (( (v>>7)&1  )) && s="$s Tx初始化完成"
    (( (v>>6)&1  )) && s="$s 数字ping"
    (( (v>>5)&1  )) && s="$s PPP包"
    (( (v>>4)&1  )) && s="$s 配置包"
    (( (v>>3)&1  )) && s="$s ID包"
    (( (v>>2)&1  )) && s="$s 信号强度包"
    (( (v>>1)&1  )) && s="$s 开始数字ping"
    (( (v>>0)&1  )) && s="$s EPT"
    [[ -z "$s" ]] && s=" -"
    echo "$s"
}

echo "=============================================================="
echo " RA9530 笔充电监视（含反向 FOD 设置）  $(date '+%F %T')"
printf ' 总线 %s Hz   时长 %ds   间隔 %ds   FOD 阈值 %d mW\n' \
  "$(od -An -tu4 --endian=big /sys/bus/i2c/devices/i2c-$I2C_BUS/of_node/clock-frequency 2>/dev/null | tr -d ' ')" \
  "$DURATION" "$INTERVAL" "$FOD_MW"
echo "=============================================================="

gpio_prep "$PIN_EN"; gpio_prep "$PIN_BOOST"
gpio_set "$PIN_EN" 1; gpio_set "$PIN_BOOST" 1
ms 100

echo
echo "########## 开 Tx 之前的基线（重点看 FOD 与反向遥测）##########"
printf '  芯片ID=%s   开关=%s 升压=%s\n' "$(rd 0x0000 2)" "$(gpio_get $PIN_EN)" "$(gpio_get $PIN_BOOST)"
printf '  MODE(4D)=%s   0x78=%s   IRQ=%s\n' "$(rd8 0x4d)" "$(rd8 0x78)" "$(rd 0x30 4)"
printf '  FOD(0x92/0x93) = %s / %s      <- 驱动要用的是 500mW = 0xF4 / 0x01\n' "$(rd8 0x92)" "$(rd8 0x93)"
printf '  IIN(0x6E/6F)=%s   VIN(0x70/71)=%s   REV温度(0x7A)=%s\n' \
       "$(rd16le 0x6e)" "$(rd16le 0x70)" "$(rd8 0x7a)"
printf '  笔电量SOC(0x3A)=%s\n' "$(rd8 0x3a)"
printf '  CEP(0xA5)=%s  RPP(0xA6)=%s  ALIGN_X(0xB0)=%s   <- RPP=笔报告"收到了多少功率"\n' \
       "$(rd8 0xa5)" "$(rd8 0xa6)" "$(rd8 0xb0)"

echo
echo "########## 1. 设置反向 FOD 阈值 ##########"
wr8 0x92 $(( FOD_MW & 0xff )) >/dev/null
wr8 0x93 $(( (FOD_MW >> 8) & 0xff )) >/dev/null
ms 30
printf '  已写 %d mW -> 回读 0x92=%s 0x93=%s\n' "$FOD_MW" "$(rd8 0x92)" "$(rd8 0x93)"

echo
echo "########## 2. 使能 Tx：写 0x0076 = 0x21 ##########"
wr8 0x76 0x21 >/dev/null
ms 100
printf '  MODE=%s (0x04 = TRx)   0x78=%s (0x01 = 已启动)\n' "$(rd8 0x4d)" "$(rd8 0x78)"

echo
printf '\n%-7s %-5s %-5s %-11s %-26s %-6s %-6s %-6s %-8s %-8s %-9s %-7s %s\n' \
   时间 MODE 0x78 IRQ 中断位 SOC CEP RPP IIN VIN 反向温度 结温 HID
echo "----------------------------------------------------------------------------------------------------------------------------"

t=0
while [[ $t -lt $DURATION ]]; do
    mode=$(rd8 0x4d); d78=$(rd8 0x78); soc=$(rd8 0x3a)
    iin=$(rd16le 0x6e); vin=$(rd16le 0x70); rt=$(rd8 0x7a)
    temp=$(rd16le 0x0084)
    read -r b0 b1 b2 b3 <<<"$(rd 0x30 4)"
    if [[ "$b0" == 0x* && "$b3" == 0x* ]]; then
        irqv=$(( 0x${b3#0x}*16777216 + 0x${b2#0x}*65536 + 0x${b1#0x}*256 + 0x${b0#0x} ))
        irqs=$(printf '0x%08X' "$irqv")
    else
        irqv=0; irqs="??"
    fi
    hid=$(cat /sys/class/power_supply/hid-*-battery/capacity 2>/dev/null | head -1)

    cep=$(rd8 0xa5); rpp=$(rd8 0xa6)
    printf '%-7s %-5s %-5s %-11s %-26s %-6s %-6s %-6s %-8s %-8s %-9s %-7s %s\n' \
        "${t}s" "$mode" "$d78" "$irqs" "$(irq_text "$irqv")" \
        "$soc" "$cep" "$rpp" "$iin" "$vin" "$rt" "${temp}°C" "${hid:-?}%"

    if [[ "$mode" != "0x04" ]]; then
        printf '%-7s MODE=%s 掉出 Tx，重写 FOD + 0x0076=0x21\n' "${t}s" "$mode"
        wr8 0x92 $(( FOD_MW & 0xff )) >/dev/null; wr8 0x93 $(( (FOD_MW >> 8) & 0xff )) >/dev/null
        wr8 0x76 0x21 >/dev/null; ms 100
    fi
    ms $(( INTERVAL * 1000 )); t=$(( t + INTERVAL ))
done

echo
echo "=============================================================="
echo " 判读"
echo "  * IIN（反向输入电流）非 0 且随时间变化 -> 功率确实输出了，笔在充电"
echo "    （笔很小，可能只有几十~几百 mA；SOC 列上升就是最终证据）"
echo "  * IIN 一直为 0  -> 芯片进了 TRx 但没把功率送出去，需要继续查"
echo "    （那时把 0x30 的 IRQ 位、FOD 回读值、以及是否有 EPT 位一起贴出来）"
printf ' 结束状态: MODE=%s 0x78=%s FOD=%s/%s IIN=%s VIN=%s SOC=%s 结温=%s°C\n' \
  "$(rd8 0x4d)" "$(rd8 0x78)" "$(rd8 0x92)" "$(rd8 0x93)" "$(rd16le 0x6e)" "$(rd16le 0x70)" \
  "$(rd8 0x3a)" "$(rd16le 0x0084)"
printf ' CEP=%s  RPP=%s（RPP 非 0 = 笔确认收到了功率）\n' "$(rd8 0xa5)" "$(rd8 0xa6)"
