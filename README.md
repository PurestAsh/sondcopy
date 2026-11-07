# Sound Copy

**把 Linux 正在播放的声音，实时串流到 iOS 设备上播放。**

[English](README.en.md) · 简体中文

> 本项目由 **opencode + DeepSeek Flash** 全程生成。

---

## 简介

Sound Copy 是一个极简的跨设备音频串流方案：

- **服务端**（`sound-copy-server`）运行在 Linux **Wayland** 桌面上，捕获系统音频输出（PipeWire/WirePlumber 回环），编码后通过 UDP 实时发送。
- **客户端**（`sound-copy-ios`）运行在 iOS 17+ 设备上，通过 UDP 接收音频，解码后由 `AVAudioEngine` 播放，支持**后台播放与锁屏播放**。

典型场景：

- 把 Linux 主机的音乐 / 会议 / 视频声音无线转到手机或蓝牙耳机；
- 局域网内低延迟直连，不经过任何云服务；
- 让多台 iOS 设备共享同一路系统声音。

```
┌──────────────────────────────┐          UDP :9000           ┌──────────────────────────────┐
│  Linux (Wayland)             │   interleaved f32 LE         │  iOS 17+                     │
│  ┌─────────────────────────┐ │ ───────────────────────────► │  ┌─────────────────────────┐ │
│  │ sound-copy-server (Rust)│ │   48 kHz · stereo · 20 ms    │  │ sound-copy-ios (SwiftUI)│ │
│  │ gpui-kit + flexaudio    │ │                              │  │ UDPReceiver             │ │
│  │ SystemLoopback 采集      │ │                              │  │ AVAudioEngine 播放      │ │
│  └─────────────────────────┘ │                              │  └─────────────────────────┘ │
└──────────────────────────────┘                              └──────────────────────────────┘
```

---

## 特性

- 🎧 **系统声音采集**：通过 `flexaudio` 的 `SystemLoopback` 捕获 Wayland 会话下的系统音频输出。
- 📱 **iOS 后台播放**：切换到后台或锁屏后仍可继续收听；来电、路由变化后自动恢复。
- ⚡ **低延迟直连**：局域网内点对点 UDP 传输，无中转服务器。
- 🖥️ **图形化服务端**：基于 `gpui-kit` 的暗色小窗口，填写目标地址、一键开始/结束采集。
- 🧰 **无需 Xcode**：iOS 端使用 [xtool](https://xtool.dev) 构建。
- 🔍 **内置诊断**：客户端实时显示收包数、字节数、数据峰值、音频引擎与输出路由状态，并提供 440 Hz 测试音。
- 🤖 **全程 AI 生成**：由 opencode + DeepSeek Flash 生成。

---

## 工作原理

### 音频链路

1. Linux 端以 **48 kHz、立体声** 打开系统回环音频流，持续读取交错（interleaved）的 `f32` 采样。
2. 每个采样按 **小端 float32** 序列化，直接作为 UDP 数据报发送到 `iOS 设备 IP:9000`。
3. iOS 端监听 `0.0.0.0:9000`，把每 8 字节解析为一组 `(左声道, 右声道)`，写入环形缓冲。
4. `AVAudioEngine` 的 `AVAudioSourceNode` 按声卡时钟从环形缓冲取数据播放；缓冲欠载时自动补静音。

发送节奏约为每 **20 ms** 一包，即 **960 帧 = 7680 字节**。客户端对包长是宽松的，只要长度是 8 的倍数即可解析。

### 传输协议

| 项目 | 说明 |
| --- | --- |
| 传输层 | UDP |
| 端口 | `9000`（固定） |
| 音频格式 | 交错立体声，32-bit 小端浮点（`f32 LE`） |
| 采样率 | 48 kHz（客户端音频引擎固定为 48 kHz） |
| 每帧 | 8 字节 = L (4B) + R (4B) |
| 典型包长 | 7680 字节（960 帧 / 20 ms） |
| 包头 | 无 |
| 加密 | 无（仅建议在可信局域网内使用） |

> 协议刻意保持简单：没有握手、序号、重传和抖动缓冲协商。网络丢包会直接表现为音频缺口，丢包严重时建议改用有线网络或 5 GHz Wi-Fi。

---

## 项目结构

```
soundcp/
├── README.md                 # 中文说明（本文件）
├── README.en.md              # English README
├── sound-copy-server/        # Linux 服务端（Rust）
│   ├── Cargo.toml
│   └── src/main.rs           # GUI、系统音频采集、UDP 发送
└── sound-copy-ios/           # iOS 客户端（SwiftUI + xtool）
    ├── Package.swift
    ├── xtool.yml             # bundle ID 等 xtool 配置
    ├── Info.plist            # 后台音频、本地网络权限等
    └── Sources/apple_hello/
        ├── apple_helloApp.swift
        ├── ContentView.swift # 界面、AudioPlayer、环形缓冲
        └── UDPReceiver.swift # UDP 监听与解析
```

---

## 环境要求

### 服务端（Linux）

- Linux 桌面，**Wayland** 会话（X11 未验证）
- PipeWire / WirePlumber 正在运行，且能够采集系统回环音频
- Rust **1.85+**（项目使用 `edition = "2024"`）
- 构建依赖：`pkg-config` 以及 PipeWire 开发库（`libpipewire-0.3-dev` / `libspa` 等）

  Debian / Ubuntu 示例：

  ```bash
  sudo apt install pkg-config libpipewire-0.3-dev libspa-0.2-dev
  ```

  Fedora 示例：

  ```bash
  sudo dnf install pkgconf-pkg-config pipewire-devel
  ```

### 客户端（iOS）

- iOS / iPadOS **17.0+**
- [xtool](https://xtool.dev)（跨平台 Xcode 替代工具链）
- 用于安装到真机的 Apple 开发者签名（免费账号即可）
- Linux 与 iOS 设备处于**同一局域网**

---

## 快速开始

### 1. 启动 iOS 客户端

先确认设备 IP（设置 → 无线局域网 → 当前网络详情）。

```bash
cd sound-copy-ios
xtool dev          # 构建、安装并在设备上运行
```

仅构建不运行：

```bash
xtool dev build
```

首次启动时：

- 允许 **本地网络** 访问（否则收不到任何数据）；
- 点击 **开始接收**，客户端开始监听 `0.0.0.0:9000` 并启动音频引擎；
- 可先点 **测试声音（440Hz）** 验证扬声器/耳机播放链路是否正常。

> `xtool.yml` 中的 `bundleID` 与 `Info.plist` 中的 `CFBundleIdentifier` 目前是占位值 `com.example.apple-hello`，安装到真机前请改成你自己的唯一标识。

### 2. 启动 Linux 服务端

```bash
cd sound-copy-server
cargo run --release
```

窗口出现后：

1. 在输入框中填写 iOS 设备的地址，例如 `192.168.1.23:9000`（默认值 `192.168.31.103:9000` 只是示例，请务必修改）；
2. 点击 **开始采集**；
3. 终端会每秒输出一次发送统计，例如：

   ```text
   已发送 1520 包，每包 7680 字节，采集峰值 0.7321
   ```

   峰值长期为 `0.0000` 通常表示系统没有声音输出，或回环源没有选对。

3. 在 iOS 端点击 **停止接收**（或服务端点击 **结束采集**）即可停止。

---

## 使用技巧

- **后台播放**：iOS 客户端已声明 `UIBackgroundModes: audio`，锁屏或切换 App 后音频应继续播放。
- **自动恢复**：来电、拔耳机、蓝牙断开、输出设备采样率变化后，客户端会尝试重建/重启音频引擎；切回前台时也会检查一次。
- **延迟与卡顿**：客户端缓冲约 0.5 秒。若网络抖动大，可减少同时占用带宽的设备，优先使用 5 GHz Wi-Fi。
- **多设备收听**：多个 iOS 设备监听不同地址时，服务端需要分别发送；当前实现一次只向一个目标地址发送。

---

## 故障排查

| 现象 | 可能原因与处理 |
| --- | --- |
| iOS 端收包数一直为 0 | 未授予本地网络权限；设备不同网段；服务端填错 IP；Linux 防火墙拦截 UDP 9000。可临时 `sudo ufw allow 9000/udp` 验证。 |
| 有收包但无声音 | 先点“测试声音（440Hz）”。测试音正常则问题在数据/音量；无测试音则检查静音开关、音量、输出路由。 |
| 终端提示“打开系统回环音频失败” | 当前不是 Wayland 会话，或 PipeWire 未运行 / 缺少回环设备。确认 `echo $XDG_SESSION_TYPE` 输出 `wayland`，并检查 `wpctl status`。 |
| 终端提示“启动音频采集失败” | 系统音频服务未就绪，或没有可用的默认输出设备。 |
| 服务端发送报 `EINVAL` | 发送 socket 必须绑定 `0.0.0.0`（代码已处理）。若自行修改，请勿绑定 `127.0.0.1`。 |
| 音频断续、爆音 | 无线网络丢包或抖动。靠近路由器、改用 5 GHz / 有线网络，关闭大流量下载。 |
| iOS 后台不久后停止 | 确认系统未开启低电量模式；某些机型/系统版本对后台网络与音频限制更严格。 |
| 构建服务端失败（找不到 pipewire） | 安装 PipeWire 开发库，确保 `pkg-config --modversion libpipewire-0.3` 可用。 |

---

## 已知限制

- 仅支持 **Wayland**，不支持 X11（系统音频采集依赖 Wayland/PipeWire 环境）。
- 无认证与加密，**请勿暴露到公网**。
- 无重传与前向纠错，丢包即静音缺口。
- 单目标地址发送；暂不支持服务发现、多播或一对多。
- iOS 端采样率固定为 48 kHz，若系统回环输出为其他采样率，需要在服务端重采样（当前未实现）。
- iOS 工程仍使用 `apple_hello` 作为 target/模块名，属于脚手架遗留命名。

---

## 参与贡献

欢迎提交 Issue 与 Pull Request。建议在改动音频协议时同步更新本文档的「传输协议」一节，并保持服务端与客户端兼容。

---

## 说明

本项目由 **opencode + DeepSeek Flash** 生成，主要用于学习与局域网内自用。使用前请自行评估网络环境与安全风险。
