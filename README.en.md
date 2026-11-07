# Sound Copy

**Stream the audio playing on Linux to your iOS device in real time.**

English · [简体中文](README.md)

> This project was generated end-to-end by **opencode + DeepSeek Flash**.

---

## Overview

Sound Copy is a minimal cross-device audio streaming setup:

- **Server** (`sound-copy-server`) runs on a Linux **Wayland** desktop, captures the system audio output (PipeWire/WirePlumber loopback), encodes it, and sends it over UDP in real time.
- **Client** (`sound-copy-ios`) runs on iOS 17+ and receives the stream over UDP, decoding it for playback through `AVAudioEngine`, with **background and lock-screen playback** support.

Typical use cases:

- Send music, meetings, or video audio from a Linux machine to a phone or Bluetooth headphones;
- Low-latency, direct connection on the local network with no cloud service in between;
- Let multiple iOS devices listen to the same system audio.

```
┌──────────────────────────────┐          UDP :9000           ┌──────────────────────────────┐
│  Linux (Wayland)              │   interleaved f32 LE         │  iOS 17+                      │
│  ┌─────────────────────────┐  │ ───────────────────────────► │  ┌─────────────────────────┐  │
│  │ sound-copy-server (Rust)│  │   48 kHz · stereo · 20 ms    │  │ sound-copy-ios (SwiftUI)│  │
│  │ gpui-kit + flexaudio    │  │                              │  │ UDPReceiver             │  │
│  │ SystemLoopback capture  │  │                              │  │ AVAudioEngine playback  │  │
│  └─────────────────────────┘  │                              │  └─────────────────────────┘  │
└──────────────────────────────┘                              └──────────────────────────────┘
```

---

## Features

- 🎧 **System audio capture**: captures the Wayland session's audio output through `flexaudio`'s `SystemLoopback` source.
- 📱 **iOS background playback**: keeps playing when the app is backgrounded or the screen is locked, and recovers automatically after calls or route changes.
- ⚡ **Low-latency direct link**: peer-to-peer UDP on the local network, no relay server.
- 🖥️ **Graphical server**: a small dark-themed `gpui-kit` window where you enter the target address and start/stop capture with one click.
- 🧰 **No Xcode required**: the iOS app is built with [xtool](https://xtool.dev).
- 🔍 **Built-in diagnostics**: the client shows packet count, byte count, data peak, audio engine status, and output route, plus a 440 Hz test tone.
- 🤖 **AI-generated**: created by opencode + DeepSeek Flash.

---

## How It Works

### Audio pipeline

1. On Linux, the system loopback stream is opened as **48 kHz stereo** audio and interleaved `f32` samples are read continuously.
2. Each sample is serialized as a **little-endian float32** and sent directly as a UDP datagram to `iOS device IP:9000`.
3. The iOS client listens on `0.0.0.0:9000`, parses every 8 bytes as one `(left, right)` sample pair, and writes it into a ring buffer.
4. An `AVAudioSourceNode` in `AVAudioEngine` pulls data from the ring buffer on the audio clock; underruns are filled with silence.

Packets are sent roughly every **20 ms**, i.e. **960 frames = 7680 bytes**. The client is lenient about packet size and accepts any payload whose length is a multiple of 8.

### Wire protocol

| Item | Description |
| --- | --- |
| Transport | UDP |
| Port | `9000` (fixed) |
| Audio format | Interleaved stereo, 32-bit little-endian float (`f32 LE`) |
| Sample rate | 48 kHz (the client's audio engine is fixed at 48 kHz) |
| Per frame | 8 bytes = L (4 B) + R (4 B) |
| Typical packet | 7680 bytes (960 frames / 20 ms) |
| Header | None |
| Encryption | None (use only on a trusted LAN) |

> The protocol is intentionally simple: no handshake, sequence numbers, retransmission, or jitter-buffer negotiation. Packet loss shows up directly as audio gaps; if loss is significant, prefer a wired network or 5 GHz Wi-Fi.

---

## Project Layout

```
soundcp/
├── README.md                 # Chinese README
├── README.en.md              # English README (this file)
├── sound-copy-server/        # Linux server (Rust)
│   ├── Cargo.toml
│   └── src/main.rs           # GUI, system audio capture, UDP sending
└── sound-copy-ios/           # iOS client (SwiftUI + xtool)
    ├── Package.swift
    ├── xtool.yml             # xtool configuration (bundle ID, etc.)
    ├── Info.plist            # Background audio, local network permission, etc.
    └── Sources/apple_hello/
        ├── apple_helloApp.swift
        ├── ContentView.swift # UI, AudioPlayer, ring buffer
        └── UDPReceiver.swift # UDP listener and parser
```

---

## Requirements

### Server (Linux)

- Linux desktop with a **Wayland** session (X11 is not tested)
- PipeWire / WirePlumber running, with system loopback capture available
- Rust **1.85+** (the project uses `edition = "2024"`)
- Build dependencies: `pkg-config` and PipeWire development libraries (`libpipewire-0.3-dev` / `libspa`, etc.)

  Debian / Ubuntu:

  ```bash
  sudo apt install pkg-config libpipewire-0.3-dev libspa-0.2-dev
  ```

  Fedora:

  ```bash
  sudo dnf install pkgconf-pkg-config pipewire-devel
  ```

### Client (iOS)

- iOS / iPadOS **17.0+**
- [xtool](https://xtool.dev) (cross-platform Xcode replacement toolchain)
- Apple developer signing for on-device installation (a free account is enough)
- The Linux host and the iOS device must be on the **same LAN**

---

## Quick Start

### 1. Start the iOS client

First, find the device's IP address (Settings → Wi-Fi → details of the current network).

```bash
cd sound-copy-ios
xtool dev          # build, install, and run on the device
```

Build only:

```bash
xtool dev build
```

On first launch:

- Allow **Local Network** access (otherwise no data will arrive);
- Tap **开始接收** (Start Receiving); the client starts listening on `0.0.0.0:9000` and starts the audio engine;
- Optionally tap **测试声音（440Hz）** (Test Tone) to verify the speaker/headphone playback path.

> The current UI and terminal output are in Chinese; the English labels above are translations for reference.

> The `bundleID` in `xtool.yml` and `CFBundleIdentifier` in `Info.plist` are currently placeholders (`com.example.apple-hello`). Change them to your own unique identifier before installing on a real device.

### 2. Start the Linux server

```bash
cd sound-copy-server
cargo run --release
```

Once the window appears:

1. Enter the iOS device's address, e.g. `192.168.1.23:9000` (the default `192.168.31.103:9000` is just an example — be sure to change it);
2. Click **开始采集** (Start Capture);
3. The terminal prints a send report every second, for example:

   ```text
   已发送 1520 包，每包 7680 字节，采集峰值 0.7321
   ```

   A peak that stays at `0.0000` usually means the system is not producing audio, or the wrong loopback source was captured.

4. To stop, tap **停止接收** (Stop Receiving) on iOS, or click **结束采集** (Stop Capture) on the server.

---

## Tips

- **Background playback**: the iOS client declares `UIBackgroundModes: audio`, so audio should continue after locking the screen or switching apps.
- **Automatic recovery**: after an interruption, unplugging headphones, a Bluetooth disconnect, or an output sample-rate change, the client tries to rebuild/restart the audio engine; it also checks when returning to the foreground.
- **Latency and stutter**: the client buffers about 0.5 seconds. If the network is jittery, reduce competing traffic and prefer 5 GHz Wi-Fi.
- **Multiple listeners**: multiple iOS devices would each need their own stream; the current implementation sends to a single target address at a time.

---

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| Packet count stays at 0 on iOS | Local Network permission not granted; devices on different subnets; wrong IP entered on the server; Linux firewall blocking UDP 9000. Try `sudo ufw allow 9000/udp` to verify. |
| Packets arrive but no sound | Tap **测试声音（440Hz）** (Test Tone) first. If the test tone works, the issue is in the stream/volume path; if not, check mute, volume, and output route. |
| "Failed to open system loopback audio" | Not on a Wayland session, or PipeWire is not running / no loopback device. Check `echo $XDG_SESSION_TYPE` outputs `wayland` and inspect `wpctl status`. |
| "Failed to start audio capture" | The system audio service is not ready, or there is no usable default output device. |
| Server reports `EINVAL` when sending | The sending socket must bind to `0.0.0.0` (the code already does this). Do not bind it to `127.0.0.1` if you modify the code. |
| Choppy audio or crackling | Wireless packet loss/jitter. Move closer to the AP, use 5 GHz or wired networking, and stop large downloads. |
| Playback stops soon after backgrounding | Check whether Low Power Mode is enabled; some devices/OS versions are stricter about background networking and audio. |
| Server build fails (PipeWire not found) | Install the PipeWire development libraries and make sure `pkg-config --modversion libpipewire-0.3` works. |

---

## Known Limitations

- **Wayland only**; X11 is not supported (system audio capture depends on the Wayland/PipeWire environment).
- No authentication or encryption — **do not expose it to the public internet**.
- No retransmission or forward error correction; packet loss becomes silent gaps.
- Single target address; no service discovery, multicast, or one-to-many streaming.
- The iOS client's sample rate is fixed at 48 kHz. If the system loopback runs at another rate, resampling on the server would be required (not implemented yet).
- The iOS project still uses `apple_hello` as its target/module name, a leftover from the scaffold.

---

## Contributing

Issues and pull requests are welcome. If you change the audio protocol, please update the "Wire protocol" section here and keep the server and client compatible.

---

## Notes

This project was generated by **opencode + DeepSeek Flash**, mainly for learning and personal use on a local network. Evaluate your own network environment and security risks before use.
