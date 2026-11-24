import XCTest
import FileProvider
import OSLog

private let fpxLogger = Logger(subsystem: "chat.simplex.fpx", category: "foreign")

private func fpxLog(_ event: String, _ fields: String) {
    fpxLogger.log("FPX \(event, privacy: .public) pid=\(getpid(), privacy: .public) \(String(fields.map { $0.isWhitespace ? "_" : $0 }), privacy: .public)")
}

@objc(SimpleXFPProbeService) protocol ForeignProbeService {
    func ping(_ request: Data, reply: @escaping (Data) -> Void)
    func crash()
}

final class FPForeignTests: XCTestCase {
    func testForeignLookup() throws {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["FPX_ROOT"])
        fpxLog("foreign-start", "root=\(path)")
        let done = expectation(description: "lookup")
        done.assertForOverFulfill = false
        let start = Date()
        FileManager.default.getFileProviderServicesForItem(at: URL(fileURLWithPath: path, isDirectory: true)) { services, error in
            let names = services.map { $0.keys.map(\.rawValue).sorted().joined(separator: ",") } ?? "-"
            fpxLog("foreign-lookup", "services=\(names) error=\(String(describing: error))")
            guard let service = services?[NSFileProviderServiceName("chat.simplex.app.probe")] else {
                done.fulfill()
                return
            }
            service.getFileProviderConnection { connection, error in
                fpxLog("foreign-connect", "ok=\(connection == nil ? 0 : 1) error=\(String(describing: error))")
                guard let connection else {
                    done.fulfill()
                    return
                }
                connection.remoteObjectInterface = NSXPCInterface(with: ForeignProbeService.self)
                connection.resume()
                fpxLog("foreign-resumed", "")
                let proxy = connection.remoteObjectProxyWithErrorHandler { e in
                    fpxLog("foreign-reply", "ok=0 error=\(String(describing: e))")
                    done.fulfill()
                }
                guard let probe = proxy as? ForeignProbeService else {
                    fpxLog("foreign-reply", "ok=0 error=proxy")
                    done.fulfill()
                    return
                }
                probe.ping(Data(#"{"caller":"foreign","tag":"foreign","hold":false}"#.utf8)) { data in
                    fpxLog("foreign-reply", "ok=1 reply=\(String(decoding: data, as: UTF8.self))")
                    done.fulfill()
                }
            }
        }
        wait(for: [done], timeout: 30)
        fpxLog("foreign-end", "ms=\(Int(Date().timeIntervalSince(start) * 1000))")
    }
}
