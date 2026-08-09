import Foundation
import zlib

/// Reads an allowlisted diff-viewer asset in chunks suitable for a URL scheme task.
/// WebKit does not honor Content-Encoding for app-owned custom schemes, so `.deflate`
/// assets must be inflated before they cross the scheme-handler boundary. One shared
/// actor admits exactly one stream at a time so decoded bytes and file handles retain
/// the same aggregate bound as the former serial stream queue.
actor DiffViewerAssetReader {
    private static let maxInflatedSize = 32 * 1024 * 1024

    private final class Stream {
        let fileURL: URL
        var decodedData: Data?
        var decodedOffset = 0
        var fileHandle: FileHandle?

        init(fileURL: URL) {
            self.fileURL = fileURL
        }
    }

    private struct ActiveStream {
        let id: UUID
        let stream: Stream
    }

    private struct WaitingStream {
        let id: UUID
        let fileURL: URL
        let continuation: CheckedContinuation<Void, Never>
    }

    private var activeStream: ActiveStream?
    private var waitingStreams: [WaitingStream] = []

    func read(streamID: UUID, fileURL: URL, upToCount count: Int) async throws -> Data {
        if activeStream?.id != streamID {
            await waitForTurn(streamID: streamID, fileURL: fileURL)
        }
        try Task.checkCancellation()
        guard let activeStream, activeStream.id == streamID else {
            throw CocoaError(.fileReadUnknown)
        }
        let stream = activeStream.stream
        try openIfNeeded(stream)

        if let decodedData = stream.decodedData {
            guard stream.decodedOffset < decodedData.count else { return Data() }
            let end = min(stream.decodedOffset + count, decodedData.count)
            defer { stream.decodedOffset = end }
            return decodedData.subdata(in: stream.decodedOffset..<end)
        }
        return try stream.fileHandle?.read(upToCount: count) ?? Data()
    }

    func close(streamID: UUID) {
        guard let current = activeStream, current.id == streamID else { return }
        try? current.stream.fileHandle?.close()
        current.stream.fileHandle = nil
        activeStream = nil
        admitNextStream()
    }

    deinit {
        try? activeStream?.stream.fileHandle?.close()
    }

    private func waitForTurn(streamID: UUID, fileURL: URL) async {
        if activeStream == nil {
            activeStream = ActiveStream(id: streamID, stream: Stream(fileURL: fileURL))
            return
        }

        await withCheckedContinuation { continuation in
            waitingStreams.append(WaitingStream(
                id: streamID,
                fileURL: fileURL,
                continuation: continuation
            ))
        }
    }

    private func admitNextStream() {
        guard !waitingStreams.isEmpty else { return }
        let next = waitingStreams.removeFirst()
        activeStream = ActiveStream(id: next.id, stream: Stream(fileURL: next.fileURL))
        next.continuation.resume()
    }

    private func openIfNeeded(_ stream: Stream) throws {
        guard stream.decodedData == nil, stream.fileHandle == nil else { return }
        if stream.fileURL.lastPathComponent.hasSuffix(".deflate") {
            let compressed = try Data(contentsOf: stream.fileURL, options: .mappedIfSafe)
            stream.decodedData = try Self.inflateZlib(compressed)
        } else {
            stream.fileHandle = try FileHandle(forReadingFrom: stream.fileURL)
        }
    }

    private static func inflateZlib(_ compressed: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { inflateEnd(&stream) }

        return try compressed.withUnsafeBytes { inputBuffer in
            guard let inputBase = inputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                throw CocoaError(.fileReadCorruptFile)
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBase)
            stream.avail_in = uInt(compressed.count)

            var output = Data()
            let chunkSize = 64 * 1024
            var chunk = [UInt8](repeating: 0, count: chunkSize)

            while true {
                try Task.checkCancellation()
                let result = chunk.withUnsafeMutableBytes { outputBuffer -> Int32 in
                    stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }

                let produced = chunkSize - Int(stream.avail_out)
                guard output.count <= maxInflatedSize - produced else {
                    throw CocoaError(.fileReadTooLarge)
                }
                output.append(chunk, count: produced)

                if result == Z_STREAM_END {
                    return output
                }
                guard result == Z_OK, stream.avail_in > 0 || produced > 0 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        }
    }
}
