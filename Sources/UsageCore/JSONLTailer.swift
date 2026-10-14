import Foundation

/// Reads a JSONL file incrementally, returning only complete lines appended since the last read.
/// A trailing partial line (one still being written) is held back until its newline arrives.
public final class JSONLTailer {
    public let url: URL
    public private(set) var offset: UInt64 = 0
    private var pending = Data()

    public init(url: URL) {
        self.url = url
    }

    public struct Read {
        public var lines: [Data]
        /// The file shrank since the last read, so earlier lines may no longer be valid.
        public var wasReset: Bool
    }

    public func readNewLines() throws -> Read {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        var wasReset = false
        if size < offset {
            offset = 0
            pending.removeAll()
            wasReset = true
        }
        guard size > offset else { return Read(lines: [], wasReset: wasReset) }

        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: Int(size - offset)) ?? Data()
        offset += UInt64(data.count)
        pending.append(data)

        var lines: [Data] = []
        var start = pending.startIndex
        while let newline = pending[start...].firstIndex(of: 0x0A) {
            if newline > start {
                lines.append(pending.subdata(in: start..<newline))
            }
            start = pending.index(after: newline)
        }
        pending = pending.subdata(in: start..<pending.endIndex)
        return Read(lines: lines, wasReset: wasReset)
    }
}
