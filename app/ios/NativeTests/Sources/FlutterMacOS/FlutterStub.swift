// Test-only stand-in for the FlutterMacOS types that the generated EngineApi.g.swift names, so the pigeon
// message structs, PigeonError and the API protocols compile in the macOS test package. Nothing here sends
// messages: the channel calls are no-ops. The app itself links the real Flutter framework.
import Foundation

public protocol FlutterBinaryMessenger: AnyObject {}

public typealias FlutterReply = (Any?) -> Void
public typealias FlutterMessageHandler = (Any?, @escaping FlutterReply) -> Void

open class FlutterError: NSObject {
    public let code: String
    public let message: String?
    public let details: Any?

    public init(code: String, message: String?, details: Any?) {
        self.code = code
        self.message = message
        self.details = details
    }
}

open class FlutterStandardTypedData: NSObject {
    public let data: Data
    public init(bytes data: Data) { self.data = data }
}

open class FlutterStandardReader: NSObject {
    public init(data: Data) {}
    open func readValue() -> Any? { nil }
    open func readValue(ofType type: UInt8) -> Any? { nil }
}

open class FlutterStandardWriter: NSObject {
    public init(data: NSMutableData) {}
    open func writeByte(_ value: UInt8) {}
    open func writeValue(_ value: Any) {}
}

open class FlutterStandardReaderWriter: NSObject {
    override public init() {}
    open func reader(with data: Data) -> FlutterStandardReader { FlutterStandardReader(data: data) }
    open func writer(with data: NSMutableData) -> FlutterStandardWriter { FlutterStandardWriter(data: data) }
}

open class FlutterStandardMessageCodec: NSObject {
    public init(readerWriter: FlutterStandardReaderWriter) {}
}

open class FlutterBasicMessageChannel: NSObject {
    public init(name: String, binaryMessenger: FlutterBinaryMessenger, codec: FlutterStandardMessageCodec) {}
    open func setMessageHandler(_ handler: FlutterMessageHandler?) {}
    open func sendMessage(_ message: Any?, reply: FlutterReply?) {}
}
