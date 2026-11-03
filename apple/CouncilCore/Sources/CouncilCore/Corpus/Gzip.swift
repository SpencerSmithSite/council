// Ported from the `gzip.decode` / `gzip.decoder` calls in
// lib/src/services/database_service.dart (`_copyDatabaseFromAsset`) and
// lib/src/services/packs/pack_service.dart (`_expand`).

import Foundation
import zlib

/// Why a gzip file could not be expanded.
///
/// Dart surfaces its own codec's exception here and neither caller catches it,
/// so this is not folded into `PackError`: a corrupt archive that somehow
/// passed its checksum is reported as what it is.
public struct GzipError: Error, CustomStringConvertible, Sendable {
    public let description: String
}

/// gzip expansion, streamed file to file.
///
/// Foundation has no gzip codec. This uses the SDK's zlib rather than the
/// Compression framework because zlib parses the gzip wrapper itself
/// (`windowBits` 15 + 16): the optional header fields — the bundled corpus
/// carries an FNAME, "core.db" — and the CRC-32 and length trailer, which is
/// checked. Compression's `COMPRESSION_ZLIB` is raw deflate only, so the
/// wrapper, and the CRC, would have to be reimplemented by hand.
///
/// Streamed rather than buffered for the reason `_download` streams: holding
/// a compressed fragment and its expanded copy in memory at once is avoidable
/// on a phone.
public enum Gzip {
    private static let chunkSize = 256 * 1024

    /// Expand the gzip file at `source` into `destination`, replacing it.
    ///
    /// Concatenated members are expanded one after another, as gunzip does.
    /// The destination is flushed to disk before returning, like Dart's
    /// `writeAsBytes(flush: true)`, because a caller may stamp the result as
    /// installed straight afterwards.
    public static func decompress(_ source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.truncate(atOffset: 0)

        var stream = z_stream()
        // inflateInit2 is a C macro; this is what it expands to.
        var status = inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw GzipError(description: "zlib could not start (\(status))")
        }
        defer { inflateEnd(&stream) }

        var outBuffer = [UInt8](repeating: 0, count: chunkSize)
        var sawAnyInput = false
        var memberOpen = false

        while true {
            guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            sawAnyInput = true
            var pending = chunk[...]

            while !pending.isEmpty {
                memberOpen = true
                let consumed: Int = try pending.withUnsafeBytes { raw in
                    stream.next_in = UnsafeMutablePointer(
                        mutating: raw.bindMemory(to: Bytef.self).baseAddress
                    )
                    stream.avail_in = uInt(raw.count)
                    repeat {
                        let produced: Int = outBuffer.withUnsafeMutableBytes { out in
                            stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                            stream.avail_out = uInt(out.count)
                            status = inflate(&stream, Z_NO_FLUSH)
                            return out.count - Int(stream.avail_out)
                        }
                        guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                            let reason = stream.msg.map { String(cString: $0) } ?? "error \(status)"
                            throw GzipError(description: "not a valid gzip file: \(reason)")
                        }
                        if produced > 0 {
                            try output.write(contentsOf: outBuffer[0..<produced])
                        }
                        if status == Z_STREAM_END { break }
                        // Z_BUF_ERROR with input left means no progress at all.
                        if status == Z_BUF_ERROR && produced == 0 { break }
                    } while stream.avail_in > 0 || stream.avail_out == 0
                    return raw.count - Int(stream.avail_in)
                }
                pending = pending.dropFirst(consumed)

                if status == Z_STREAM_END {
                    // One member is done; anything after it is another member.
                    memberOpen = false
                    guard inflateReset(&stream) == Z_OK else {
                        throw GzipError(description: "zlib could not reset between members")
                    }
                } else if consumed == 0 {
                    throw GzipError(description: "not a valid gzip file: no progress")
                }
            }
        }

        guard sawAnyInput else { throw GzipError(description: "empty file") }
        // A truncated file ends mid-member: zlib never reached the trailer, so
        // the CRC was never checked and the output is incomplete.
        guard !memberOpen else {
            throw GzipError(description: "not a valid gzip file: unexpected end of file")
        }
        try output.synchronize()
    }
}
