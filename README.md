# Linux2iOS Audio Stream

把 Linux（Wayland）系统正在播放的声音，实时串流到 iOS 设备上播放。

> 本项目由 **opencode + DeepSeek Flash** 全程生成。

---

## 简介

Linux2iOS Audio Stream 是一个跨设备音频串流方案：

- **服务端**运行在 Linux（仅支持 **Wayland** 会话），捕获系统音频输出，编码后通过网络实时发送。
- **客户端**运行在 iOS，接收并解码音频，支持**后台播放**，实现“Linux 出声、iPhone/iPad 收听”。

典型场景：把 Linux 主机的音乐/会议/视频音频无线转到手机或耳机上听；局域网内低延迟直连；多设备共享同一路系统声音。

---

## 特性

- 🎧 **系统声音采集**：捕获 Wayland 会话下的系统音频输出
- 📱 **iOS 后台播放**：切到后台、锁屏仍可继续收听
- ⚡ **低延迟串流**：适合音乐、会议、视频伴音等场景
- 🔒 **局域网直连**：默认在本地网络内点对点传输
- 🦀 **Rust 服务端**：基于 `gpui-kit` 构建
- 🧰 **xtool 客户端**：iOS 端使用 xtool 工具链构建
- 🤖 **全程 AI 生成**：由 opencode + DeepSeek Flash 生成

---
