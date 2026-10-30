# GPU 占用率：交接（2026-10-31）

目的：把目前的观察、测量、讨论和候选方案交给下一位讨论者，判断有没有比"电压² × 频率"更好的解法。
作者已同意由我们开分支实现、提 PR；方案还没有定，代码一行没改。

## 1. 背景

- 用户感觉 ftop 的 GPU 占用率偏高，在旧电脑上就有，换了新 Mac Studio 后仍然如此。作者建议跑 `ftop doctor`。
- 所有测量都用**正式版 0.2.7**（`~/Applications/Ftop.app`，Developer ID 签名、已公证、附有公证凭证；GitHub v0.2.7 于 2026-10-21 05:15 UTC 发布，签名时间 00:15 UTC；本机没有任何签名证书）。没有用到 `build/` 里的开发版（0.2.6，临时签名）。
- 机器：Mac17,14，Apple M5 Max，GPU 40 核（驱动配置 `num_gps` = 16），GPU 频率 13 档 338–1620 MHz。
- 显示器：两台 5K，分别 240 Hz 和 144 Hz（按 2560×1440 的界面尺寸显示）。屏幕合成负担很重，这是现象特别明显的原因之一。

## 2. ftop 现在怎么算

- 占用率 = 显卡驱动 `IOAccelerator` 的 `PerformanceStatistics` → `"Device Utilization %"`，只除以 100、超过 100 按 100 算，没有别的处理。
  - 读取：[CFtopSys.c:1008](../../../Sources/CFtopSys/CFtopSys.c)（第 1017 行取值）
  - 使用：[Providers.swift:265, 292](../../../Sources/FtopSensors/Providers.swift)
- 频率 = IOReport "GPU Stats" / "GPU Performance States" / 通道 `GPUPH` 的各频率档停留时间，按 `sgx` 节点 `perf-states` 表里的频率加权（[CFtopSys.c:782, 832](../../../Sources/CFtopSys/CFtopSys.c)）。
- 功耗 = IOReport "Energy Model" / "GPU Energy"。温度 = SMC 所有 `Tg*` 键。显存 = `"In use system memory"`。
- 设计依据：[blueprint 修订 "GPU and power readings"](../../architecture/2026-10-06-ftop-blueprint.md)（约第 434 行）。界面：[decision 修订 "the GPU has a column of its own"](../../product/2026-10-06-floating-panel-decision.md)（第 452 行起），规定"柱子高度是 usage，线是频率"。

## 3. 观察和测量

### 3.1 连续观察（约 34 小时）
- 2026-10-28 13:32 到 10-29 23:37，每 30 秒一条，共 2674 条。睡眠造成约 12 小时空白。
- 脚本：[sample.py](sample.py)；数据：[samples.csv](samples.csv)。
- 每条记录：驱动的 Device/Renderer/Tiler %、硬件忙碌比例（由 `ftop doctor --states` 输出的 GPUPH 停留时间算出）、忙碌时的平均频率、按频率折算的负载、正式版 `ftop probe --json` 的 usage/频率/GPU 瓦数/整机瓦数、用户空闲秒数、前台应用。
- 注意：ftop 的读数来自每次新启动的 `ftop probe`，**不是**一直运行着的面板。
- 注意：只存了平均频率，没有存逐档停留时间。

### 3.2 满载测试（30 秒）
- 程序：[stress.swift](stress.swift)（Metal 计算任务，纯 FMA 运算，2^20 个线程，持续提交）；采样：[sample_fast.py](sample_fast.py)；数据：[full-load.csv](full-load.csv)。
- 满载：忙碌 99.9%，1619 MHz，ftop 显示 98–100%，**GPU 约 82.5 W**，整机约 105 W。停止后 2 秒内降回 1 W 以下。
- 只测了一种任务类型。图形或显存吃重的任务，满载功耗可能不同。

### 3.3 关键数字
以 82.5 W 为满载，"实际功耗占比" = GPU 瓦数 ÷ 82.5。

| 场景（按忙碌时的频率分组） | 条数 | 驱动 % | 按频率折算 | 电压²×频率（近似） | 实际功耗占比 |
|---|---|---|---|---|---|
| 低频 <500 MHz | 1205 | 20 | 2.3 | 0.8 | 0.2 |
| 中频 500–1100 | 176 | 45 | 27.1 | 13.5 | 6.0 |
| 高频 ≥1100 | 376 | 35 | 30.8 | 20.3 | 11.3 |
| 满载 | — | ~100 | ~100 | 100 | 100 |

和 GPU 功耗的相关系数（1757 条，忙碌 >0）：驱动 % 0.57，硬件忙碌比例 0.75，按频率折算 0.95，电压²×频率 0.97。
"电压²×频率"这一列是**用平均频率近似**算的，不是逐档算的。

### 3.4 驱动偶尔报假的 0
- 长期观察中，`ftop probe` 有 117 次报 0%，而驱动和硬件都显示至少 10% 在忙；其中 51 次是前后都正常、中间单独掉成 0。同一时期直接用 `ioreg` 读驱动，同样的情况只有 9 次。
- 满载测试前后，直接读驱动在空闲阶段 25 次里有 7 次是 0（3 个字段同时为 0），同时硬件显示 43–46% 在忙。
- 结论：0 来自驱动这个字段本身，什么时候读到它取决于读取时机；ftop 把它原样显示了出来。GPUPH 停留时间在这两天从没出现过这种假的 0。
- 面板（一直运行的那个进程）是否同样会闪 0，没有直接验证。

### 3.5 一次真实负载
- 10-28 15:00–17:50 锁屏（前台是 `loginwindow`），GPU 约 1270 MHz、约 9.5 W，ftop 显示约 36%。这段时间 GPU 确实在干活，不是 bug。不知道是哪个程序（当天开过 MuMu 安卓模拟器）。

## 4. 已经得出的判断

- 驱动的 % 是"忙碌时间比例"，和硬件 GPUPH 统计的忙碌时间基本一致，所以不是读错了。但它不管频率、不管用了多少核心、不管功耗：0.2 W 也能显示 20%。
- 业界也普遍用"忙碌时间"：NVIDIA `nvidia-smi` 的 GPU-Util、AMD `gpu_busy_percent`、Windows 任务管理器按引擎统计的运行时间。区别在于那些工具会把频率和功耗放在旁边，而且独立显卡空闲时很快就做完工作。苹果 GPU 在 338 MHz 上慢慢合成两台高刷 5K 屏，所以忙碌比例被拉高。
- CPU 占用在各平台也都按忙碌时间算（Windows 任务管理器从 Win8 起改用了考虑频率的算法）。
- 用户否决了**查表或校准**（按机型记录满载功耗）：机型太多，新芯片还要继续加，不优雅。

## 5. 能拿到什么（普通权限，本机已验证）

ftop 没用到的：
- `sgx` 的 `perf-states`：每档是一对 (频率 Hz, 电压 mV)，例如 338 MHz/645 mV …… 1620 MHz/1075 mV。13 档电压依次是 645 655 675 730 740 780 805 830 880 905 960 1040 1075。
- `perf-state-table-count` = 4：一共有 4 套表，频率相同，电压略有不同（例如第一档有 0x285=645 和 0x276=630 两种）。芯片实际用哪一套，**不知道**。
- 每个程序的 GPU 时间：`AGXDeviceUserClient` → `AppUsage` → `accumulatedGPUTime`、`lastSubmittedTime`，以及 `IOUserClientCreator`（pid 和名字）。本机有 104 个。单位和语义还没核实。
- 驱动其他字段：Renderer / Tiler Utilization %、Alloc system memory（约 7 GB，正在使用约 2.6 GB）、recoveryCount（GPU 重启次数）、TiledSceneBytes、SplitSceneCount。
- IOReport 里和 GPU 相关的 263 个通道：BSTGPUPH（加速控制的频率档）、`GPU_PPM`（电源管理给 GPU 设的功率目标占最高功率的百分比，本机一直在 80–89%）、CLTM-induced GPU Performance States（因温度降频）、GPU / CS Throttler Counters、Power Controller States、Context Switch Latencies、UMA 内存池、"GPU UT AggD Stats"（按频率档分的 UT Engagement 的 Sum/Count/Min/Max；满载时平均约 1.1 centi-%，含义不明，看起来不是核心占用）。
- 列通道的工具：[ior.c](ior.c)（列出名字含 GPU/AGX/GFX 的 IOReport 通道和 1 秒内的变化；编译：`clang -o ior ior.c -framework CoreFoundation -lIOReport`）。

拿不到的：
- 用了多少个核心、核心占得多满：普通权限的计数器里没有。管理员权限估计也没有（`powermetrics` 的 GPU 部分只有忙碌比例、频率和功耗），但**没用 sudo 实测过**。Metal 计数器和 Instruments 只能看自己的程序，或者做一次专门的录制。
- CPU 功耗：普通权限下读数为 0，ftop 的设计里明确不显示。

## 6. 当前候选方案

**负载 = Σ（各档忙碌时间 × 该档 V²·f）÷（总时间 × 最高档 V²·f）**
- 依据：动态功耗 ≈ C·V²·f。数据全部来自芯片自己（GPUPH + `perf-states`），不用查表，不用校准，新芯片自动适用。
- 逐级退回：读不到电压 → 按频率折算；读不到 GPUPH → 驱动 %。doctor 里注明当前用的是哪一种（和"温度要注明传感器级别"同一个规则）。
- 悬停里列原始数据：`负载 x% · 忙碌 y% · MHz · W`。
- 数值仍是 0–100%，面板尺寸不变。
- 第二步（单独一个 PR）：用每个程序的 GPU 时间显示"谁在用 GPU"。

## 7. 这个方案还存在的问题

1. **丢掉"GPU 已经到极限"的信号**：GPU 因温度或电源被压在中频、100% 在忙时，负载只显示中等数值。无风扇机型最容易遇到。缓解办法：悬停保留忙碌 %；也可以用 CLTM 和降频计数器判断是否被降频。具体怎么显示，没有定。
2. **改了指标含义**：要在 `docs/product/` 补一条设计修订；和活动监视器、`nvidia-smi` 对不上；菜单栏的 GPU 读数含义也会跟着变；名字用 "usage" 还是 "load" 没有定。
3. **4 套电压表**：用哪一套不知道，估计误差在 5% 以内，要写明这个假设。
4. **验证不够**：只在 M5 Max 上解析过；M1–M4 和 M6 的格式没确认；issue 8 里 M6 有 P14、P15 两档超出表的长度。0.97 是用平均频率近似算的；严格验证需要重新采逐档数据。
5. **剩余偏差约 2 倍**：中高负载时仍比实际功耗占比高（20% 对 11%），原因是没有核心数信息。
6. **悬停内容变了，要按布局变更来做**：重新生成参考图片并检查，还要把真实面板拖成小、窄、大几种尺寸看一遍。

## 8. 想请讨论的问题

1. 有没有不用查表、又能保留"已到极限"信号的指标或显示方式？比如负载和忙碌两个都显示、用形状区分，或者让柱子高度和数字表示不同的东西。
2. 有没有本机可读、更直接的数据可以替代 V²·f？比如 `GPU_PPM`、BSTGPUPH，或者用 GPU 能耗除以某个可以从芯片本身推出来的上限。
3. 剩下约 2 倍的偏差，在不知道核心数的情况下还能不能再缩小？
4. 主数字应该回答哪个问题："GPU 做了多少功"，还是"GPU 还有没有余量"？
5. 4 套电压表该用哪一套，能不能在运行时判断出来？

## 9. 约束（来自 AGENTS.md 和设计决定）

- 只有 `FtopSensors` 和 `CFtopSys` 能调用系统接口，私有符号只在 `CFtopSys` 里声明；`FtopUI` 不能引用 `FtopSensors`。
- 颜色、字号、间距只写在 `Theme.swift`。面板不是 SwiftUI，由 `Scene` 加 Core Animation 画。
- 面板尺寸不能随读数变：按一个字段可能出现的最宽数值来排版。
- 读不到的值显示为"不可用"，不能显示成 0。
- 只显示当前状态，不画历史曲线；界面文字尽量少，细节放在悬停里。
- 新分支从 `main` 开（`main` 在 a318876；当前所在分支 `feat/resize-cursors-and-menubar-trio` 是另一件事）。
- 完成前要跑 `scripts/check.sh`；提交和推送要用户同意。
