import Foundation
import FileProvider
import OSLog

private let fpxLogger = Logger(subsystem: "chat.simplex.fpx", category: "client")

public func fpxLog(_ event: String, _ fields: String) {
    fpxLogger.log("FPX \(event, privacy: .public) pid=\(getpid(), privacy: .public) \(fields, privacy: .public)")
}

public enum FPProbeMethod: String, CaseIterable {
    case root
    case item
    case manager
    case restricted
}

public enum FPProbeStorage: String {
    case directoryAndItem
    case directory
    case none
}

private struct FPProbeError: Error {
    let phase: String
    let text: String

    init(_ phase: String, _ text: String) {
        self.phase = phase
        self.text = text
    }

    init(_ phase: String, _ error: Error?) {
        self.phase = phase
        if let e = error as NSError? {
            let underlying = (e.userInfo[NSUnderlyingErrorKey] as? NSError).map { "/\($0.domain)#\($0.code)" } ?? ""
            text = "\(e.domain)#\(e.code)\(underlying):\(fpxValue(e.localizedDescription))"
        } else {
            text = "nil"
        }
    }
}

private struct FPProbeSuccess {
    let reply: FPProbeReply
    let services: String
    let lookupMs: Int
    let connectMs: Int
    let replyMs: Int
}

private func fpxValue(_ s: String) -> String {
    String(s.map { $0.isWhitespace ? "_" : $0 }.prefix(200))
}

private func fpxNow() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1e9
}

private func fpxMs(_ from: Double, _ to: Double = fpxNow()) -> Int {
    Int(((to - from) * 1000).rounded())
}

private func fpxWait<T>(_ timeout: Double, _ phase: String, _ start: (@escaping (Result<T, FPProbeError>) -> Void) -> Void) -> Result<T, FPProbeError> {
    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var result: Result<T, FPProbeError>?
    var expired = false
    let t0 = fpxNow()
    start { r in
        lock.lock()
        let late = expired
        if result == nil && !late { result = r }
        lock.unlock()
        if late { fpxLog("late", "phase=\(phase) ms=\(fpxMs(t0)) ok=\((try? r.get()) != nil ? 1 : 0)") }
        semaphore.signal()
    }
    let waited = semaphore.wait(timeout: .now() + timeout)
    lock.lock()
    defer { lock.unlock() }
    if let result { return result }
    expired = true
    return .failure(FPProbeError(phase, waited == .timedOut ? "timeout" : "none"))
}

public final class FPProbe: NSObject, FPProbeClient {
    public static let shared = FPProbe()
    private let queue = DispatchQueue(label: "chat.simplex.fpx.probe")
    private var held: NSXPCConnection?
    private var heldCaller = "-"

    public func notify(_ request: Data) {
        let r = try? JSONDecoder().decode(FPProbeRequest.self, from: request)
        fpxLog("notify", "caller=\(heldCaller) from=\(r?.caller ?? "?") tag=\(r?.tag ?? "?")")
    }

    public func run(caller: String, tag: String, methods: [FPProbeMethod], budget: Double, hold: Bool = false, storage: FPProbeStorage = .directoryAndItem, completion: @escaping (String) -> Void) {
        queue.async {
            self.prepareStorage(caller, tag, storage)
            let results = methods.map { self.probe(caller, tag, $0, budget, hold: hold && $0 == .root) }
            fpxLog("done", "caller=\(caller) tag=\(tag)")
            completion(results.joined(separator: " "))
        }
    }

    public func pingHeld(caller: String, tag: String, timeout: Double, completion: @escaping () -> Void) {
        queue.async {
            let start = fpxNow()
            if let held = self.held {
                switch self.send(held, FPProbeRequest(caller: caller, tag: tag, hold: false), timeout: timeout) {
                case let .success(r):
                    fpxLog("result", "caller=\(caller) tag=\(tag) method=held ok=1 attempts=1 totalMs=\(fpxMs(start)) replyMs=\(fpxMs(start)) server=\(r.pid) serverStarted=\(r.startedAt) instances=\(r.instances) calls=\(r.calls) holders=\(r.holders) footprint=\(r.footprint)")
                case let .failure(e):
                    fpxLog("result", "caller=\(caller) tag=\(tag) method=held ok=0 attempts=1 totalMs=\(fpxMs(start)) phase=\(e.phase) error=\(e.text)")
                }
            } else {
                fpxLog("result", "caller=\(caller) tag=\(tag) method=held ok=0 attempts=0 totalMs=0 phase=connect error=no-held-connection")
            }
            fpxLog("done", "caller=\(caller) tag=\(tag)")
            completion()
        }
    }

    public func release(caller: String, tag: String, completion: @escaping () -> Void) {
        queue.async {
            fpxLog("release", "caller=\(caller) tag=\(tag) held=\(self.held == nil ? 0 : 1)")
            self.held?.invalidate()
            self.held = nil
            fpxLog("done", "caller=\(caller) tag=\(tag)")
            completion()
        }
    }

    public func crash(caller: String, tag: String, completion: @escaping () -> Void) {
        queue.async {
            let request = FPProbeRequest(caller: caller, tag: tag, hold: false)
            if case let .success((service, _)) = self.lookup(request, .root, timeout: 3),
               case let .success(connection) = self.connect(service, timeout: 3) {
                connection.remoteObjectInterface = NSXPCInterface(with: FPProbeService.self)
                connection.resume()
                (connection.remoteObjectProxy as? FPProbeService)?.crash()
                fpxLog("crash-sent", "caller=\(caller) tag=\(tag)")
                Thread.sleep(forTimeInterval: 1)
                connection.invalidate()
            } else {
                fpxLog("crash-failed", "caller=\(caller) tag=\(tag)")
            }
            fpxLog("done", "caller=\(caller) tag=\(tag)")
            completion()
        }
    }

    private func rootURL() -> URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: APP_GROUP_NAME)!.appendingPathComponent("File Provider Storage", isDirectory: true)
    }

    public func listDomains(caller: String, tag: String, completion: @escaping () -> Void) {
        queue.async {
            let start = fpxNow()
            let listed: Result<String, FPProbeError> = fpxWait(10, "domains") { done in
                NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                    if let error {
                        done(.failure(FPProbeError("domains", error)))
                    } else {
                        done(.success(domains.map(\.identifier.rawValue).joined(separator: ",")))
                    }
                }
            }
            switch listed {
            case let .success(ids): fpxLog("domains", "caller=\(caller) tag=\(tag) ok=1 ms=\(fpxMs(start)) count=\(ids.isEmpty ? 0 : ids.split(separator: ",").count) ids=\(fpxValue(ids))")
            case let .failure(e): fpxLog("domains", "caller=\(caller) tag=\(tag) ok=0 ms=\(fpxMs(start)) error=\(e.text)")
            }
            fpxLog("done", "caller=\(caller) tag=\(tag)")
            completion()
        }
    }

    private func rootExists() -> String {
        FileManager.default.fileExists(atPath: rootURL().path) ? "1" : "0"
    }

    private func prepareStorage(_ caller: String, _ tag: String, _ storage: FPProbeStorage) {
        let fm = FileManager.default
        let root = rootURL()
        let item = root.appendingPathComponent(fpProbeItemName)
        let rootExisted = fm.fileExists(atPath: root.path)
        let itemExisted = fm.fileExists(atPath: item.path)
        if storage != .none { try? fm.createDirectory(at: root, withIntermediateDirectories: true) }
        if storage == .directoryAndItem && !itemExisted { fm.createFile(atPath: item.path, contents: nil) }
        fpxLog("storage", "caller=\(caller) tag=\(tag) storage=\(storage.rawValue) root=\(fpxValue(root.path)) rootExisted=\(rootExisted ? 1 : 0) itemExisted=\(itemExisted ? 1 : 0) rootExists=\(rootExists()) itemExists=\(fm.fileExists(atPath: item.path) ? 1 : 0)")
    }

    private func probe(_ caller: String, _ tag: String, _ method: FPProbeMethod, _ budget: Double, hold: Bool) -> String {
        let start = fpxNow()
        let request = FPProbeRequest(caller: caller, tag: tag, hold: hold)
        var attempt = 0
        var lastError = FPProbeError("none", "none")
        repeat {
            attempt += 1
            let attemptStart = fpxNow()
            switch attemptOnce(request, method, remaining: budget - (attemptStart - start), hold: hold) {
            case let .success(s):
                fpxLog("result", "caller=\(caller) tag=\(tag) method=\(method.rawValue) ok=1 attempts=\(attempt) totalMs=\(fpxMs(start)) lookupMs=\(s.lookupMs) connectMs=\(s.connectMs) replyMs=\(s.replyMs) server=\(s.reply.pid) serverStarted=\(s.reply.startedAt) instances=\(s.reply.instances) calls=\(s.reply.calls) holders=\(s.reply.holders) footprint=\(s.reply.footprint) rootExists=\(rootExists()) services=\(s.services) serverStorage=\(fpxValue(s.reply.storage))")
                return "\(method.rawValue):ok:\(s.reply.pid)"
            case let .failure(e):
                lastError = e
                fpxLog("attempt", "caller=\(caller) tag=\(tag) method=\(method.rawValue) ok=0 attempt=\(attempt) phase=\(e.phase) ms=\(fpxMs(attemptStart)) rootExists=\(rootExists()) error=\(e.text)")
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while fpxNow() - start < budget
        fpxLog("result", "caller=\(caller) tag=\(tag) method=\(method.rawValue) ok=0 attempts=\(attempt) totalMs=\(fpxMs(start)) phase=\(lastError.phase) error=\(lastError.text)")
        return "\(method.rawValue):fail:\(lastError.phase)"
    }

    private func attemptOnce(_ request: FPProbeRequest, _ method: FPProbeMethod, remaining: Double, hold: Bool) -> Result<FPProbeSuccess, FPProbeError> {
        let t0 = fpxNow()
        let service: NSFileProviderService
        let services: String
        switch lookup(request, method, timeout: max(remaining, 0.5)) {
        case let .success((s, names)):
            service = s
            services = names
        case let .failure(e):
            return .failure(e)
        }
        let t1 = fpxNow()
        let connection: NSXPCConnection
        switch connect(service, timeout: max(remaining - (t1 - t0), 0.5)) {
        case let .success(c): connection = c
        case let .failure(e): return .failure(e)
        }
        let t2 = fpxNow()
        let pinged = ping(connection, request, hold: hold, timeout: 1)
        let t3 = fpxNow()
        if case .success = pinged, hold {
            held?.invalidate()
            held = connection
            heldCaller = request.caller
        } else {
            connection.invalidate()
        }
        return pinged.map { FPProbeSuccess(reply: $0, services: services, lookupMs: fpxMs(t0, t1), connectMs: fpxMs(t1, t2), replyMs: fpxMs(t2, t3)) }
    }

    private func lookup(_ request: FPProbeRequest, _ method: FPProbeMethod, timeout: Double) -> Result<(NSFileProviderService, String), FPProbeError> {
        fpxWait(timeout, "lookup") { done in
            switch method {
            case .root, .item:
                let root = self.rootURL()
                let url = method == .root ? root : root.appendingPathComponent(fpProbeItemName)
                FileManager.default.getFileProviderServicesForItem(at: url) { services, error in
                    let names = services.map { $0.keys.map(\.rawValue).sorted().joined(separator: ",") } ?? "-"
                    if let service = services?[fpProbeServiceName] {
                        done(.success((service, names)))
                    } else if let error {
                        done(.failure(FPProbeError("lookup", error)))
                    } else {
                        done(.failure(FPProbeError("lookup", "missing:\(names)")))
                    }
                }
            case .manager, .restricted:
                if #available(iOS 16.0, *) {
                    let manager = NSFileProviderManager.default
                    fpxLog("manager", "caller=\(request.caller) tag=\(request.tag) storage=\(fpxValue(manager.documentStorageURL.path))")
                    manager.getService(named: method == .manager ? fpProbeServiceName : fpProbeRestrictedServiceName, for: .rootContainer) { service, error in
                        if let service {
                            done(.success((service, "-")))
                        } else {
                            done(.failure(FPProbeError("lookup", error)))
                        }
                    }
                } else {
                    done(.failure(FPProbeError("lookup", "unavailable")))
                }
            }
        }
    }

    private func connect(_ service: NSFileProviderService, timeout: Double) -> Result<NSXPCConnection, FPProbeError> {
        fpxWait(timeout, "connect") { done in
            service.getFileProviderConnection { connection, error in
                if let connection {
                    done(.success(connection))
                } else {
                    done(.failure(FPProbeError("connect", error)))
                }
            }
        }
    }

    private func ping(_ connection: NSXPCConnection, _ request: FPProbeRequest, hold: Bool, timeout: Double) -> Result<FPProbeReply, FPProbeError> {
        connection.remoteObjectInterface = NSXPCInterface(with: FPProbeService.self)
        connection.exportedInterface = NSXPCInterface(with: FPProbeClient.self)
        connection.exportedObject = self
        if hold {
            let caller = request.caller
            connection.interruptionHandler = { fpxLog("interrupted", "caller=\(caller)") }
            connection.invalidationHandler = { fpxLog("invalidated", "caller=\(caller)") }
        }
        connection.resume()
        return send(connection, request, timeout: timeout)
    }

    private func send(_ connection: NSXPCConnection, _ request: FPProbeRequest, timeout: Double) -> Result<FPProbeReply, FPProbeError> {
        fpxWait(timeout, "reply") { done in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in done(.failure(FPProbeError("reply", error))) }
            guard let service = proxy as? FPProbeService else {
                done(.failure(FPProbeError("reply", "proxy")))
                return
            }
            service.ping((try? JSONEncoder().encode(request)) ?? Data()) { data in
                if let reply = try? JSONDecoder().decode(FPProbeReply.self, from: data) {
                    done(.success(reply))
                } else {
                    done(.failure(FPProbeError("reply", "decode")))
                }
            }
        }
    }
}
