import Foundation

public struct SSEEvent: Equatable, Sendable {
    public var name: String
    public var data: String
    public init(name: String = "message", data: String) { self.name = name; self.data = data }
}

/// Incremental byte parser: handles split UTF-8, CR/LF/CRLF, multiline data and heartbeats.
public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var dataLines: [String] = []
    private var eventName = "message"
    private var afterCR = false
    private var eventSize = 0
    private var isFirstLine = true
    public let maximumEventBytes: Int

    public init(maximumEventBytes: Int = 2_097_152) { self.maximumEventBytes = maximumEventBytes }

    public mutating func append(_ bytes: Data) throws -> [SSEEvent] {
        var result: [SSEEvent] = []
        for byte in bytes {
            if byte == 13 {
                consumeLine(into: &result)
                afterCR = true
            } else if byte == 10 {
                if !afterCR { consumeLine(into: &result) }
                afterCR = false
            } else {
                afterCR = false
                line.append(byte)
                eventSize += 1
                if eventSize > maximumEventBytes { throw APIError.streamTooLarge }
            }
        }
        return result
    }

    public mutating func finish() -> [SSEEvent] {
        var result: [SSEEvent] = []
        if !line.isEmpty { consumeLine(into: &result) }
        dispatch(into: &result)
        return result
    }

    private mutating func consumeLine(into result: inout [SSEEvent]) {
        var text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if isFirstLine {
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            isFirstLine = false
        }
        if text.isEmpty { dispatch(into: &result); return }
        if text.hasPrefix(":") { eventSize -= text.utf8.count; return }
        let pair = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var value = pair.count == 2 ? String(pair[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch pair[0] {
        case "data": dataLines.append(value)
        case "event": eventName = value
        default: break
        }
    }

    private mutating func dispatch(into result: inout [SSEEvent]) {
        if !dataLines.isEmpty { result.append(SSEEvent(name: eventName, data: dataLines.joined(separator: "\n"))) }
        dataLines.removeAll(keepingCapacity: true)
        eventName = "message"
        eventSize = 0
    }
}
