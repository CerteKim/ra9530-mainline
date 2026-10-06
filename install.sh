#!/usr/bin/env bash
#
# ra9530/install.sh — 一键安装：内核驱动 + 设备树节点 + 用户态工具 + 充电守护
#
#   sudo ./install.sh
#   KDIR=~/aarch64-packages/linux-surface/src/kernel sudo ./install.sh
#
# 安装内容：
#   * 内核模块 ra9530-charger.ko（并 make modules_install + depmod，重启后由 udev 自动加载）
#   * 设备树节点（写进 /boot 下的 DTB，自动备份为 *.orig-ra9530）
#   * /usr/local/bin/{ra9530-pen-battery.sh,ra9530-charge-policy.sh}
#   * /etc/systemd/system/ra9530-charge-policy.service（启用，重启后生效）

set -euo pipefail

HERE=$(dirname "$(readlink -f "$0")")
[[ ${EUID} -eq 0 ]] || { echo "需要 root：sudo $0" >&2; exit 1; }

KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
if [[ ! -d "$KDIR" ]]; then
	cat >&2 <<EOF
找不到内核构建目录：$KDIR

若这台机器上没有 /lib/modules/$(uname -r)/build，请指向已编译的内核树：
  KDIR=~/aarch64-packages/linux-surface/src/kernel sudo ./install.sh
（该树若未 prepare 过：make -C <树> modules_prepare）
EOF
	exit 1
fi

command -v fdtput >/dev/null || { echo "缺少 fdtput（pacman -S dtc）" >&2; exit 1; }

KVER=$(uname -r)
MODDIR=/lib/modules/$KVER

echo "==> 1/5 编译并安装内核模块（$KDIR）"
make -C "$KDIR" M="$HERE/driver" modules

# 先清掉任何旧副本：外置模块默认装到 extra/，而 updates/ 的优先级更高，
# 残留的旧文件会让 modprobe 一直加载旧版（我们踩过这个坑）。
stale=$(find "$MODDIR" -name 'ra9530-charger.ko*' 2>/dev/null || true)
if [[ -n "$stale" ]]; then
	echo "    清理旧副本："
	echo "$stale" | sed 's/^/      /'
	echo "$stale" | while read -r f; do rm -f "$f"; done
fi

make -C "$KDIR" M="$HERE/driver" modules_install
depmod -a "$KVER"

# 校验装进去的确实是刚编译出来的那一份
built=$(sha256sum "$HERE/driver/ra9530-charger.ko" | cut -d' ' -f1)
installed=$(find "$MODDIR" -name 'ra9530-charger.ko' -exec sha256sum {} \; 2>/dev/null | awk '{print $1}' | sort -u)
if [[ "$installed" != "$built" ]]; then
	echo "!! 安装校验失败：装进去的模块与刚编译的不一致" >&2
	echo "   编译产物 $built" >&2
	echo "   已安装   ${installed:-（没找到）}" >&2
	exit 1
fi
echo "    已安装并校验通过（sha256 ${built:0:16}…）"
find "$MODDIR" -name 'ra9530-charger.ko' | sed 's/^/      /'
if lsmod | grep -q '^ra9530_charger'; then
	echo "    提示：模块正在运行，要让新版生效需：sudo rmmod ra9530_charger && sudo modprobe ra9530-charger"
fi

echo
echo "==> 2/5 写入设备树节点"
"$HERE/driver/install-dt.sh"

echo
echo "==> 3/5 安装用户态工具到 /usr/local/bin"
install -m 0755 "$HERE/tools/ra9530-pen-battery.sh"   /usr/local/bin/ra9530-pen-battery.sh
install -m 0755 "$HERE/tools/ra9530-charge-policy.sh" /usr/local/bin/ra9530-charge-policy.sh

echo
echo "==> 4/5 安装并启用充电守护"
install -m 0644 "$HERE/tools/ra9530-charge-policy.service" \
	/etc/systemd/system/ra9530-charge-policy.service
systemctl daemon-reload
systemctl enable ra9530-charge-policy.service

echo
echo "==> 5/5 完成"
cat <<'EOF'

接下来：

  1) 重启让设备树改动生效（DTB 已备份为 /boot/.../*.orig-ra9530）
         sudo reboot

  2) 重启后检查（udev 会按设备树自动加载模块）：
         dmesg | grep -i ra9530
         cat /sys/class/power_supply/ra9530-charger/status
         cat /sys/bus/i2c/devices/1-003b/rpp           # 非 0 = 笔在收功率
         systemctl status ra9530-charge-policy

  3) 笔的 BLE 电量（充电策略的依据）需要先和本机配对一次：
         bluetoothctl
         > agent on
         > default-agent
         > scan on
         > pair  <笔的地址>        # 名字一般是 "Xiaomi Smart Pen"
         > trust <笔的地址>
     配对成功后：
         /usr/local/bin/ra9530-pen-battery.sh --verbose     # 应输出百分比

  4) 手动控制充电（可选）：
         echo 0 | sudo tee /sys/bus/i2c/devices/1-003b/enabled   # 停
         echo 1 | sudo tee /sys/bus/i2c/devices/1-003b/enabled   # 开

  还原设备树：sudo ra9530/driver/install-dt.sh --revert
EOF
