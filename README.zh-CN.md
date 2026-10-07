<p align="center"><img src="docs/media/icon.png" width="112" alt="ftop 图标：一只闭着眼的雪鸮"></p>
<h1 align="center">ftop</h1>
<p align="center">给 Apple Silicon Mac 用的一个小而安静的系统监视器。<br>一块浮动的玻璃面板，任何尺寸都能用。</p>
<p align="center"><a href="README.md">English</a></p>

![同一块面板的六种尺寸](docs/media/sizes.png)

## 它是做什么的

ftop 用来替代你常年开在终端标签页里的监视工具（btop、htop），换成一个可以放在桌面任何
位置的原生窗口。它为机器正在使劲干活的时刻而做：本地模型在跑、AI 代理在编译、一次很长
的构建。这时你想一眼看清各个核心、内存和网络的状态，以及是哪个进程在占用。

- **每个核心单独显示。** 性能核和能效核分成两组柱子。柱子高度是占用，柱上的小横线是
  该核心当前的频率。
- **芯片温度**，并标明它实际来自哪一级传感器。
- **内存**：已用、总量、压缩、交换，以及系统自己给出的内存压力。
- **网络**：当前的下载和上传速度。
- **进程**：按 CPU 排序的最忙进程；窗口够大时再加一列按内存排序的。
- **任意窗口尺寸。** 拖动任何一条边，ftop 选出合适的布局，并让窗口贴合它，所以内容
  不会被裁掉，也不会留空白。
- **不看的时候几乎不花资源。** 隐藏或被完全遮住时，除了菜单栏上那一个数字，其他读数
  全部停止。

它只显示当前状态：没有历史曲线，没有磁盘面板。

## 一块面板，各种尺寸

小窗口只留要点；大窗口显示更多内容，而不是把字放大：每个核心的数字、最多 24 行进程、
再加一列按内存排序的进程。

![大窗口](docs/media/large.png)

这些图片由 ftop 自己的绘制代码配合示例数据生成（`scripts/readme-media.sh`），放在一张
替代的壁纸上。真实窗口用的是 macOS 的玻璃材质，背景会随它后面的内容变化。

## 资源占用

用 `scripts/perf.sh` 在一台 14 核 Apple Silicon Mac 上测得，每秒刷新一次：

| 状态 | CPU | 内存 |
| --- | --- | --- |
| 小面板（300 × 420） | 约占一个核心的 1.0% | 22–38 MB |
| 大面板（约 1050 × 500） | 1.2–1.5% | 同上 |
| 隐藏或被完全遮住 | 0.0–0.1% | 同上 |

## 安装

要求：Apple Silicon Mac，macOS 15 或更新。

**用发布包。** 在[发布页](https://github.com/Nongfsq/ftop/releases/latest)下载
`Ftop-<版本>-arm64.zip`，解压后把 `Ftop.app` 移到 `~/Applications`。然后把命令链接到
`PATH` 里的某个目录：

```bash
mkdir -p ~/.local/bin && ln -sfn ~/Applications/Ftop.app/Contents/MacOS/ftop ~/.local/bin/ftop
```

这个应用只做了本机签名，没有经过苹果公证，所以用浏览器下载的副本会被 macOS 拦住。
清除一次下载标记即可：

```bash
xattr -dr com.apple.quarantine ~/Applications/Ftop.app
```

**从源码构建。** 需要 Xcode（用 Xcode 27 构建和测试）。

```bash
git clone https://github.com/Nongfsq/ftop.git
```

```bash
cd ftop && scripts/bundle.sh && scripts/install.sh
```

这会把 `Ftop.app` 放进 `~/Applications`，并把 `ftop` 链接到 `~/.local/bin`。

## 使用

```bash
ftop            # 打开面板
ftop toggle     # 隐藏或显示
ftop quit       # 关闭
ftop doctor     # 这台 Mac 上哪些读数可用，不可用的原因是什么
```

- 拖动面板可以移动它；拖动边缘可以改变大小。
- 把指针移到面板顶部会出现两个按钮：置顶和隐藏。
- 菜单栏显示 `CPU 19%`，点一下可以显示或隐藏面板。
- 指针停在某个核心、内存条或进程上，会显示详细信息。
- 在面板或菜单栏项目上点右键，可以换配色和打开**设置…**。

<img src="docs/media/settings.png" width="290" alt="设置窗口">

设置同时也是一个纯文本文件 `~/.config/ftop/config.json5`（可以写注释的 JSON）。设置
窗口和这个文件保持一致，保存后立即生效。

### 系统进程

没有额外权限时，macOS 只让 ftop 看到你自己的进程。要把 `WindowServer` 这类系统进程也
列出来，授权一次即可：

```bash
sudo ftop grant
```

这会把应用里的一个小辅助程序标记为以 root 身份运行。它不接受参数，不读环境变量，不写
文件，只输出进程表；源码在 `Sources/ftop-helper/main.swift`。

## 限制

- 只支持 Apple Silicon。核心分组和每核频率依赖它。
- 每核频率和温度来自 macOS 的私有接口（IOReport 和 HID 传感器服务），可能随系统更新
  而变化；读不到的数值会显示为不可用，绝不显示成零。也因为这一点，ftop 不能上架
  Mac App Store。
- 界面有英文和中文。

## 开发

`scripts/check.sh` 是提交前的检查：格式、无警告构建、测试。产品决定在
[docs/product/](docs/product/)，架构在 [docs/architecture/](docs/architecture/)，
给编码代理的规则在 [AGENTS.md](AGENTS.md)。

ftop 最初是 [btop](https://github.com/aristocratos/btop) 的一个分支，之后从头重写，
与它不共享任何代码。

## 许可证

[MIT](LICENSE)
