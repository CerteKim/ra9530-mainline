#!/usr/bin/env bash
#
# pen-charge-check.sh — 一条命令读出"笔到底有没有在充电"的硬指标
#
# 背景：
#   触屏控制器 (0018:4858:121A, hid-multitouch) 同时导出触屏与 Stylus，
#   并通过 HID Battery Strength 把【笔的电池】报给内核
#   （内核 CONFIG_HID_BATTERY_STRENGTH=y），于是有了：
#       /sys/class/power_supply/hid-0018:4858:121A.0003-battery
#   触屏本身没有电池，所以这个 capacity 就是笔的。
#
#   另外 ADSP 侧有一条 Wireless 电源通路（pmic-glink）：
#       /sys/class/power_supply/qcom-battmgr-wls   online=0/1
#   它只读，但能告诉我们固件认为"无线充电"是否在工作。
#
# 普通用户即可运行（不加 sudo 也能看笔电量与 wls 状态；加 sudo 会额外读芯片寄存器）。
#
# 用法:
#   ./pen-charge-check.sh
#   sudo ./pen-charge-check.sh     # 额外读 RA9530 的 MODE / Vin / TX_STAT

set -u

PEN=$(echo /sys/class/power_supply/hid-*-battery 2>/dev/null | awk '{print $1}')
WLS=/sys/class/power_supply/qcom-battmgr-wls
BAT=/sys/class/power_supply/qcom-battmgr-bat

rd() { [[ -r "$1" ]] && cat "$1" 2>/dev/null || echo "?"; }

echo "=================================================================="
echo " 笔充电状态检查    $(date '+%F %T')"
echo "=================================================================="
echo
if [[ -n "${PEN:-}" && -d "$PEN" ]]; then
    echo "笔 (通过触屏控制器的 HID 电池上报):"
    printf '  capacity(电量) = %s %%\n' "$(rd "$PEN/capacity")"
    printf '  status         = %s\n'   "$(rd "$PEN/status")"
    printf '  present        = %s\n'   "$(rd "$PEN/present")"
    printf '  online         = %s\n'   "$(rd "$PEN/online")"
else
    echo "笔: 找不到 HID 电池节点（笔未与触屏通信？把它贴到机身上并轻触一下屏幕）"
fi
echo
echo "平板电池 / ADSP 电源通路:"
printf '  battmgr-bat  status = %s   capacity = %s %%\n' "$(rd "$BAT/status")" "$(rd "$BAT/capacity")"
printf '  battmgr-wls  online = %s   (1 = 固件认为无线充电在工作)\n' "$(rd "$WLS/online")"
printf '  battmgr-ac   online = %s\n' "$(rd /sys/class/power_supply/qcom-battmgr-ac/online)"
printf '  battmgr-usb  online = %s\n' "$(rd /sys/class/power_supply/qcom-battmgr-usb/online)"
echo
echo "RA9530 (需要 root):"
if [[ ${EUID} -eq 0 ]]; then
    BUS=$(for d in /sys/bus/i2c/devices/i2c-*; do
            [[ -e "$d/of_node" ]] || continue
            [[ "$(readlink -f "$d/of_node")" == *"i2c@89c000"* ]] && echo "${d##*-}"
          done)
    if [[ -n "$BUS" ]]; then
        id=$(i2ctransfer -f -y "$BUS" w2@0x3b 0x00 0x00 r2 2>&1)
        if [[ "$id" == 0x* ]]; then
            printf '  芯片ID=%s   MODE=%s (0x04=正在发射, 0x80=未使能)   TX_STAT=%s   Vin=%s\n' \
                "$id" "$(i2ctransfer -f -y "$BUS" w2@0x3b 0x00 0x4d r1 2>/dev/null)" \
                "$(i2ctransfer -f -y "$BUS" w2@0x3b 0x00 0x7e r1 2>/dev/null)" \
                "$(i2ctransfer -f -y "$BUS" w2@0x3b 0x00 0x80 r2 2>/dev/null)"
        else
            echo "  芯片无应答: $id"
        fi
    fi
else
    echo "  (用 sudo 运行可额外显示 RA9530 的 MODE / TX_STAT / Vin)"
fi
echo
echo "提示: 笔若长时间不动会休眠，读数可能不变；量之前先用笔轻触一下屏幕唤醒它。"
