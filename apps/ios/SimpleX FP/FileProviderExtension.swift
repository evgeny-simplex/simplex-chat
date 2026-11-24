import FileProvider
import OSLog
import UniformTypeIdentifiers

private let fpxLogger = Logger(subsystem: "chat.simplex.fpx", category: "extension")

private func fpxLog(_ event: String, _ fields: String = "") {
    fpxLogger.log("FPX \(event, privacy: .public) pid=\(getpid(), privacy: .public) \(fields, privacy: .public)")
}

private func fpxValue(_ s: String) -> String {
    String(s.map { $0.isWhitespace ? "_" : $0 })
}

private func samePath(_ a: URL, _ b: URL) -> Bool {
    a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
}

private func processStartTime() -> Double {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
    let t = info.kp_proc.p_un.__p_starttime
    return Double(t.tv_sec) + Double(t.tv_usec) / 1e6
}

private func physFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
}

final class FileProviderExtension: NSFileProviderExtension {
    override init() {
        super.init()
        ProbeServer.shared.instanceCreated()
    }

    override func item(for identifier: NSFileProviderItemIdentifier) throws -> NSFileProviderItem {
        fpxLog("server-item", "id=\(identifier.rawValue)")
        switch identifier {
        case .rootContainer: return ProbeItem(identifier: .rootContainer, filename: "SimpleX", contentType: .folder)
        case fpProbeItemIdentifier: return ProbeItem(identifier: fpProbeItemIdentifier, filename: fpProbeItemName, contentType: .data)
        default: throw NSFileProviderError(.noSuchItem)
        }
    }

    override func urlForItem(withPersistentIdentifier identifier: NSFileProviderItemIdentifier) -> URL? {
        let root = NSFileProviderManager.default.documentStorageURL
        return switch identifier {
        case .rootContainer: root
        case fpProbeItemIdentifier: root.appendingPathComponent(fpProbeItemName)
        default: nil
        }
    }

    override func persistentIdentifierForItem(at url: URL) -> NSFileProviderItemIdentifier? {
        let root = NSFileProviderManager.default.documentStorageURL
        let id: NSFileProviderItemIdentifier? =
            if samePath(url, root) { NSFileProviderItemIdentifier.rootContainer }
            else if samePath(url, root.appendingPathComponent(fpProbeItemName)) { fpProbeItemIdentifier }
            else { nil }
        fpxLog("server-identifier", "url=\(fpxValue(url.path)) id=\(id?.rawValue ?? "-")")
        return id
    }

    override func providePlaceholder(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        fpxLog("server-placeholder", "url=\(fpxValue(url.path))")
        completionHandler(nil)
    }

    override func startProvidingItem(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        fpxLog("server-provide", "url=\(fpxValue(url.path))")
        completionHandler(nil)
    }

    override func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier) throws -> NSFileProviderEnumerator {
        fpxLog("server-enumerator", "id=\(containerItemIdentifier.rawValue)")
        return EmptyEnumerator()
    }

    override func supportedServiceSources(for itemIdentifier: NSFileProviderItemIdentifier) throws -> [NSFileProviderServiceSource] {
        fpxLog("server-sources", "id=\(itemIdentifier.rawValue)")
        return ProbeServer.shared.sources
    }
}

final class ProbeItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier = NSFileProviderItemIdentifier.rootContainer
    let filename: String
    @objc let contentType: UTType

    init(identifier: NSFileProviderItemIdentifier, filename: String, contentType: UTType) {
        itemIdentifier = identifier
        self.filename = filename
        self.contentType = contentType
    }
}

final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }
}

final class ProbeServer: NSObject, FPProbeService {
    static let shared = ProbeServer()
    let startedAt = processStartTime()
    let sources: [NSFileProviderServiceSource]
    private let lock = NSLock()
    private var instances = 0
    private var calls = 0
    private var holders: [NSXPCConnection] = []

    override init() {
        sources = [
            ProbeSource(name: fpProbeServiceName, restricted: false),
            ProbeSource(name: fpProbeRestrictedServiceName, restricted: true)
        ]
        super.init()
    }

    func instanceCreated() {
        lock.lock()
        instances += 1
        let n = instances
        lock.unlock()
        fpxLog("server-instance", "n=\(n) started=\(startedAt) footprint=\(physFootprint()) storage=\(fpxValue(NSFileProviderManager.default.documentStorageURL.path))")
    }

    func accept(_ connection: NSXPCConnection) {
        connection.exportedInterface = NSXPCInterface(with: FPProbeService.self)
        connection.exportedObject = self
        connection.remoteObjectInterface = NSXPCInterface(with: FPProbeClient.self)
        let peer = connection.processIdentifier
        connection.invalidationHandler = { [weak self, weak connection] in
            self?.drop(connection)
            fpxLog("server-invalidated", "peer=\(peer)")
        }
        connection.resume()
    }

    private func drop(_ connection: NSXPCConnection?) {
        lock.lock()
        holders.removeAll { $0 === connection }
        lock.unlock()
    }

    func ping(_ request: Data, reply: @escaping (Data) -> Void) {
        let r = try? JSONDecoder().decode(FPProbeRequest.self, from: request)
        let connection = NSXPCConnection.current()
        lock.lock()
        calls += 1
        let others = holders.filter { $0 !== connection }
        if r?.hold == true, let connection, !holders.contains(where: { $0 === connection }) {
            holders.append(connection)
        }
        let response = FPProbeReply(
            pid: getpid(),
            startedAt: startedAt,
            instances: instances,
            calls: calls,
            holders: holders.count,
            footprint: physFootprint(),
            storage: NSFileProviderManager.default.documentStorageURL.path
        )
        lock.unlock()
        fpxLog("server-ping", "from=\(r?.caller ?? "?") tag=\(r?.tag ?? "?") peer=\(connection?.processIdentifier ?? 0) calls=\(response.calls) holders=\(response.holders) notified=\(others.count) footprint=\(response.footprint)")
        for holder in others {
            let peer = holder.processIdentifier
            let proxy = holder.remoteObjectProxyWithErrorHandler { e in
                fpxLog("server-notify-error", "peer=\(peer) error=\(fpxValue(String(describing: e)))")
            }
            (proxy as? FPProbeClient)?.notify(request)
        }
        reply((try? JSONEncoder().encode(response)) ?? Data())
    }

    func crash() {
        fpxLog("server-crash")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exit(1) }
    }
}

final class ProbeSource: NSObject, NSFileProviderServiceSource, NSXPCListenerDelegate {
    let serviceName: NSFileProviderServiceName
    @objc let isRestricted: Bool
    private let listener = NSXPCListener.anonymous()

    init(name: NSFileProviderServiceName, restricted: Bool) {
        serviceName = name
        isRestricted = restricted
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint {
        fpxLog("server-endpoint", "service=\(serviceName.rawValue)")
        return listener.endpoint
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        fpxLog("server-accept", "service=\(serviceName.rawValue) peer=\(newConnection.processIdentifier)")
        ProbeServer.shared.accept(newConnection)
        return true
    }
}
