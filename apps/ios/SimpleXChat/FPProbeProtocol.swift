import Foundation
import FileProvider

public let fpProbeServiceName = NSFileProviderServiceName("chat.simplex.app.probe")

public let fpProbeRestrictedServiceName = NSFileProviderServiceName("chat.simplex.app.probe.restricted")

public let fpProbeItemName = "probe"

public let fpProbeItemIdentifier = NSFileProviderItemIdentifier("probe")

@objc(SimpleXFPProbeService) public protocol FPProbeService {
    func ping(_ request: Data, reply: @escaping (Data) -> Void)
    func crash()
}

@objc(SimpleXFPProbeClient) public protocol FPProbeClient {
    func notify(_ request: Data)
}

public struct FPProbeRequest: Codable {
    public var caller: String
    public var tag: String
    public var hold: Bool

    public init(caller: String, tag: String, hold: Bool) {
        self.caller = caller
        self.tag = tag
        self.hold = hold
    }
}

public struct FPProbeReply: Codable {
    public var pid: Int32
    public var startedAt: Double
    public var instances: Int
    public var calls: Int
    public var holders: Int
    public var footprint: UInt64
    public var storage: String

    public init(pid: Int32, startedAt: Double, instances: Int, calls: Int, holders: Int, footprint: UInt64, storage: String) {
        self.pid = pid
        self.startedAt = startedAt
        self.instances = instances
        self.calls = calls
        self.holders = holders
        self.footprint = footprint
        self.storage = storage
    }
}
