// Ported from `PackException` in lib/src/services/packs/pack_manifest.dart and
// the places lib/src/services/packs/pack_service.dart throws it.

import Foundation

/// Why a pack operation could not complete. Thrown rather than returned so a
/// partial install cannot be mistaken for a successful one.
///
/// Dart has one exception class carrying a message; each message it is ever
/// constructed with is a case here, and `message` reproduces its text exactly
/// (the golden scenarios compare it). The reader sees `message`.
///
/// Not everything a pack operation can throw is a `PackError`, in either app:
/// a merge that SQLite rejects (an id collision, a reshaped table) surfaces as
/// GRDB's `DatabaseError`, as it surfaces as sqflite's `DatabaseException` in
/// Flutter; a corrupt archive that somehow passed its checksum surfaces as
/// `GzipError`; a stall mid-download surfaces as the fetcher's own error.
public enum PackError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// The catalogue request had no answer within the network timeout.
    case catalogueTimedOut
    /// The catalogue answered with something other than HTTP 200.
    case catalogueUnavailable(status: Int)
    /// The manifest's id space is not the app's: its ids may already mean
    /// something else here.
    case differentIdSpace
    /// The manifest's vectors come from another embedding model.
    case incompatibleEmbeddingModel
    /// A fragment download had no answer within the network timeout.
    case downloadTimedOut(fragment: String)
    /// A fragment download answered with something other than HTTP 200.
    case downloadFailed(status: Int)
    /// The downloaded bytes do not hash to the manifest's `sha256`.
    case checksumMismatch

    public var message: String {
        switch self {
        case .catalogueTimedOut:
            "Could not reach the library catalogue: the connection timed out."
        case .catalogueUnavailable(let status):
            "Could not reach the library catalogue (HTTP \(status))."
        case .differentIdSpace:
            "This content was built for a different version of the app. Update the app and try again."
        case .incompatibleEmbeddingModel:
            "This content was built for a newer version of the app. Update the app and try again."
        case .downloadTimedOut(let fragment):
            "Could not start downloading \(fragment): the connection timed out."
        case .downloadFailed(let status):
            "Download failed (HTTP \(status))."
        case .checksumMismatch:
            "A download did not match its checksum and was discarded. Check your connection and try again."
        }
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}
