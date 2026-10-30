# "GPU UT AggD Stats" 是不是核心级占用（2026-10-31）

结论：**不是。** 这组通道统计的是驱动的一个控制环在 GPU 通电期间、每约 0.27 ms 采一次的"UT 介入程度"，按频率档分开累计。从名字和相邻通道看，它最像某种节流（throttle）环路，不反映有几个核心在忙，也不反映核心忙得多满。普通权限和 root 能看到的 IOReport 通道完全一样；`powermetrics` 的 GPU 部分也没有核心字段。在这台机器上，**拿不到核心级占用**。

机器：Mac17,14，Apple M5 Max，GPU 40 核，13 档 338–1620 MHz，两台 5K 显示器（240 Hz、144 Hz），macOS 26B123。所有数字来自 2026-10-31 03:20–03:50 的测量。

## 1. 通道和字段

一共两组，数据是同一份：

| 组 / 子组 | 通道 | IOReport 格式 | 含义（实测） |
|---|---|---|---|
| GPU UT AggD Stats / Count | `AGX.Count_UT_Engagement_Perf_State_0..15` | 1 = simple（单个整数，开机以来累计） | 在该频率档下采样的次数，包括值为 0 的 |
| GPU UT AggD Stats / Not_Engaged_Count | `AGX.UT_Not_Engaged_Perf_State_0..15` | simple，累计 | 其中值为 0（"未介入"）的次数 |
| GPU UT AggD Stats / Sum | `AGX.Sum_UT_Engagement_Perf_State_0..15` | simple，累计 | 介入时的值之和，单位 centi-%（0.01 %） |
| GPU UT AggD Stats / Min | `AGX.Min_UT_Engagement_Perf_State_0..15` | simple，**开机以来的最小值**（不是累计，相减没有意义） | 介入时的最小值，各档都是 1 |
| GPU UT AggD Stats / Max | `AGX.Max_UT_Engagement_Perf_State_0..15` | simple，开机以来的最大值 | 介入时的最大值，各档 220–1327（2.2–13.3 %） |
| GPU UT Engagement / "UT Engagement centi-% Histogram for perf state N" | `GPU UT Engagement centi-%` ×16 | 3 = histogram | 同一个量按档分的直方图：0–950 centi-% 每 50 一格共 19 格，再往上每 1000 一格共 10 格 |
| GPU Stats / UT Engagement centi-% Histogram | `GPU UT Engagement centi-%` | histogram | 16 档合在一起的直方图 |

- 单位标签全是空的（`IOReportChannelUnit = 0`）。"centi-%" 来自直方图的名字。驱动是 `AGXAcceleratorG17X`。
- 核对过的关系（280 个 1 秒样本；单行误差最多 3，来自各通道读取时刻不同；总量误差小于 0.001 %）：
  - `Count − Not_Engaged` = 直方图命中次数
  - `Sum` = 直方图的和
  - 也就是说，AggD 是直方图的汇总；介入值为 0 的样本不进直方图，只记进 Not_Engaged。
- Perf_State_N 对应 GPUPH 的 PN。满载时只有 State_13 在涨，空闲时只有 State_1 在涨；State_0 和 14、15 从不变化。
- Count 的速度约等于 GPU 通电时间 × 3.4–3.8 kHz（空闲每通电秒约 3425 次，满载约 3830 次）；GPU 关着（GPUPH OFF）时不计数。所以 Count 只是"通电多久"的计时，不含负载信息。
- 开机以来的原始值见 [ut-aggd-since-boot.txt](ut-aggd-since-boot.txt)，通道定义见 [ut-aggd-channels.txt](ut-aggd-channels.txt)，直方图分格见 [ut-aggd-histcfg.c](ut-aggd-histcfg.c)。

## 2. 测量方法

- 采样程序 [ut-aggd-sample.c](ut-aggd-sample.c)：订阅上面两组，再加 GPUPH、GPU Throttler Counters、GPU_PPM、Fender 和 Energy Model（GPU Energy），每秒输出一行 CSV。同一行里还有驱动的 `Device Utilization %`（IOKit 直接读）。频率按 `sgx` perf-states 的 13 档加权（338 … 1620 MHz）。读不到的值留空，不写 0。
- 负载：[ut-aggd-stress.swift](ut-aggd-stress.swift) 是 `stress.swift` 加了第二个参数，用来指定线程数的 log2。线程数 2^10、2^12、2^14、2^16、2^18、2^20，内核不变（纯 FMA，持续提交）。2^10 只有一个 1024 线程的线程组，最多占用一两个核心，但 GPU 一直有活，所以忙碌比例和频率都跟满载一样。这正是要找的"忙碌、频率相同，用的核心数不同"。
- 屏幕合成：[ut-aggd-composite.swift](ut-aggd-composite.swift) 开一个 1800×1100 的窗口，里面 60 个半透明、带阴影的 Core Animation 图层每帧移动和旋转。这样只让 WindowServer 合成，没有计算任务。浏览器窗格只能静态显示本地文件，所以没用网页。
- 顺序：[ut-aggd-run.sh](ut-aggd-run.sh)。每种状态先等负载稳定 3 秒，再采 35 秒；汇总时去掉每段前 2 行，每段 33 行。每段结束时各跑一次正式版 `ftop probe --json` 对照（[ut-aggd-probe.csv](ut-aggd-probe.csv)）。
- 数据：[ut-aggd-samples.csv](ut-aggd-samples.csv)（逐秒原始数据）；[ut-aggd-summary.csv](ut-aggd-summary.csv)（每种状态的平均，由 [ut-aggd-summary.py](ut-aggd-summary.py) 生成）。

## 3. 各状态数值

忙碌、频率来自 GPUPH；瓦数来自 Energy Model "GPU Energy"。"介入"指 Count − Not_Engaged；"介入均值" = Sum ÷ 介入次数；"总均值" = Sum ÷ Count。

| 状态 | GPUPH 忙碌 % | 忙碌时平均 MHz | GPU W | 驱动 Device % | Count/s | 介入/s | 介入比例 | 介入均值（centi-%） | 总均值（centi-%） | Sum/s |
|---|---|---|---|---|---|---|---|---|---|---|
| 桌面空闲（两台 5K 照常合成） | 33.6 | 341 | 0.65 | 37 | 1150 | 500 | 0.44 | 8.5 | 3.7 | 4229 |
| 屏幕合成（动画窗口） | 58.8 | 1455 | 12.2 | 50 | 2084 | 921 | 0.44 | **19.3** | 8.5 | 17735 |
| 小负载 2^10 线程 | 98.0 | 1600 | **8.7** | 87 | 3713 | 1193 | 0.32 | 7.7 | 2.5 | 9157 |
| 2^12 | 97.5 | 1593 | 11.2 | 81 | 3676 | 1222 | 0.33 | 9.4 | 3.1 | 11472 |
| 小负载 2^14 线程 | 98.6 | 1604 | 31.7 | 91 | 3745 | 1190 | 0.32 | 7.5 | 2.4 | 8930 |
| 2^16 | 98.0 | 1596 | 62.0 | 93 | 3697 | 1168 | 0.32 | 8.8 | 2.8 | 10240 |
| 2^18 | 99.5 | 1614 | 76.2 | 98 | 3805 | 1062 | 0.28 | 5.3 | 1.5 | 5625 |
| 满载 2^20 线程 | 99.8 | 1617 | **86.1** | 98 | 3824 | 1090 | 0.29 | **4.7** | 1.3 | 5063 |

- 各状态的直方图几乎全落在第 0 格（0–0.5 %），最多到第 4 格（2.0–2.5 %）。
- GPU Throttler Counters（含 `Throttle Counter UT`）在所有状态下增量都是 0。
- 交接文档里的"满载平均约 1.1 centi-%"对应这里的总均值（1.3）。

## 4. 判断

决定性的对比是 2^10 和 2^20：忙碌比例（98.0 和 99.8 %）和频率（1600 和 1617 MHz）几乎一样，GPU 功耗相差 **10 倍**（8.7 W 和 86 W）。如果 UT Engagement 反映核心占用，它应当跟功耗同向变大，实际却是：

- 介入次数（1193 和 1090 次/秒）和介入比例（0.32 和 0.29）基本不变。
- 介入均值（7.7 和 4.7）、Sum/s（9157 和 5063）反而**变小**。
- 只看 2^10–2^20 这六种负载（忙碌和频率都相同）的 210 个 1 秒样本，和 GPU 瓦数的相关系数：介入均值 −0.59，Sum/s −0.63，介入比例 −0.75。方向和"核心占用"正好相反，幅度也不成比例：功耗 10 倍，这几个量的变化都不到 2 倍。
- Count 只跟忙碌时间走（全部样本相关系数 1.00），因为它就是通电期间的采样计时。
- 介入值最高的反而是屏幕合成（19.3），比任何计算负载都高，功耗却只有 12 W。它更像随工作**类型**（图形合成和纯计算）变化，而不是随用了多少 GPU 变化。

所以它不是核心级占用，也不是"每个核心忙多满"，排除。

**它到底是什么，不确定。** 线索都指向节流或限流类的控制环：

- `GPU Throttler Counters` 里有 `Throttle Counter UT`。
- SoC Stats 里有 `UT_EXT_THROTTLE_MGPU03`、`UT_EXT_THROTTLE_MGPU12`、`UT_EXT_THROTTLE_AFR` 等事件。
- 直方图的细分格只覆盖 0–9.5 %，说明设计者预期它通常很小。
- 测量期间所有 UT 节流事件都是 INACT，节流计数都是 0。

"Engagement" 可能是这个环路在每个控制周期里的介入强度，具体机制公开资料里没有。对 ftop 来说，这一点不影响结论。

## 5. 同一份列表里的其他候选

全机 IOReport 通道 11146 个（[ut-aggd-list.c](ut-aggd-list.c)）。名字含 Core、Cluster、Shader、ALU、Occupancy、Active、Engagement、Aggregate 的全部看过，和 GPU 有关的见下表。数据：[ut-aggd-scan-idle.txt](ut-aggd-scan-idle.txt)、[ut-aggd-scan-2e10.txt](ut-aggd-scan-2e10.txt)、[ut-aggd-scan-2e20.txt](ut-aggd-scan-2e20.txt)，由 [ut-aggd-scan.c](ut-aggd-scan.c) 和 [ut-aggd-scan.sh](ut-aggd-scan.sh) 各采 8 秒；[ut-aggd-cs-dpe.csv](ut-aggd-cs-dpe.csv)。

| 通道 | 看到什么 | 结论 |
|---|---|---|
| GPU Stats / Active Time Histogram、Idle Time Histogram | 每段连续忙碌（空闲）的时长分布；满载时忙碌段很长 | 时间维度，和 GPUPH 重复，排除 |
| GPU Stats / Fender State、Fender Active/Idle Time | Fender 几乎一直是 ON，三种状态没有差别 | 排除 |
| GPU Stats / CS Throttler Counters（`CS Throttle Counter DPE`） | 空闲时为 0，有计算负载时涨。按 2^10…2^20 依次为 155M、156M、161M、72M、119M、576M（8 秒），对应功耗 6.7–85 W | 和功耗不单调，排除 |
| GPU Stats / GPU Throttler Counters（含 UT） | 所有状态下都是 0 | 排除 |
| GPU Stats / PWRCTRL | 空闲时是 IDLE_OFF/PERF，有计算负载时大部分时间是 DEADLINE；2^10 和 2^20 一样 | 是控制模式，排除 |
| GPU Stats / AFRSTATE、BSTGPUPH、GPU_CLTM、PZRSDNCY、PMU_RC | 频率或限制档的停留时间；2^10 和 2^20 一样 | 排除 |
| PMP0 / Volt-Temp HM / `AGX_V_T` | 电压-温度格子（例如 1075 mV / 55 °C 和 65 °C） | 可以印证 perf-states 的电压，但不含核心信息，排除 |
| SoC Stats / `MGPU0..3_THROTTLE_*_TRIG`、`UT_EXT_THROTTLE_MGPU03/12`、`VDD_GPU03/12_VOLTAGE_CHANGE_COMPLETION` | 说明 GPU 分成 MGPU0–3 四块、两条电源轨，但只有节流触发和调压完成事件，各块没有自己的活动或供电状态 | 节流触发始终 INACT，排除 |
| AVMR Offset（按档直方图） | 三种状态都没有数据 | 不可用 |
| Energy Model / `GPU Energy`（nJ）、`GPU0`（mJ） | 就是功耗 | 唯一跟核心数同向的量，但它本身就是功耗，不是新的维度 |
| Core Performance Level（MCPU0/1、PCPU） | 是 CPU 的 | 无关 |

**没有任何通道按 GPU 核心、核心簇或 MGPU 分块报告活动或占用。**

## 6. root 下有没有多的

[ut-aggd-root.sh](ut-aggd-root.sh) 用 sudo 跑了一次，结果见 [ut-aggd-root-powermetrics.txt](ut-aggd-root-powermetrics.txt)。

- 用 root 列 IOReport：11147 行，和普通用户**逐行相同**（组、子组、名字、格式的差异 0 行）。root 没有多出通道。
- `powermetrics --samplers gpu_power`：只有 HW active frequency、各频率档的停留比例、SW requested state、idle residency、GPU Power。2^10 时是 98 % 忙碌、1600 MHz、7.4–8.5 W；2^20 时 99.9 % 忙碌、1618 MHz、84 W。没有核心字段。
- `powermetrics -A` 里 GPU 相关的只多一列按进程的 "GPU ms/s"（时间维度，和 `AGXDeviceUserClient` 的 AppUsage 是同一类信息）。

## 7. 对 ftop 的建议

- **不用** UT AggD / UT Engagement：它和"GPU 用了多少"无关，放进公式只会加噪声。核心占用份额没有公式可写。所需的通道普通权限能读，但读到的东西没用。
- 核心数这个维度在本机读不到（普通权限和 root 都一样）。唯一随核心数变化的量是 GPU 功耗本身。用功耗去补核心维度，需要一个"该芯片满载功耗"的参照，相当于按机型查表或校准，这条路用户已经否决了。
- 因此交接文档第 7 节第 5 条"剩余约 2 倍偏差"在不查表的前提下无法用硬件计数器消掉。建议的做法：维持"忙碌 × 频率（或 V²·f）"作为主数，悬停里列出瓦数，让用户自己看到功耗这一维。

## 8. 没做的和局限

- 只测了一种计算内核（纯 FMA）和一种合成负载。图形渲染、显存吃重的任务没测，UT 值可能不同，但 2^10 和 2^20 这组对比已足够排除"核心占用"这个解释。
- UT 的确切含义没查到公开资料，第 4 节的"节流类控制环"是推测。
- 只在 M5 Max（G17X 驱动）上看过，其他芯片的通道名和分格可能不同。
- 编译出的可执行文件都在会话 scratchpad，没有放进仓库。
