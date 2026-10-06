#!/usr/bin/env bash
#
# ra9530-charge-policy.sh — 用笔的 BLE 电量控制 RA9530 充电（防止长期满电搁置）
#
# 依据：
#   * 参考驱动 idtp9418 用 LIMIT_SOC 85（充到 85% 停）；
#   * 本机实测：充电器 0x003A 从不上报电量（无 CSP 中断），触屏 HID 电量不准，
#     而笔自己的 BLE Battery Level（0x2A19）准确 —— 绑定后 BlueZ 暴露
#     org.bluez.Battery1，读数可靠。
#   * 且实测【满电的笔仍会报告 rpp≈30】，所以驱动里那套"rpp≈0 判满"在
#     这支笔上不会触发 —— 策略必须由电量驱动。
#
# 逻辑：
#   电量 >= HIGH  -> 写 enabled=0 停充
#   电量 <= LOW   -> 写 enabled=1 恢复
#   读不到电量（笔在睡觉/断连）-> 保持现状，什么都不做（驱动侧该停的已经停了）
#
# 用法:
#   ./ra9530-charge-policy.sh                 # 前台跑（Ctrl-C 停）
#   HIGH=85 LOW=75 INTERVAL=120 ./ra9530-charge-policy.sh
#   sudo systemctl enable --now ra9530-charge-policy   # 用附带的 service
#
# 依赖：ra9530-pen-battery.sh（读电量）、RA9530 驱动（enabled 属性）

set -u

HERE=$(dirname "$(readlink -f "$0")")
BATT_SH=${BATT_SH:-$HERE/ra9530-pen-battery.sh}
ENABLED=${ENABLED:-/sys/bus/i2c/devices/1-003b/enabled}
NAME=${NAME:-Xiaomi Smart Pen}
HIGH=${HIGH:-85}
LOW=${LOW:-75}
INTERVAL=${INTERVAL:-120}

log() { printf '%s [policy] %s\n' "$(date '+%F %T')" "$*"; }

[[ -x "$BATT_SH" ]] || { echo "找不到 $BATT_SH" >&2; exit 1; }
[[ -w "$ENABLED" ]] || { echo "找不到可写的 $ENABLED（驱动没加载？）" >&2; exit 1; }

state=""          # 最近一次我们做过的动作: on / off / ""
trap 'log "退出"; exit 0' INT TERM

while :; do
    pct=$("$BATT_SH" 2>/dev/null | tail -1)

    if [[ "$pct" =~ ^[0-9]+$ ]]; then
        if (( pct >= HIGH )) && [[ "$state" != "off" ]]; then
            echo 0 > "$ENABLED" 2>/dev/null && {
                log "笔电量 ${pct}% ≥ ${HIGH}% → 停止充电"
                state="off"
            }
        elif (( pct <= LOW )) && [[ "$state" != "on" ]]; then
            echo 1 > "$ENABLED" 2>/dev/null && {
                log "笔电量 ${pct}% ≤ ${LOW}% → 恢复充电"
                state="on"
            }
        else
            log "笔电量 ${pct}%（区间 ${LOW}-${HIGH}%，保持 ${state:-默认}）"
        fi
    else
        log "读不到电量（笔可能在睡觉/未连接/未绑定），保持现状"
    fi

    sleep "$INTERVAL"
done
