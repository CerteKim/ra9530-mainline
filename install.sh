#!/usr/bin/env bash
#
# install.sh — 安装 RA9530 笔充电器：内核模块（DKMS 优先）+ 设备树节点
#              + 用户态工具 + 充电守护
#
#   sudo ./install.sh                  # 有 dkms 就用 DKMS（推荐：内核升级自动重编）
#   sudo ./install.sh --plain          # 强制普通外置模块（内核升级后需手动重装）
#   KDIR=<内核树> sudo ./install.sh     # 指定内核构建目录
#
# DKMS 与普通方式**不要混用**：脚本会先清掉 /lib/modules/<ver> 下所有
# ra9530-charger.ko 副本，避免"优先级更高的旧副本把新版挡住"（踩过这个坑）。

set -euo pipefail

HERE=$(dirname "$(readlink -f "$0")")
KVER=$(uname -r)
MODDIR=/lib/modules/$KVER
DKMS_NAME=ra9530
DKMS_VER=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$HERE/dkms.conf" 2>/dev/null | head -1)
DKMS_VER=${DKMS_VER:-1.0.1}
MODE=auto

while [[ $# -gt 0 ]]; do
	case "$1" in
		--plain) MODE=plain ;;
		--dkms)  MODE=dkms ;;
		*) echo "未知参数: $1" >&2; exit 2 ;;
	esac
	shift
done

[[ ${EUID} -eq 0 ]] || { echo "需要 root：sudo $0" >&2; exit 1; }
command -v fdtput >/dev/null || { echo "缺少 fdtput（pacman -S dtc）" >&2; exit 1; }

KDIR=${KDIR:-$MODDIR/build}
if [[ ! -d "$KDIR" ]]; then
	echo "找不到内核构建目录：$KDIR" >&2
	echo "若本机没有 $MODDIR/build，请指向已编译的内核树：" >&2
	echo "  KDIR=/path/to/linux sudo $0" >&2
	exit 1
fi

# ---------------------------------------------------------------- 1) 模块
echo "==> 1/4 内核模块"

# 先清掉所有旧副本（外置模块进 extra/，DKMS 进 updates/dkms/，而 updates/ 优先级更高）
stale=$(find "$MODDIR" -name 'ra9530-charger.ko*' 2>/dev/null || true)
if [[ -n "$stale" ]]; then
	echo "    清理已有副本："
	echo "$stale" | sed 's/^/      /'
	echo "$stale" | while read -r f; do rm -f "$f"; done
fi

use_dkms=no
[[ "$MODE" == "dkms"  ]] && use_dkms=yes
if [[ "$MODE" == "auto" ]] && command -v dkms >/dev/null; then use_dkms=yes; fi

if [[ "$use_dkms" == "yes" ]]; then
	command -v dkms >/dev/null || { echo "    没有 dkms（pacman -S dkms）" >&2; exit 1; }
	SRCDIR=/usr/src/$DKMS_NAME-$DKMS_VER
	echo "    使用 DKMS：$DKMS_NAME/$DKMS_VER -> $SRCDIR"

	if dkms status "$DKMS_NAME/$DKMS_VER" 2>/dev/null | grep -q .; then
		dkms remove -m "$DKMS_NAME" -v "$DKMS_VER" --all >/dev/null 2>&1 || true
	fi

	rm -rf "$SRCDIR"
	mkdir -p "$SRCDIR"
	tar -C "$HERE" --exclude=.git --exclude='*.ko' --exclude='*.o' \
	    --exclude='*.mod*' --exclude='.*.cmd' --exclude='.tmp_versions' \
	    -cf - . | tar -C "$SRCDIR" -xf -

	dkms add     -m "$DKMS_NAME" -v "$DKMS_VER"
	dkms build   -m "$DKMS_NAME" -v "$DKMS_VER"
	dkms install -m "$DKMS_NAME" -v "$DKMS_VER" --force
	dkms status "$DKMS_NAME/$DKMS_VER" | sed 's/^/      /'
	echo "    ✓ 已由 DKMS 安装（内核升级后会自动为新内核重建）"
else
	echo "    使用普通外置模块（没有 dkms 或指定了 --plain）"
	make -C "$KDIR" M="$HERE/driver" modules >/dev/null
	make -C "$KDIR" M="$HERE/driver" modules_install
	depmod -a "$KVER"

	built=$(sha256sum "$HERE/driver/ra9530-charger.ko" | cut -d' ' -f1)
	installed=$(find "$MODDIR" -name 'ra9530-charger.ko' -exec sha256sum {} \; 2>/dev/null | awk '{print $1}' | sort -u)
	if [[ "$installed" != "$built" ]]; then
		echo "!! 安装校验失败：装进去的与刚编译的不一致" >&2
		echo "   编译 $built" >&2
		echo "   已装 ${installed:-（没找到）}" >&2
		exit 1
	fi
	echo "    ✓ 已安装并校验（sha256 ${built:0:16}…）"
	find "$MODDIR" -name 'ra9530-charger.ko' | sed 's/^/      /'
	echo "    ⚠ 内核升级后需要重新运行本脚本"
fi

if lsmod | grep -q '^ra9530_charger'; then
	echo "    提示：模块正在运行，让新版生效：sudo rmmod ra9530_charger && sudo modprobe ra9530-charger"
fi

# ---------------------------------------------------------------- 2) 设备树
echo
echo "==> 2/4 设备树节点"
"$HERE/driver/install-dt.sh"

# ---------------------------------------------------------------- 3) 工具
echo
echo "==> 3/4 用户态工具 -> /usr/local/bin"
install -m 0755 "$HERE/tools/ra9530-pen-battery.sh"   /usr/local/bin/ra9530-pen-battery.sh
install -m 0755 "$HERE/tools/ra9530-charge-policy.sh" /usr/local/bin/ra9530-charge-policy.sh

# ---------------------------------------------------------------- 4) 守护
echo
echo "==> 4/4 充电守护"
install -m 0644 "$HERE/tools/ra9530-charge-policy.service" \
	/etc/systemd/system/ra9530-charge-policy.service
systemctl daemon-reload
systemctl enable ra9530-charge-policy.service

cat <<'EOF'

完成。接下来：

  1) 设备树改动需要重启才生效（DTB 已备份为 /boot/.../*.orig-ra9530）
         sudo reboot

  2) 重启后检查（模块由 udev 按设备树自动加载，DKMS 方式亦然）：
         dmesg | grep -i ra9530
         cat /sys/class/power_supply/ra9530-charger/status
         cat /sys/bus/i2c/devices/1-003b/rpp        # 非 0 = 笔在收功率
         systemctl status ra9530-charge-policy
     DKMS 方式另查：
         dkms status

  3) 笔的 BLE 电量（充电策略的依据）需要先配对一次：
         bluetoothctl -> agent on; default-agent; scan on;
                         pair <笔的地址>; trust <笔的地址>
     然后：/usr/local/bin/ra9530-pen-battery.sh --verbose

  4) 手动控制充电：
         echo 0 | sudo tee /sys/bus/i2c/devices/1-003b/enabled
         echo 1 | sudo tee /sys/bus/i2c/devices/1-003b/enabled

  还原设备树：sudo driver/install-dt.sh --revert
  卸载 DKMS ：sudo dkms remove -m ra9530 -v <版本> --all
EOF
