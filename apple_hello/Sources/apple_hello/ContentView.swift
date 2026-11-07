import AVFoundation
import Combine
import Foundation
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var receiver = UDPReceiver()
    // 流式音频播放器（48kHz 立体声）
    @StateObject private var player = AudioPlayer()

    var body: some View {
        VStack(spacing: 16) {
            // 接收端只负责监听固定端口，发送端直接发到「本机 IP:9000」。
            Text("监听端口 \(UDPReceiver.listenPort) · 支持后台/锁屏播放")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                if receiver.isReceiving {
                    receiver.stop()
                } else {
                    if receiver.start() {
                        player.start()
                    }
                }
            } label: {
                Text(receiver.isReceiving ? "停止接收" : "开始接收")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            // 诊断信息：先看有没有收包、峰值是否非零，再看音频引擎状态。
            VStack(alignment: .leading, spacing: 4) {
                if let error = receiver.errorMessage {
                    Text("接收错误：\(error)")
                        .foregroundStyle(.red)
                }
                Text("已收包 \(receiver.diagnostics.packets) 个 / \(receiver.diagnostics.bytes) 字节")
                Text("数据峰值 \(String(format: "%.3f", receiver.diagnostics.peak))")
                Text(player.status)
            }
            .font(.footnote.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("测试声音（440Hz）") {
                player.playTestTone()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .onAppear {
            // 每收到并解析完一个数据包时调用（主线程）
            // samples 一包 960 组，每组 first = 左声道、second = 右声道（-1...1）
            receiver.onDataReceived = { samples in
                player.enqueue(samples)
            }

            // 停止接收后调用（主线程）
            receiver.onStopped = {
                player.stop()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // 回到前台时，如果引擎被系统停掉（路由变化/被打断），自动恢复。
            if newPhase == .active {
                player.ensureRunning()
            }
        }
    }
}

// MARK: - 音频播放

/// 48kHz 立体声流式播放器。
///
/// 对方每 20ms 发来 960 帧，正好对应 48kHz：
/// 960 帧 / 0.02 秒 = 48000 帧/秒。
/// 数据先写入环形缓冲，再由音频线程按声卡时钟取走，网络抖动时用静音补齐。
final class AudioPlayer: NSObject, ObservableObject {

    static let sampleRate: Double = 48_000

    private let engine = AVAudioEngine()
    private let ringBuffer: SampleRingBuffer
    private var sourceNode: AVAudioSourceNode?
    private var isRunning = false
    /// 被电话/其他 App 打断后，是否需要恢复播放。
    private var shouldResumeAfterInterruption = false

    /// 音频引擎状态，显示在界面上，便于判断问题出在网络还是播放。
    @Published private(set) var status = "音频：未启动"

    init(sampleRate: Double = 48_000) {
        // 交错存放：L0 R0 L1 R1 ...；容量为 0.5 秒
        ringBuffer = SampleRingBuffer(capacity: Int(sampleRate))
        super.init()

        #if os(iOS)
        observeAudioSession()
        #endif
    }

    #if os(iOS)
    private func observeAudioSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        center.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            shouldResumeAfterInterruption = isRunning
            if engine.isRunning { engine.stop() }
            isRunning = false
            status = "音频：被系统中断"

        case .ended:
            guard shouldResumeAfterInterruption else { return }
            shouldResumeAfterInterruption = false
            try? AVAudioSession.sharedInstance().setActive(true)
            start()

        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        // 拔耳机、蓝牙断开等路由变化后，引擎可能被停止，尝试恢复。
        ensureRunning()
    }

    @objc private func handleEngineConfigurationChange(_ notification: Notification) {
        // 输出设备采样率/通道数变化时，引擎需要重新 prepare/start。
        ensureRunning()
    }
    #endif

    /// 如果仍在接收状态但引擎被系统停掉了，就把它重新拉起来。
    /// 切回前台、路由变化、打断结束后都会调用。
    func ensureRunning() {
        guard isRunning else { return }
        guard !engine.isRunning else { return }

        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            engine.prepare()
            try engine.start()
            let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            status = "音频：已恢复（\(Int(rate)) Hz）"
            print("AudioPlayer: 音频引擎已恢复，输出采样率 \(rate)")
        } catch {
            print("AudioPlayer: 音频引擎恢复失败 \(error)")
            status = "音频恢复失败：\(error.localizedDescription)"
        }
    }

    /// 启动音频引擎（可重复调用）。
    ///
    /// 注意：AVAudioEngine 的建图和 connect 必须放在 AVAudioSession 激活之后，
    /// 否则真机上可能因硬件格式无效而抛出无法捕获的 ObjC 异常导致闪退。
    func start() {
        guard !isRunning else { return }

        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setPreferredSampleRate(Self.sampleRate)
            try session.setActive(true)
            #endif

            setUpEngineIfNeeded()
            guard sourceNode != nil else {
                status = "音频：创建播放节点失败"
                return
            }

            engine.prepare()
            try engine.start()
            isRunning = true
            let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            #if os(iOS)
            let route = AVAudioSession.sharedInstance().currentRoute.outputs
                .map { "\($0.portName)[\($0.portType.rawValue)]" }
                .joined(separator: ",")
            #else
            let route = "macOS"
            #endif
            status = "音频：运行中，输出 \(Int(outputRate)) Hz，路由 \(route)"
            print("AudioPlayer: 音频已启动，输出采样率 \(outputRate)，路由 \(route)")
        } catch {
            print("AudioPlayer: 音频启动失败 \(error)")
            status = "音频启动失败：\(error.localizedDescription)"
            isRunning = false
        }
    }

    /// 只建一次音频图。使用**非交错**标准格式，和 AVAudioEngine 的惯例一致。
    private func setUpEngineIfNeeded() {
        guard sourceNode == nil else { return }

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate,
            channels: 2
        ) else {
            print("AudioPlayer: 无法创建 48kHz 立体声格式")
            return
        }

        // 只捕获 ringBuffer，避免闭包 -> self -> sourceNode 的循环引用
        let ring = ringBuffer
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)

            if buffers.count >= 2,
               let leftData = buffers[0].mData,
               let rightData = buffers[1].mData {
                // 非交错：每个声道一个缓冲区。
                // 注意：这里以 frameCount 为准，不要用 mDataByteSize 推算帧数，
                // 某些情况下引擎给的 mDataByteSize 可能是 0，会导致永远输出静音。
                let left = leftData.assumingMemoryBound(to: Float.self)
                let right = rightData.assumingMemoryBound(to: Float.self)

                let read = ring.read(left: left, right: right, frames: frames)
                if read < frames {
                    left.advanced(by: read).update(repeating: 0, count: frames - read)
                    right.advanced(by: read).update(repeating: 0, count: frames - read)
                }
            } else if let mData = buffers.first?.mData {
                // 兜底：如果系统给的是交错缓冲区，按交错方式写。
                let availableBytes = Int(buffers[0].mDataByteSize)
                let maxFrames = min(
                    frames,
                    availableBytes / (MemoryLayout<Float>.size * 2)
                )
                let output = mData.assumingMemoryBound(to: Float.self)

                let read = ring.read(into: output, count: maxFrames * 2)
                let readFrames = read / 2
                if readFrames < maxFrames {
                    output.advanced(by: read)
                        .update(repeating: 0, count: (maxFrames - readFrames) * 2)
                }
            }

            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
    }

    /// 把一包解析好的样本转成交错立体声写入缓冲。
    /// 第一包到来时如果引擎还没启动，会自动启动。
    func enqueue(_ samples: [UDPSample]) {
        if !isRunning { start() }
        guard isRunning, !samples.isEmpty else { return }

        var interleaved = [Float]()
        interleaved.reserveCapacity(samples.count * 2)
        for sample in samples {
            interleaved.append(sample.first)   // 左声道
            interleaved.append(sample.second)  // 右声道
        }
        ringBuffer.write(interleaved)
    }

    /// 播放 0.25 秒 440Hz 测试音，用来单独验证「音频引擎 + 扬声器」这条链路。
    /// 如果这个按钮有声音，说明播放没问题，问题在收包/发包；没声音则是播放链路问题。
    func playTestTone() {
        if !isRunning { start() }
        guard isRunning else { return }

        let rate = Self.sampleRate
        let frameCount = Int(rate * 0.25)
        var samples = [Float]()
        samples.reserveCapacity(frameCount * 2)
        for index in 0..<frameCount {
            let value = Float(sin(2.0 * Double.pi * 440.0 * Double(index) / rate) * 0.2)
            samples.append(value) // 左
            samples.append(value) // 右
        }
        ringBuffer.write(samples)
        status = "音频：测试音已写入（运行中）"
    }

    /// 停止播放并清空缓冲。
    func stop() {
        shouldResumeAfterInterruption = false
        if engine.isRunning {
            engine.stop()
        }
        ringBuffer.reset()
        isRunning = false
        status = "音频：已停止"

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    deinit {
        #if os(iOS)
        NotificationCenter.default.removeObserver(self)
        #endif
        if engine.isRunning {
            engine.stop()
        }
    }
}

/// 单生产者（网络回调）/ 单消费者（音频线程）的环形缓冲，存放交错的 Float 样本。
final class SampleRingBuffer: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    /// 已缓存的 Float 个数（不是帧数）
    private var available = 0

    init(capacity: Int) {
        // 容量必须是偶数，保证左右声道成对
        let evenCapacity = max(capacity, 2) / 2 * 2
        storage = [Float](repeating: 0, count: evenCapacity)
    }

    /// 写入交错样本；缓冲满时丢弃多余部分（保持低延迟，不越积越多）。
    func write(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        let capacity = storage.count
        let writable = min(samples.count, capacity - available)
        guard writable > 0 else { return }

        storage.withUnsafeMutableBufferPointer { destination in
            samples.withUnsafeBufferPointer { source in
                var remaining = writable
                var sourceOffset = 0
                while remaining > 0 {
                    let chunk = min(remaining, capacity - writeIndex)
                    destination.baseAddress!.advanced(by: writeIndex)
                        .update(from: source.baseAddress!.advanced(by: sourceOffset), count: chunk)
                    writeIndex = (writeIndex + chunk) % capacity
                    sourceOffset += chunk
                    remaining -= chunk
                }
            }
        }
        available += writable
    }

    /// 非交错读取：左/右声道分别写入两个缓冲区，返回实际读到的帧数。
    func read(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frames: Int
    ) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let capacity = storage.count
        let frameCount = min(frames, available / 2)
        guard frameCount > 0 else { return 0 }

        var index = readIndex
        for frame in 0..<frameCount {
            left[frame] = storage[index]
            index += 1
            if index == capacity { index = 0 }

            right[frame] = storage[index]
            index += 1
            if index == capacity { index = 0 }
        }
        readIndex = index
        available -= frameCount * 2
        return frameCount
    }

    /// 交错读取：尽量读满 `requested` 个 Float，返回实际读到的个数。
    func read(into destination: UnsafeMutablePointer<Float>, count requested: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let capacity = storage.count
        let count = min(requested, available)
        guard count > 0 else { return 0 }

        storage.withUnsafeBufferPointer { source in
            var remaining = count
            var destinationOffset = 0
            while remaining > 0 {
                let chunk = min(remaining, capacity - readIndex)
                destination.advanced(by: destinationOffset)
                    .update(from: source.baseAddress!.advanced(by: readIndex), count: chunk)
                readIndex = (readIndex + chunk) % capacity
                destinationOffset += chunk
                remaining -= chunk
            }
        }
        available -= count
        return count
    }

    /// 清空缓冲。
    func reset() {
        lock.lock()
        readIndex = 0
        writeIndex = 0
        available = 0
        lock.unlock()
    }
}
