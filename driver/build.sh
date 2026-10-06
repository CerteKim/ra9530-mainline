#!/usr/bin/env bash
#
# build.sh — 编译 RA9530 笔充电器模块
#
# 默认用 /lib/modules/$(uname -r)/build；也可以指定内核树：
#   KDIR=~/aarch64-packages/linux-surface/src/kernel ./build.sh

set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

KDIR=${KDIR:-/lib/modules/$(uname -r)/build}

if [[ ! -d "$KDIR" ]]; then
    cat <<EOF
找不到内核构建目录: $KDIR

请指定一个已编译的内核树，例如：
  KDIR=~/aarch64-packages/linux-surface/src/kernel $0
以及（若该树还没 prepare 过）：
  make -C ~/aarch64-packages/linux-surface/src/kernel modules_prepare
EOF
    exit 1
fi

echo "== 用 $KDIR 编译 =="
make -C "$KDIR" M="$PWD" modules

echo
echo "== 产物 =="
ls -l ra9530-charger.ko
modinfo ra9530-charger.ko 2>/dev/null | head -10 || true

echo
echo "下一步："
echo "  sudo insmod $PWD/ra9530-charger.ko      # 或用 modprobe（需先 make modules_install）"
echo "  dmesg | tail -30"
echo "  cat /sys/class/power_supply/ra9530-charger/status"
