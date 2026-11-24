import XCTest
import FileProvider
import OSLog

private let fpxLogger = Logger(subsystem: "chat.simplex.fpx", category: "foreign")

@objc(SimpleXFPProbeService) private protocol ForeignProbeService {
    func ping(_ request: Data, reply: @escaping (Data) -> Void)
    func crash()
}

final class FPForeignTests: XCTestCase {
    func testForeignLookup() throws {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["FPX_ROOT"])
        let done = expectation(description: "lookup")
        done.assertForOverFulfill = false
        var result = "none"
        let start = Date()
        FileManager.default.getFileProviderServicesForItem(at: URL(fileURLWithPath: path, isDirectory: true)) { services, error in
            let names = services.map { $0.keys.map(\.rawValue).sorted().joined(separator: ",") } ?? "-"
            guard let service = services?[NSFileProviderServiceName("chat.simplex.app.probe")] else {
                result = "lookup services=\(names) error=\(String(describing: error))"
                done.fulfill()
                return
            }
            service.getFileProviderConnection { connection, error in
                guard let connection else {
                    result = "connect services=\(names) error=\(String(describing: error))"
                    done.fulfill()
                    return
                }
                connection.remoteObjectInterface = NSXPCInterface(with: ForeignProbeService.self)
                connection.resume()
                let proxy = connection.remoteObjectProxyWithErrorHandler { e in
                    result = "reply services=\(names) error=\(String(describing: e))"
                    done.fulfill()
                } as? ForeignProbeService
                proxy?.ping(Data(#"{"caller":"foreign","tag":"foreign","hold":false}"#.utf8)) { data in
                    result = "ok services=\(names) reply=\(String(decoding: data, as: UTF8.self))"
                    done.fulfill()
                }
            }
        }
        wait(for: [done], timeout: 30)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        fpxLogger.log("FPX foreign pid=\(getpid(), privacy: .public) ms=\(ms, privacy: .public) result=\(String(result.map { $0.isWhitespace ? "_" : $0 }), privacy: .public)")
    }
}
