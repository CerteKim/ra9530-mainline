# Xiaomi Book S 12.4 磁吸触控笔充电（Renesas RA9530）

这台平板（`xiaomi,book-12.4`，SC8180X，DT 引导）的磁吸笔充电器是一颗
**Renesas RA9530**（ACPI 里是 `Device (SXB)`，`_HID = "TXRA9530"`，
I²C 地址 `0x3b`，挂在 `&i2c7` / `0x89c000` 上）。

**状态：Linux 下已完全可用** —— 实测把一支放空到 0% 的笔充到了 **100%**，
并且能读到准确电量、能按阈值停充。

---

## 快速安装（需要 root）

```sh
cd /path/to/ra9530-mainline
sudo ./install.sh
sudo reboot
```

`install.sh` 会：编译并安装内核模块 → 把设备树节点写进 `/boot` 的 DTB（自动备份）
→ 安装用户态工具到 `/usr/local/bin` → 安装并启用充电守护。

## 安装方式：DKMS（推荐）还是普通外置模块

`install.sh` 默认**优先使用 DKMS**（只要系统里有 `dkms`）：

| | **DKMS**（默认） | 普通外置模块（`--plain`） |
|---|---|---|
| 内核升级后 | **自动为新内核重建** ✓ | 需手动重跑 `install.sh` ⚠ |
| 模块位置 | `/lib/modules/<ver>/updates/dkms/` | `/lib/modules/<ver>/extra/` |
| 源码副本 | `/usr/src/ra9530-1.0.2/` | 不复制 |

```sh
sudo pacman -S dkms                # 若尚未安装
cd /path/to/ra9530-mainline
sudo ./install.sh                  # 自动走 DKMS；想强制旧方式用 --plain

dkms status                        # 查看状态
sudo dkms remove -m ra9530 -v 1.0.2 --all     # 卸载
```

改动源码后重新执行 `sudo ./install.sh` 即可（脚本会重新复制源码到 `/usr/src` 并重建）。
**两种方式不要混用** —— 脚本每次都会先清掉 `/lib/modules/<ver>` 下所有
`ra9530-charger.ko` 副本（`updates/` 的优先级高于 `extra/`，残留副本会让 `modprobe`
一直加载旧版）。

重启后：

```sh
dmesg | grep -i ra9530                              # RA9530 rev 2 / transmitting (mode 0x04)
cat /sys/class/power_supply/ra9530-charger/status   # Charging
cat /sys/bus/i2c/devices/1-003b/rpp                 # 非 0 = 笔正在收功率
cat /sys/bus/i2c/devices/1-003b/pen_present         # 1 = 笔吸在磁吸位上
```

手动控制充电：

```sh
echo 0 | sudo tee /sys/bus/i2c/devices/1-003b/enabled   # 停
echo 1 | sudo tee /sys/bus/i2c/devices/1-003b/enabled   # 开
```

还原设备树：`sudo ./driver/install-dt.sh --revert`

**用户态不在这里**：读笔的 BLE 电量、按 85%/75% 控制充电、以及"笔吸在磁吸位上时
屏蔽笔输入"的停靠闸门，都在 **zcc-aur** 仓库的 `xiaomi-book-12.4-config` 包里，
装好即带 systemd 单元：

```sh
sudo pacman -S xiaomi-book-12.4-config              # 见 github.com/CerteKim/zcc-aur
systemctl status ra9530-charge-policy
/usr/local/bin/ra9530-pen-battery.sh                # 笔的准确电量（需先 BLE 配对）
```

---

## 目录结构

| 路径 | 内容 |
|---|---|
| **`driver/`** | 内核驱动 `ra9530-charger.c`、Makefile/Kconfig、设备树绑定 `renesas,ra9530.yaml`、节点片段 `ra9530.dtsi`、DTB 补丁脚本 `install-dt.sh`、编译脚本 `build.sh`、驱动说明 `README.md` |
| **`investigation/`** | 排查期间用的一次性脚本（探寄存器、扫引脚、抓 EPT、找电量…），保留作记录 |
| **`notes/`** | [完整调查笔记](notes/ra9530-stylus-charger.md) 与 [可提交上游的报告](notes/ra9530-upstream-report.md) |
| `install.sh` | 一键安装（驱动 + 设备树） |

> 原先这里有 `tools/`（BLE 电量读数、85%/75% 充电策略、systemd 单元）。它已经移出去，
> 现在是 zcc-aur 的 `xiaomi-book-12.4-config` 包 —— 同一个守护在两个仓库各留一份迟早
> 会漂，所以只保留包里的那一份。

---

## 关键事实（想要复现/移植的人看这几条）

1. **发射命令寄存器是 `0x0076`，写 `0x21`（`TX_EN|TX_FOD_EN`）**：

   ```sh
   i2ctransfer -f -y 1 w3@0x3b 0x00 0x76 0x21
   ```

   随后 `0x004D` 读作 `0x04`（TRx）、`0x0078` 由 `0x02` 变 `0x01`。
   **Renesas 评估手册上的 `0x007C` 是错的**（该芯片的 TX 寄存器块整体偏移 6 字节，
   往那里写会被接受、读得回来，但芯片**永不处理**）。

2. **开 Tx 之前必须先设反向模式 FOD 阈值**，否则芯片把功率压到接近 0
   （现象：协商成功、模式停在 TRx、笔却一直 0%）：

   ```sh
   i2ctransfer -f -y 1 w3@0x3b 0x00 0x92 0xf4   # 500 mW
   i2ctransfer -f -y 1 w3@0x3b 0x00 0x93 0x01
   ```

3. **I²C 速率应当是 400 kHz**（固件/ACPI 声明值），树里原来的 1 MHz 会让总线变差。

4. **GPIO**：`gpio11` = 电源开关（高有效）、`gpio186` = 7V 升压（高有效）、
   `gpio97`/`gpio189` = 两个霍尔（**读数不同即视为笔已吸附**）、
   `gpio101` = 芯片 INT（开漏低有效，用下降沿）。固件默认已把开关/升压拉高。
   两个霍尔脚还各注册了**双边沿中断**：跳变时驱动回写 `pen_present` 并
   `sysfs_notify()`，所以用户态只请求 `POLLPRI` 就能阻塞等通知，不必每秒轮询
   （实测端到端 3~6 ms）。另有 1 秒一次的 `detect_poll`，覆盖挂起期间丢掉的边沿。
   中断处理里只排一个 20 ms 的防抖 work —— 若在处理里直接干活，`IRQF_ONESHOT`
   会在等锁期间屏蔽该线，monitor 持锁做 I2C 刷新时到达的边沿就丢了。

5. **充电器从不上报笔的电量**（中断位图里永远没有 CSP/bit15），
   满电的笔也仍报 `rpp≈30`；**准确电量只能从笔自己的 BLE 拿**
   （`Xiaomi Smart Pen` 的 Battery Service，绑定后是 `org.bluez.Battery1`）。
   因此"停充策略"由 zcc-aur 的 `xiaomi-book-12.4-config` 包里的
   `ra9530-charge-policy.sh` 读 BLE 电量 + 写驱动的 `enabled` 来实现；它同时在
   `pen_present` 上等驱动的中断通知，笔吸在磁吸位上时屏蔽数字化仪报的笔事件
   （否则停靠中的笔被当成"悬停"，mutter 会把光标拽到磁吸位那个点）。

6. **充电器无法提供笔的 BLE 地址**：参考驱动读的 `0x00BE` 在本变体上是
   `00:00:00:00:93:00`（非法值），包体里也只有 3 个字节对得上。地址请从 BLE
   广播获取，并**按名字匹配**（那是随机地址，会轮换）。驱动会校验这个读数，
   拿不到就如实说"本变体不上报"。

7. 运行任何 `i2ctransfer` 时**要加 `-f`** —— 驱动占用该地址后，
   不加 `-f` 会被内核以 `EBUSY` 拒绝。

---

## 参考文献

* `nik012003/idtp9418-mainline` — <https://github.com/nik012003/idtp9418-mainline>
  小米平板 5（同款笔、同族 P9418）的驱动；**它的寄存器地图才与本芯片吻合**，
  `0x0076`/FOD/两个霍尔等关键点都来自它。
* `kernel/google-modules/bms`（Pixel）的 `p9221_chip.c` 有显式的 `ra9530_chip_tx_mode()`，
  但用的是 P9412 的地址（本机实测无效）。
* Renesas：RA9530/RA9520 Stylus Application AP Design Guide（R16UH0023EU0100）、
  RA953-R Evaluation Kit Manual（R16UH0022EU0200）。
