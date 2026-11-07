import Combine
import Darwin
import Foundation

/// 一次收包解析后的一组数据：8 字节 = 两个小端 float32。
struct UDPSample: Sendable {
    /// 第一个 4 字节（小端 float32）
    let first: Float
    /// 第二个 4 字节（小端 float32）
    let second: Float
}

/// 接收诊断信息，显示在界面上，用来判断问题卡在哪一环。
struct UDPSDiagnostics: Equatable, Sendable {
    var packets = 0
    var bytes = 0
    var peak: Float = 0
}

/// UDP 接收器。
///
/// - 接收循环运行在后台队列，不阻塞 UI。
/// - 每个数据包应为 1920 * 4 = 7680 字节，解析成 960 组 `UDPSample`。
/// - `onDataReceived`、`onStopped` 都在主线程回调。
final class UDPReceiver: ObservableObject, @unchecked Sendable {

    // MARK: - 协议常量

    /// 每个数据包的字节数：1920 * 4。
    static let bytesPerPacket = 1920 * 4
    /// 每个数据包解析出的组数：7680 / 8 = 960。
    static let samplesPerPacket = bytesPerPacket / 8
    /// 单次收包缓冲区（UDP 数据报最大 65507 字节）。
    private static let receiveBufferSize = 65536
    /// 非阻塞收包的 poll 超时（毫秒），用于及时响应停止。
    private static let pollTimeout: Int32 = 100

    // MARK: - 回调（内容留给你实现）

    /// 每收到并解析完一个数据包时调用，在主线程回调。
    var onDataReceived: (([UDPSample]) -> Void)?

    /// 停止接收后调用，在主线程回调。
    var onStopped: (() -> Void)?

    // MARK: - 状态

    /// 当前是否正在接收，驱动按钮文案。
    @Published private(set) var isReceiving = false
    /// 收包诊断：包数、字节数、峰值。界面会显示，便于定位问题。
    @Published private(set) var diagnostics = UDPSDiagnostics()
    /// 最近一次错误（bind/socket 失败等），界面会显示。
    @Published private(set) var errorMessage: String?

    private let receiveQueue = DispatchQueue(
        label: "com.example.apple-hello.udp-receive",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private var running = false
    /// 每次 start/stop 都递增，用于让旧循环尽快退出。
    private var generation = 0

    // MARK: - 对外接口

    /// 本地监听端口。发送端（sound-copy）直接发到「本机 IP:9000」即可。
    static let listenPort: UInt16 = 9000

    /// 开始在固定端口 `9000` 上接收，无需再输入对方地址。
    @discardableResult
    func start() -> Bool {
        stateLock.lock()
        if running {
            stateLock.unlock()
            return false
        }
        running = true
        generation += 1
        let currentGeneration = generation
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.isReceiving = true
            self?.errorMessage = nil
            self?.diagnostics = UDPSDiagnostics()
        }

        receiveQueue.async { [weak self] in
            self?.receiveLoop(generation: currentGeneration, port: Self.listenPort)
        }
        return true
    }

    /// 停止接收数据，并触发 `onStopped`。
    func stop() {
        stateLock.lock()
        if !running {
            stateLock.unlock()
            return
        }
        running = false
        generation += 1
        stateLock.unlock()

        // 后台循环会在 poll 超时后退出并自行关闭 socket。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isReceiving = false
            self.onStopped?()
        }
    }

    // MARK: - 接收循环（后台队列）

    private func isActive(generation expected: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running && generation == expected
    }

    /// 记录错误并同步到界面。
    private func report(_ message: String) {
        print("UDPReceiver: \(message)")
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = message
        }
    }

    /// 纯 UDP 监听通常不会触发 iOS 的「本地网络」权限弹窗。
    /// 从同一个 socket 发一个本地广播包，主动把系统权限弹窗顶出来。
    private func triggerLocalNetworkPrompt(fd: Int32, port: UInt16) {
        var enable: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enable, socklen_t(MemoryLayout<Int32>.size))

        var broadcast = sockaddr_in()
        broadcast.sin_family = sa_family_t(AF_INET)
        broadcast.sin_port = port.bigEndian
        broadcast.sin_addr = in_addr(s_addr: INADDR_BROADCAST)

        var probe: UInt8 = 0
        let sent = withUnsafePointer(to: &broadcast) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, &probe, 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        // 权限尚未授予时这里经常返回 -1，但系统弹窗已经被触发。
        if sent < 0 {
            print("UDPReceiver: 本地网络探测包发送失败, errno=\(errno)")
        }
    }

    private func receiveLoop(generation: Int, port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            report("socket() 失败, errno=\(errno)")
            handleLoopEnded(generation: generation)
            return
        }
        defer { close(fd) }

        // 允许端口复用，避免重启时 bind 失败。
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // 加大接收缓冲区，防止 20ms 一包时丢包。
        var receiveBuffer: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))

        // 1. 本地绑定到输入的端口，等待对方发数据过来。
        var localAddress = sockaddr_in()
        localAddress.sin_family = sa_family_t(AF_INET)
        localAddress.sin_port = port.bigEndian
        localAddress.sin_addr = in_addr(s_addr: INADDR_ANY)

        let bindResult = withUnsafePointer(to: &localAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            report("bind(\(port)) 失败, errno=\(errno)")
            handleLoopEnded(generation: generation)
            return
        }

        // 2. 不再调用 connect()。
        // UDP 的 connect() 会给内核设置一个严格的源地址/源端口过滤器：
        // 只有源 IP 和源端口都完全匹配的数据报才会被投递，其余会被静默丢弃。
        // 发送端如果使用系统随机分配的源端口，就会导致一个包都收不到。
        // 这里只用 bind(0.0.0.0:9000) 监听，接收任意来源的数据。
        print("UDPReceiver: 已监听 0.0.0.0:\(port)，等待发送端发来的数据")
        triggerLocalNetworkPrompt(fd: fd, port: port)

        // 非阻塞 + poll：既能及时收包，也能在 stop() 后快速退出。
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var buffer = [UInt8](repeating: 0, count: Self.receiveBufferSize)
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)

        var packetCount = 0
        var byteCount = 0
        var peak: Float = 0
        var sincePublish = 0

        while isActive(generation: generation) {
            let ready = poll(&descriptor, 1, Self.pollTimeout)

            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 {
                // 超时，回到循环条件检查是否该停止。
                continue
            }

            let count = recv(fd, &buffer, buffer.count, 0)
            if count > 0 {
                if let packetPeak = deliver(buffer: buffer, count: count) {
                    packetCount += 1
                    byteCount += count
                    peak = max(peak, packetPeak)
                    sincePublish += 1

                    // 第一包立即显示，之后每 10 包（约 200ms）刷新一次，避免过度重绘。
                    if sincePublish >= 10 || packetCount == 1 {
                        sincePublish = 0
                        let snapshot = UDPSDiagnostics(
                            packets: packetCount,
                            bytes: byteCount,
                            peak: peak
                        )
                        DispatchQueue.main.async { [weak self] in
                            self?.diagnostics = snapshot
                        }
                    }
                }
            } else if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    continue
                }
                break
            }
            // count == 0 表示为空数据报，直接忽略。
        }

        handleLoopEnded(generation: generation)
    }

    /// 因错误导致循环意外结束时，复位状态并通知外部。
    private func handleLoopEnded(generation: Int) {
        stateLock.lock()
        let endedWhileRunning = running && generation == self.generation
        if endedWhileRunning {
            running = false
            self.generation += 1
        }
        stateLock.unlock()

        guard endedWhileRunning else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isReceiving = false
            self.onStopped?()
        }
    }

    // MARK: - 解析

    /// 把收到的字节按小端 float32 每 8 字节一组解析后回调，返回本包峰值。
    @discardableResult
    private func deliver(buffer: [UInt8], count: Int) -> Float? {
        guard count > 0, count % 8 == 0 else { return nil }

        let pairCount = count / 8
        var samples = [UDPSample]()
        samples.reserveCapacity(pairCount)
        var peak: Float = 0

        for index in 0..<pairCount {
            let offset = index * 8
            let first = Float(bitPattern: UInt32(littleEndian: Self.readUInt32(buffer, offset)))
            let second = Float(bitPattern: UInt32(littleEndian: Self.readUInt32(buffer, offset + 4)))
            samples.append(UDPSample(first: first, second: second))
            peak = max(peak, max(abs(first), abs(second)))
        }

        DispatchQueue.main.async { [weak self] in
            self?.onDataReceived?(samples)
        }
        return peak
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
