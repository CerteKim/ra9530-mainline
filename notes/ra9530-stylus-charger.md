# 磁吸触控笔充不上电：根因是 RA9530 没有任何驱动

调查日期 2026-10-03。Xiaomi Book S 12.4 (TIMI / SC8180X, `xiaomi,book-12.4`)。
相关脚本：[verify-ra9530.sh](../investigation/verify-ra9530.sh)

## 结论

笔本身的输入功能是好的（HID 有 Stylus 集合），充不上电是因为**磁吸充电那颗电源 IC
从未被驱动**：DT 节点被注释掉、mainline 没有驱动、Google 的驱动只实现了接收端。
IC 硬件完全正常且可达。

## 证据链

| 证据 | 内容 |
|---|---|
| I2C 可达 | `&i2c7` = `89c000.i2c`，探测前中断计数为 0（从未通信过） |
| 芯片 ID | `i2ctransfer w2@0x3b 0x00 0x00 r2` -> `0x30 0x95` = **0x9530 = RA9530_CHIP_ID** |
| 版本 | `0x02`=rev 2，`0x03`=customer id 2 |
| 厂商身份 | Windows 驱动 INF 里硬件 ID = **`ACPI\TXRA9530`**，设备名 "Wingtech SXB Charger-TXRA9530 Device" |
| DT 出处 | [sc8180x-xiaomi-book-12.4.dts:596-617](../../src/kernel/arch/arm64/boot/dts/qcom/sc8180x-xiaomi-book-12.4.dts#L596-L617) 注释 "// Charger / Device (SXB)" |
| 交叉验证 | 厂商 `wtSXBCharger.dll` 里的立即数为 `0x28/0x30/0x34/0x3a/0x4d/0x50/0x58`，与 Renesas 表一致 |
| 上游状态 | mainline 无 `ra9530`/`p9221` 驱动；Google `kernel/google-modules/bms` 的 RA9530 只做 RX，`p9221_chip_tx_mode()` 是 `return -ENOTSUPP`，RA9530 分支标注 `RTX_NOTSUPPORTED // TODO(270976020)` |
| 当前模式 | System Operating Mode (0x004D) = `0x80`，**不是 0x04**（Tx 未使能） |

参考文档：[RA9530/RA9520 Stylus Application AP Design Guide](https://www.renesas.com/en/document/mah/ra9530ra9520-stylus-application-ap-design-guide)
(R16UH0023EU0100 Rev.1.00, 2022-06-28)。器件：[RA9530](https://www.renesas.com/us/en/products/power-power-management/wireless-power/wireless-power-receivers/ra9530-50w-wireless-power-receiver-wattshare-trx-mode)。

## I2C 协议

从机地址 **0x3B**，**2 字节寄存器地址、MSB 先发**（大端），地址自增。与实测一致。

```bash
# 读 1 字节
sudo i2ctransfer -y 1 w2@0x3b 0x00 0x4d r1
# 读 chip id（2 字节，小端）
sudo i2ctransfer -y 1 w2@0x3b 0x00 0x00 r2     # -> 0x30 0x95
```

注意 `i2cdetect` 默认模式**探测不到 0x3b**（geni-i2c 不支持 SMBus Quick Write，只扫
`0x30-0x37`/`0x50-0x5f`）；要用 `i2cdetect -y -r 1`。另外 `i2cdetect -r` 的大范围扫描会让
`geni_i2c` 刷 `Bus arbitration lost, clock line undriveable`（27 次，全部集中在扫描那一刻）；
单次定向读写在 1 MHz 下正常，**不需要**降低总线速率。

## Tx（平板侧）寄存器表

| 寄存器 | 地址 | RW | 长度 | 说明 |
|---|---|---|---|---|
| System Interrupt Clear (TX) | `0x0028` | RW | 4 | 写 1 清对应中断位，再写 CLR Interrupt 命令 |
| System Interrupt (TX) | `0x0030` | R | 4 | 中断事件 |
| System Interrupt Enable (TX) | `0x0034` | RW | 4 | 中断使能 |
| Battery Charge Status | `0x003A` | R | 1 | 收到 CSP 中断后读笔的电量 |
| **System Operating Mode** | `0x004D` | R | 1 | **`0x04` = Tx 已使能** |
| Proprietary Data-Out | `0x0050` | RW | 8 | 发给笔的私有包 |
| Proprietary Data-In | `0x0058` | RW | 8 | 笔发来的私有包 |
| Tx EPT Type | `0x007A` | R | 2 | 错误类型（FOD/OCP/OVP/OTP/超时…） |
| **TX System Command** | `0x007C` | RW | 2 | bit0=**TX EN**, bit1=CLR Interrupt, bit2=TX DIS, bit3=TX BC, bit4=TX WD, bit14=OPEN LOOP SYNC, bit15=TGL OPEN LOOP |
| BLE MAC Address | `0x01B4` | R | 6 | 可选 BLE 配对 |

命令寄存器是**自清除**的：IC 处理完自动清位；两次写命令间隔需 **≥3–5 ms**。

## 上电时序（关键，也是目前最大的未知）

Tx 模式下 **RA9530 内部没有 boost**，平板必须提供两样东西：

1. 外部 **Switch IC**：AP 控制，给 IC 的 VIN 供电，**VIN 压摆率必须 < 5V/ms**；
2. 外部 **Boost IC**：软启动使能，其 enable 由 IC 自己的 **PWM/GP1 (D3)** 脚驱动。

流程（指南 4.2 / 5.4.1）：

```
笔吸附
  -> 打开 Switch IC
  -> 等 5ms
  -> Boost IC 软启动
  -> 等中断 "Tx Initialization Done"
       (若收到 "EPT Type" 中断: 读 0x007A, 关 Switch IC, 放弃)
  -> 写 TX System Command (0x007C) bit0 = TX EN
  -> 等 100ms
  -> 读 0x004D，== 0x04 才算成功；否则读 0x0030 记录事件并断电
```

DT 节点里有 **2 个 GPIO**（`tlmm 11`、`tlmm 186`，都标 `GPIO_ACTIVE_LOW`），几乎可以肯定
就是 Switch IC 和 Boost 的使能；**3 个中断**（`tlmm 101` LEVEL_LOW、`189` EDGE_LOW、
`97` EDGE_LOW），而 Renesas 只定义了 1 条 IC 中断（OD2，开漏、低有效），所以 `101` 应是
IC 中断，另两条大概是笔吸附检测和故障/PG。

Windows 下这套时序很可能由 **ACPI 固件方法**完成（DT 注释里提到 `Device (SXB), Method _CRS`）。
Linux 用 DT，没有那份固件可跑，**必须在驱动里自己复现**。

## GPIO 现状（已实测）

`&tlmm` = `3100000.pinctrl` = `gpiochip3`(cdev) / `gpiochip544`(sysfs base) / 191 条线。
**五根脚全是 `func0` = GPIO 功能**，所以不需要为了驱动它们而改 DT 补 pinctrl。

| 引脚 | 实测状态 | 解读 |
|---|---|---|
| gpio11 | `out high` **16mA** pull-up | **供电/复位使能，高有效**（实测拉低后 IC 从 I2C 消失，见下）；开机固件已拉高 = 已供电 |
| gpio186 | `out high` **16mA** pull-up | 第二个使能脚，角色待定（可能是 Boost / 第二路电源开关） |
| gpio101 | `in high` | 空闲高 → 符合 Renesas 描述的 IC 中断 OD2（开漏、低有效、默认高） |
| gpio189 | `in high` | 第二根中断 |
| gpio97 | `in low` | 第三根，当前为低（可能是吸附检测） |

### gpio11 是供电/复位使能，高有效（实测）

用户态实验：把 gpio11 拉低后，I2C 访问立刻变成
`Error: Sending messages failed: No such device or address`（ENXIO，芯片不再 ACK 地址），
恢复高之后芯片回来。所以：

* **gpio11 高 = IC 活着，低 = IC 死掉**；
* DT 注释里给它标的 `GPIO_ACTIVE_LOW` **是错的**，应改成 `GPIO_ACTIVE_HIGH`；
* 开机固件（ABL）已经把它拉高 —— **IC 本来就是上电的**，缺的只是 TX EN 命令。

### 中断使能寄存器说明了什么

基线读到 `IRQ_EN (0x0034) = 0x000021FF` = bit 0–8 + bit 13。对照 Table 4，
这正好是 Tx 握手那一组中断：

```
bit0  EPT Type              bit1  Start Digital Ping     bit2  Signal Strength Packet
bit3  Identification Packet bit4  Configuration Packet   bit5  Operation Mode Change
bit6  TX Conflict           bit7  TX Initialization Done bit8  BLE Address Received
bit13 Proprietary Packet Received
```

也就是说 **固件早就把 IC 配成了 "Tx 待命、中断就绪"**，只差那条 TX EN。

### Tx 侧中断事件表（Table 4）

| bit | 名称 | AP 该做什么 |
|---|---|---|
| 17 | Pen Authentication Pass | 记日志 |
| 16 | Pen Authentication packet Received | 清中断 |
| 15 | **CSP Packet Received** | 读 Battery Charge Status `0x003A`（笔的电量） |
| 14 | EPT Restart Received | 清中断 |
| 13 | **Proprietary Packet Received** | 读 Proprietary Data-In `0x0058` |
| 8 | **BLE Address Received** | 读 BLE MAC `0x01B4` |
| 7 | **TX Initialization Done** | 配置 user register，然后使能 Tx |
| 6 | TX Conflict | 清中断 |
| 5 | Operation Mode Change | 清中断 |
| 4 | Configuration Packet Received | 清中断 |
| 3 | Identification Packet Received | 清中断 |
| 2 | Signal Strength Packet | 清中断 |
| 1 | Start Digital Ping | 清中断 |
| 0 | **EPT Type** | 读 `0x007A`，**先撤掉输入电源**，排除故障再重启 Tx |

### 中断清除流程（指南 5.1.1，容易做错）

INT 脚是**开漏、低有效、下降沿有效**（DT 里写的 LEVEL_LOW 建议改成 `IRQ_TYPE_EDGE_FALLING`）。

```
1. 读 Tx System Interrupt (0x0030) -> m
2. 把【m 本身】写回 Tx System Interrupt Clear (0x0028)   <-- 不能写 0xFFFFFFFF！
3. 写 0x02 到 TX System Command (0x007C) = Clear Interrupt
4. 校验: INT 脚回到高，且 0x0030 == 0；否则重复 1-3
```

注意指南明确写着：**只有清寄存器里设置了与中断寄存器相同的位，Clear Interrupt 命令才生效**。


sysfs 映射：base 544 → gpio11=`gpio555`，gpio101=`gpio645`，gpio186=`gpio730`。

### sysfs GPIO 的坑（已核对 `drivers/gpio/gpiolib-sysfs.c`）

`direction` 写 **`out` 或 `low` 都会先拉低**（`gpiod_direction_output_raw(desc, 0)`），
会在上电瞬间产生低毛刺。**必须写 `high`** 才能原子地设为"输出 + 高"，做初始化和恢复。

## 使能 Tx 的两条路（关键！）

来自 [RA9530 Evaluation Kit Manual](https://www.renesas.com/en/document/mah/ra9530-evaluation-kit-manual?r=1649576)
(R16UH0022EU0200)：

**路线 1 — 软件命令**：向 `0x007C` 写 `0x0001`（bit0 = TX EN）。

**路线 2 — 硬件引脚 GP2/TX_EN（芯片第 10 脚）**：
> "The GP2 pin is a digital input referenced to VDDIO. If GP2 is pulled up by VDDIO,
> TRx mode starts working automatically when external power is connected to the VOUT pin."
>
> "TRx Mode Auto-Enable: The RA9530-R enters into TRx mode automatically if GP2 level
> is high **when** Vout is powered by external power or AP."

即触发条件是「**VOUT 上电时 GP2 已经是高**」—— 是一个**边沿/上电事件**，不是电平。
手册还要求 TRx 模式下 VOUT 供 **7–9V** 才能输出 5W（最低 5V）。

**本板走的是路线 2**：厂商 Windows 驱动 `wtSXBCharger.dll` 里
**一次都没有 `0x7C`**（objdump 全量搜 `#0x7c` = 0 处），它只用
`0x28/0x30/0x34/0x3a/0x4d/0x50/0x58`。既然它也用 `0x50/0x58`（只在 TX 模式可用的
私有包寄存器），说明 Tx 是靠硬件脚使能的 → **gpio186 很可能就是 GP2/TX_EN**。

### 实测：软件命令无效

向 `0x007C` 写 `0x0001` 后，MODE / IRQ / IRQ_EN / EPT **一个位都没变**，也没产生中断。
符合手册的 `TX Status (0x007E) bit1 = "TX ready: chip is ready and wait for TX_EN command"`
—— **芯片没 ready，命令就不被受理**。

## System Operating Mode Register (0x004D) 取值

| 值 | 含义 |
|---|---|
| **`0x80`** | **Back Powered**：由 VRECT 或 VOUT 供电，但 **Tx 未使能** ← 实测就是这个 |
| `0x04` | **TRx Mode**（目标） |
| `0x09` | Extended WPC Mode |
| `0x01` | Basic WPC Mode |
| `0x00` | AC Missing |

## 诊断用寄存器（本次新增）

| 寄存器 | 长度 | 含义 |
|---|---|---|
| `0x007E` | 8 | TX Status：bit1 = **TX ready**（等 TX_EN 命令）、bit3 = TX transfer |
| `0x0080` | 16 | **Vin**，单位 mV（TX 模式） |
| `0x0082` | 16 | **Vrect**，单位 mV（TX 模式） |
| `0x0084` | 16 | 芯片结温，摄氏度 |

## 卡点精确定位（2026-10-03 实测）

**唯一未解的问题：`TX Status (0x007E) bit1 = TX ready` 始终为 0。**

已排除的：

| 假设 | 实测 | 结论 |
|---|---|---|
| 供电不对 | Vin 7044 mV、Vrect 7032 mV、结温 33 °C | 排除（TRx 要求 7–9V） |
| I2C 写不进去 | 写 `0xa55aa55a` 到 `0x0050` 读回完全一致 | 排除 |
| 芯片 Tx 参数未配置 | Ping Interval 11000 / Freq 500 / Duty 156 / LV 500 / OV 412 / FOD 800·65436·3700 / Q 30 | 排除（已配置） |
| gpio186 = GP2/TX_EN | 下降沿、上升沿、配合 gpio11 断电重启，全部无变化 | 排除 |
| 芯片坏了 | ID 0x9530 / rev 2 / 客户号 2，各寄存器语义正确 | 排除 |

**命令被写入但从未被处理**（决定性证据）：

```
写 0x007C = 0x0001 → 立刻读 = 0x01 0x00 → 300ms 后读 = 0x01 0x00
```

手册写的是 "**Chip clears the bit after processing the command**"。位一直挂着 = 芯片根本没去处理。

**寄存器存在模式门控**：所有 `>= 0x0108` 的 Tx 模式寄存器（OC 阈值、频率上下限、最小占空比、
TX DC Power…）读取全部 NACK；`<= 0x00FC` 全部正常。说明芯片在非 Tx 模式下会拒绝这些访问。

### 关键外部事实

小米官方 FAQ（[Xiaomi Smart Pen FAQ](https://www.mi.com/ph/support/faq/details/KA-07775/)）：

> "**Magnetically attached: Fully charge your Xiaomi Smart Pen in up to 18 minutes.**"
> "…we specially designed an **anti-float charging strategy** so that when the pen is fully charged,
> the pad will not continue to charge until the pen is drained to 70%…"

即充满即停、掉到 70% 再充 —— **这种策略必须由主机侧软件实现**（对应 Renesas 指南里
"AP may decide to remove power to the wireless charging system when battery is fully charged"）。
所以一定存在一个主机侧驱动/服务在管这件事。

**并且：用户确认在 Windows 下这支笔能正常磁吸充电** —— 硬件路径通，缺的是一个软件步骤。

### ACPI 表在 Linux 侧拿不到

`/sys/firmware/acpi` 不存在（内核用 DT 启动，ACPI 表被绕过），所以 DSDT 只能从
Windows 或 UEFI 固件侧取。`/boot/Persisted_Capsules.bin`（73MB）是加密/不透明格式，无明文 DSDT。

## Windows 分区里的发现（2026-10-03，只读挂载 /dev/nvme0n1p3）

* 装的就是我们手上那个 `wtSXBCharger.dll`（**sha256 完全相同**：
  `437772e8618003d84b2697e44ff68c4b08f271e9f39c47c0ac95257a1f6edcee`），
  位置 `Windows\System32\drivers\UMDF\` 与 DriverStore。它是**正规 UMDF2 驱动**
  （导出 `FxDriverEntryUm`，含 `WUDFx02000` 桩库符号；Fx 符号运行时由 UMDF host 绑定，
  所以导入表里看不到 WUDFx）。
* 设备实例：`ACPI\TXRA9530\1`，Service = `WUDFRd`，DeviceDesc =
  "Wingtech SXB Charger-TXRA9530 Device"，INF = `oem31.inf`。
* 驱动暴露设备接口 `\DosDevices\Global\WTSXBCHARGER`
  （GUID `{5e1c461f-6e0a-4d5b-8056-951928e4d2b4}`），但**磁盘上没有对应的用户态程序**
  （该 GUID 只出现在 setupapi 日志里）。
* **驱动会访问 `\\.\RESOURCE_HUB\...`** —— 这是 Windows 的 **RhProxy** 管道。
  **更正**：先前把它写成"OS 与固件/EC 共享资源并做所有权交接"是**错的**。
  按 [Microsoft 文档](https://learn.microsoft.com/en-us/windows/apps/develop/devices-sensors/enable-usermode-access)，
  RhProxy 的作用是 **"exposes GpioClx and SpbCx resources to user mode"**：
  纯粹是让**用户态**程序能访问 GPIO/I2C/SPI 的安全管道。UMDF 驱动是用户态、
  不能直接碰引脚，所以必须经它申请自己的连接资源 —— **与固件门控无关**。
* `Device (RHPX)` 的 `_CRS` 只列了**一项**资源：`I2cSerialBusV2 (0x0048, ... "\\_SB.I2C2")`，
  `_DSD` 给它起名 `"bus-I2C-I2C1"`。即固件把 **I2C2（0x884000 = Linux `i2c-0`，
  触屏那条总线）上地址 `0x48` 的目标**开放给用户态 —— 而这个 0x48 是什么设备，
  **我们从来没扫过 `i2c-0`**（只扫过 `i2c-1`）。
* 注册表 `Enum\ACPI\TXRA9530\1\LogConf\BootConfig`（REG_RESOURCE_LIST，140 字节）
  解出的资源构成：**1×I2C（Class=2/Type=1） + 2×GpioIo（Class=1/Type=2） +
  3×GpioInt（转成中断资源，GSI 1051/1052/1053）** —— 与 DT 注释里的
  "3 中断 + 2 gpio + i2c 0x3b" **完全一致**。
  但**翻译后的连接资源不带引脚号**（只有不透明的连接 Id），所以引脚仍然只能从
  DT/DSDT 得到。`Device Parameters\FirmwareIdentified = 1`。

解析工具：[parse-regf.py](../investigation/parse-regf.py)（自己实现的 regf 只读解析器，不需要 root）。

## 时序枚举：AP 的 GPIO 不参与 Tx 使能（2026-10-03 实测）

[ra9530-enable-sweep.sh](../investigation/ra9530-enable-sweep.sh) 枚举了 6 组 gpio11 / gpio186 时序，
**全部无效，每次都精确停在 `MODE=0x80 / TX_STAT=0x00 / IRQ=0`**：

| 用例 | 结果 |
|---|---|
| gpio186=0 + gpio11 断电重启（假设板上 GP2 反相） | 0x80 |
| gpio186 单独 1→0→1 | 0x80 |
| gpio186=1 + gpio11 断电重启 | 0x80 |
| gpio186=0，gpio11 重启后再拉高 gpio186 | 0x80 |
| 两根都拉低 → 先 gpio186 后 gpio11 | 0x80 |
| 两根都拉低 → 先 gpio11 后 gpio186 | 0x80 |

**结论：Tx 使能不在 AP 侧这两个 GPIO 的时序里。** 结合 Resource Hub 线索，
最可能的是固件（UEFI/EC）持有 Tx 的门控，只有 Windows 侧的 Resource Hub 客户端
接管后才放开。

## 如何取 DSDT（唯一能看清固件侧的地方）

Linux 以 DT 启动，`/sys/firmware/acpi` 不存在，ACPI 表拿不到；Windows 分区上也没有残留。
只能启动一次 Windows 把表 dump 出来。

### 方案 1：PowerShell 调 Win32 API（推荐，不需要第三方工具）

管理员 PowerShell 里整段粘贴：

```powershell
Add-Type -Namespace W -Name Api -MemberDefinition @"
[DllImport("kernel32.dll", SetLastError=true)]
public static extern uint EnumSystemFirmwareTables(uint sig, byte[] buf, uint size);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern uint GetSystemFirmwareTable(uint sig, uint id, byte[] buf, uint size);
"@
$sig = 0x41435049                      # 'ACPI'
$n   = [W.Api]::EnumSystemFirmwareTables($sig, $null, 0)
$ids = New-Object byte[] $n
[void][W.Api]::EnumSystemFirmwareTables($sig, $ids, $n)
$out = "C:\Users\Public\acpi"
New-Item -ItemType Directory -Force -Path $out | Out-Null
for ($i = 0; $i -lt $n; $i += 4) {
  $id = [BitConverter]::ToUInt32($ids, $i)
  $sz = [W.Api]::GetSystemFirmwareTable($sig, $id, $null, 0)
  if ($sz -le 0) { continue }
  $t = New-Object byte[] $sz
  [void][W.Api]::GetSystemFirmwareTable($sig, $id, $t, $sz)
  $nm = ([Text.Encoding]::ASCII.GetString($t,0,4) -replace '[^A-Za-z0-9]','_') + "_$($id.ToString('X8')).bin"
  [IO.File]::WriteAllBytes("$out\$nm", $t)
}
Get-ChildItem $out | Select-Object Name, Length
```

### 方案 2：直接导出注册表里的 ACPI 库（一条命令，可能也含表体）

```cmd
reg export "HKLM\HARDWARE\ACPI" C:\Users\Public\acpi_hardware.reg /y
```

两者都写到 `C:\Users\Public\`，重启回 Linux 后可直接从 `/mnt/win/Users/Public/` 读。

回 Linux 后装个反编译器即可分析：

```bash
sudo pacman -S acpica        # 提供 iasl
```

要在 DSDT 里找的东西：`Device (SXB)` 的 `_CRS`、它引用的 `_PR0`/`PowerResource`
及其 `_ON`/`_OFF` 方法（**真正的上电时序，可能用一个我们还没碰过的引脚**）、
以及任何 Resource Hub / 固件共享资源相关的对象。

## 突破口：Tx 初始化中断终于出现了（关键）

慢速扫描（每组保持 15s、每秒轮询）在 **「两脚都低 → gpio11 高 → 50ms → gpio186 高」**
之后出现：

```
IRQ (0x0030) = 0x00002080
  bit7  *** TX Initialization Done ***      <- 指南要求"使能 Tx 之前必须等到"的信号
  bit13 Proprietary Packet Received         <- 收到笔发来的包
INT 脚 (gpio101) 从 1 变 0
```

说明两件事：

1. **芯片确实被这个时序推进了 Tx 初始化**；
2. 之前所有「写 0x7C 无效」的实验，最可能的原因是**芯片处在中断未清除状态**，
   而指南 5.1.1 明确要求"**先把中断清掉，再执行中断事件操作**"。

完整流程见 [ra9530-tx-go.sh](../investigation/ra9530-tx-go.sh)：

```
触发时序 → 等 bit7 → 读 0x0030 得 m → 把 m 写回 0x0028 → 写 0x02 到 0x007C (CLR INT)
        → 校验 0x0030 == 0 → 写 0x0001 到 0x007C (TX EN) → 等 100ms → 读 0x004D，期望 0x04
```

## 最终结论：Tx 被芯片外部的一层门控挡住，AP 够不到

### 1. 电源路径已完全查清（实测）

| 引脚 | 角色 | 证据 |
|---|---|---|
| `gpio11` | IC 开关/使能（指南里的 **Switch IC**） | 写标记法：拉低 600ms 后 `0x0050` 的 `DEADBEEF` 丢失 → 芯片真的复位 |
| `gpio186` | **7V 升压使能**（指南里的 **Boost IC**） | 拉低 → `Vin` 3793mV；拉高 → 6998mV |

标准上电顺序 = 两脚低 → gpio11 高 → 50ms → gpio186 高，**正是指南 5.4.1 第 1 步**。

### 2. 命令接口整体失效（决定性）

[ra9530-cmd-test.sh](../investigation/ra9530-cmd-test.sh) 逐位测试 `0x007C`（手册：每一位都是
"AP writes 1 … **Chip clears the bit after processing the command**"）：

```
bit0 TX EN          -> 写了不清
bit1 CLR Interrupt  -> 写了不清
bit2 TX DIS         -> 写了不清
bit3 TX BC          -> 写了不清
bit4 TX WD          -> 写了不清
被清除的命令位: 0 个    一直挂着的: 5 个
```

**整个 `0x007C` 都不被处理** —— 不是我们写错位，而是 Tx 通路在命令接口这一层就被禁用。
对照之下，同一颗芯片的普通寄存器读写完全正常（`0x0050` 写读回一致、`0x4D`/`0x80` 数值合理）。

### 3. 推断

* 手册写明 Tx 的两条使能路径：**GP2/TX_EN 引脚为高**（VOUT 上电时自动进 TRx），
  或**软命令** `0x007C` bit0。本板两条都不通 → 指向 **GP2/TX_EN（芯片第 10 脚）为低**。
* DSDT 里 SXB 设备只有 2 个 GpioIo（= 开关 + 升压），**没有任何资源能驱动 GP2**
  → GP2 不在 AP 的可控范围内（板上接地或由 EC/固件驱动）。
* 厂商 Windows 驱动（UMDF，经 rhproxy 访问资源）**从不写 `0x007C`**，
  只做监控/读笔电量/收发私有包 → 它在 Windows 上也不是"使能者"。
  ⇒ **Windows 下把 Tx 打开的另有其人**（固件/EC），而 Linux 侧没有对应接口。

### 4. 三根"中断"脚定位完毕（实测）

| 引脚 | 实测行为 | 结论 |
|---|---|---|
| `gpio101` | 一直高，不随笔/电源变化 | IC 的 INT（OD2，开漏低有效、空闲高）✓ |
| `gpio97` | **笔拿开 = 1，笔贴上 = 0** | **笔吸附检测，工作正常** ✓ |
| `gpio189` | 一直高，不随笔/电源变化 | **未知**（唯一没搞清的一根） |

**重要：吸附检测是好的，笔确实被检测到（97 = 0 = 已吸附）。** 所以根因不是"笔没被识别"。

## 待办

- [x] `libgpiod` 看 `tlmm 11/186/97/101/189` 当前是否被复用为 GPIO、方向与电平
- [x] 确认 gpio11 = 供电/复位使能（高有效），且开机固件已拉高
- [ ] 直接写 TX EN 验证：[ra9530-txen.sh](../investigation/ra9530-txen.sh)
      —— **已实测：无效**（MODE 仍 0x80，寄存器无任何变化，因为芯片没 ready）
- [ ] 探测 TX ready 条件：[ra9530-txready.sh](../investigation/ra9530-txready.sh)
      —— **已实测：无效**。电源/写路径/参数都正常，`TX ready` 就是不置位
- [ ] 扫 Tx 参数寄存器：[ra9530-txparams.sh](../investigation/ra9530-txparams.sh)
      —— **已实测：参数齐全，不是"没配置"**
- [x] **从 Windows 分区找生产版 SXB 驱动** —— 装的就是同一个 DLL（sha256 一致）；
      资源 = 3×GpioInt + 2×GpioIo + 1×I2C；驱动访问 `\\.\RESOURCE_HUB\...`
- [x] 6 组 gpio11/gpio186 时序枚举：[ra9530-enable-sweep.sh](../investigation/ra9530-enable-sweep.sh) —— 全部无效
- [ ] 拿到 DSDT（见本文上一节 PowerShell），查 `Device (SXB)` 的 `_PR0` / `PowerResource`
      / `_ON` 时序 —— 重点找**我们还没碰过的引脚**（很可能就是 7V boost 使能）
- [ ] 若 DSDT 不可得：受控扫描候选引脚（TLMM 上固件配成 16mA 输出、未被任何驱动认领的
      `gpio54/100/118/130/152/158/187/188`；其中当前为 low 的 `100/158/187` 最可疑）
- [ ] 确认 gpio186 的真实功能；确认 gpio97 / gpio189 这两根中断分别是什么
- [x] ~~用户态分阶段上电验证：[ra9530-bringup.sh](../investigation/ra9530-bringup.sh)~~
      —— 该脚本的 Stage A 主动拉低了 gpio11，把 IC 电源断掉，设计有误；保留仅作参考
- [ ] DT：`&i2c7` 恢复节点 + 补上**整棵树里缺失**的 `txra9530_int_default` pinctrl；
      **gpio11 必须写成 `GPIO_ACTIVE_HIGH`**，中断建议 `IRQ_TYPE_EDGE_FALLING`
- [x] **写驱动前的寄存器地址已确定**（见文末突破章节）

---

# ★★★ 突破（2026-10-06）：Tx 已经能开了 ★★★

## 一句话

**发射命令寄存器是 `0x0076`，写 `0x21`（`TX_EN=bit0 | TX_FOD_EN=bit5`）即可进入 TRx。**

```bash
# 实测有效（i2c-1, 从设备 0x3b, 400 kHz）
i2ctransfer -y 1 w3@0x3b 0x00 0x76 0x21     # ★ 使能 Tx
i2ctransfer -y 1 w2@0x3b 0x00 0x4d r1       # -> 0x04 = TRx Mode（正在发射）
i2ctransfer -y 1 w2@0x3b 0x00 0x30 r4       # -> 0x04 = bit2 收到笔的信号强度包
```

实测输出（[ra9530-tx-enable.sh](../investigation/ra9530-tx-enable.sh) 路线 B 第一次即成功）：

```
MODE(4D)=0x04  0x76=0x00  0x78=0x01  0x7C=0x00 0x00  0x7E=0x00  IRQ(30)=0x04 0x00 0x00 0x00
```

* `0x4D = 0x04` = **TRx Mode**（手册里的 0x04 是对的）
* `0x78` 由 `0x02` 变 `0x01`（这正是 idtp9418 驱动的判据）
* `IRQ(0x30) bit2` = **收到笔的信号强度包** ⇒ **笔已应答，正在充电**

## 关键更正：TX 区寄存器地址应取 idtp9418 的表，不是评估手册的

之前用 `pdftotext -layout` 从评估手册 PDF 提取的 TX 寄存器表**整体偏移了 6 字节**
（表格列错位），所以一直往 `0x7C` 写、永远不生效。

| 用途 | 手册（偏移 6，错） | **本芯片实际（idtp9418 / 实测）** |
|---|---|---|
| Tx EPT Type | 0x007A | **0x0074** |
| **TX System Command** | 0x007C | **0x0076** ← 写 0x21 |
| TX Data/Status | 0x007E | **0x0078** |
| WROK Mode | — | 0x007B |
| System Operating Mode（只读） | 0x004D ✓ | 0x004D ✓（**实测写它无效**） |
| COM 命令寄存器 | 0x004E | **0x004E** |
| Reverse 模式 V/I/T | — | 0x006E/0x006F/0x0070/0x0071/0x007A |

IRQ(`0x0030`) 位定义同样取 idtp9418 的 TRX 表：
`bit0 EPT | bit1 START_DPING | bit2 GET_SS | bit3 GET_ID | bit4 GET_CFG | bit5 GET_PPP |
bit6 GET_DPING | bit7 INIT_TX | bit8 GET_BLE_ADDR`；另有 `bit13` ID 认证成功、`bit15` CSP(笔电量)。

## 两个已证伪的路线（免得重复走）

* **Google `ra9530_chip_tx_mode()` 的"写 `0x4D = 0x80`"在本芯片上无效** —— 试了 3 次，
  `0x4D` 始终 `0x80`。那套 `0x4D/0xA0/0x94` 地址属于 P9412，不是本板这颗。
* **评估手册的 `0x7C = 0x0001`** 同样无效（地址错位所致）。

## 参考实现

* **[nik012003/idtp9418-mainline](https://github.com/nik012003/idtp9418-mainline)** —— 小米平板 5
  (nabu/elish) 给同一支笔充电的驱动，**地址表与本芯片吻合**，可直接照搬：
  两个电源 GPIO（`enable`=开关=我们的 gpio11、`boost-enable`=升压=我们的 gpio186）、
  两个霍尔检测脚（`pen-det-active-{low,high}`，**两者读数不同即视为笔已吸附** =
  我们的 gpio97/gpio189）、反向 FOD 阈值、`charge_limit` 到量停充、`0x3A` 上报笔电量。
* `kernel/google-modules/bms`（Pixel）的 `p9221_chip.c` 有 `ra9530_chip_tx_mode()`，
  但地址是 P9412 的，仅供参考。

## 下一步

1. `sudo ./ra9530-charge-monitor.sh` —— 保持 Tx 并观察 `0x003A`
   （笔电量，**与 Windows 驱动读的是同一个寄存器**）
2. 写驱动：DT 节点（i2c7@0x3b + gpio11/gpio186/gpio97/gpio189/gpio101）
   → probe 校验 chip id `0x9530` → 笔吸附时使能开关/升压 → 写 `0x76=0x21`
   → 校验 `0x4D==0x04` → IRQ 处理（CSP 上报电量、EPT 处理错误）
   → 到量或笔离开时写 `TX_DIS`(bit2) 停充
3. 退出 Tx：`chip_set_cmd(P9412_CMD_TXMODE_EXIT = BIT(9))` 写 COM 寄存器 `0x4E`

---

# ✅ 结果：笔已在 Linux 下充上电（2026-10-06）

## 最小可用步骤（两步）

```bash
sudo i2ctransfer -y 1 w3@0x3b 0x00 0x92 0xf4     # 反向 FOD 阈值 = 500mW
sudo i2ctransfer -y 1 w3@0x3b 0x00 0x93 0x01
sudo i2ctransfer -y 1 w3@0x3b 0x00 0x76 0x21     # ★ 使能 Tx
```

开关(`gpio11`)/升压(`gpio186`)由固件默认拉高，无需干预。
**SRAM 易失 —— 掉电/重启后需重新执行。**

## 成功证据

* `MODE(0x4D) = 0x04`（TRx）、`0x78 = 0x08`
* **`RPP(0xA6) = 0x1e` 全程恒定非零** —— RPP = "Received Power Packet"，
  **笔自己报告收到了功率**，这是最硬的证据
* `CEP(0xA5)` 在 `0x00/0x01/0x02/0x06` 间跳动 = 笔在主动调节
* `IIN(0x6E/6F) ≈ 137`、`VIN(0x70/71) ≈ 7360mV`，结温稳定 39 °C（空载 30 °C）
* 移动笔时（305s）出现一次重新协商：`0x78=0x01`、`CEP=0x06`、`IIN→8`、`VIN→7054`，随后自恢复
* **用户实测：笔已能在屏幕上正常书写** ✅

## 之前为什么失败（一句话）

**发射命令寄存器是 `0x0076`，而且开 Tx 之前必须先设反向 FOD 阈值 `0x92/0x93`。**
前者我们写错了地址（0x7C），后者我们完全没做（实测原来是 `0x00/0x00` 空值）。

## 遗留项（写驱动要解决）

1. **`SOC(0x003A)` 恒为 `0x00`**，而 `IRQ(0x0030)` 也恒为 0 —— 尽管充电正常。
   推测：**`0x0030` 是读即清的**，我们 5 秒一次的轮询把事件吃掉了。
   → 驱动应**用 `gpio101` 作中断线（下降沿）**，而不是轮询。
   驱动还需要它做"到量停充"（参考实现用 `charge_limit`，默认充到 100%、
   掉到 95% 再补 —— 对应小米的 anti-float 行为）。
2. 退出 Tx：`0x004E`(COM) 写 `P9412_CMD_TXMODE_EXIT = BIT(9)`；停充亦可写 `TX_DIS`(bit2)。
3. 对齐/异物：`ALIGN_X(0xB0)` 等可用于提示笔的摆放位置。


## 笔电量归属（实测定论）

`irq_seen` 累积位图（完整充电一轮后）：

```
0x0000213f bit0=EPT bit1=START_DPING bit2=GET_SS bit3=GET_ID bit4=GET_CFG
           bit5=GET_PPP bit8=GET_BLE bit13=IDAUTH_OK
```

**没有 bit15(CSP)** —— 笔走完全部 WPC 协商、ID 认证成功、连 BLE 地址都发了，
**但从不发"电量包"**。所以：

* `0x003A`（同族驱动的 `REG_CHG_STATUS`）**地址没读错**，是这颗笔/这套组合
  根本不通过充电器上报电量，该寄存器永远为 0；
* **笔电量在 Linux 里本来就有**：触屏控制器通过 HID 上报，
  内核通用 HID 电池支持暴露为
  `/sys/class/power_supply/hid-0018:4858:121A.0003-battery`（实测 25%，且会变化）。
  Windows 多半也读这条。
* 因此驱动的 `capacity` 恒为 0 属预期；"充满停充"改由**用户态**用 HID 电量 + 驱动的
  可写 `enabled` 开关实现（内核/用户态正确分工）。
