// Port of `Citation` in lib/src/services/inference/chat_prompt.dart (moved
// there from lib/src/screens/chat_screen.dart so the prompt fixture can be
// generated without the screen).

/// A passage an answer was built from, as the transcript shows it under the
/// answer and as the chat history stores it.
///
/// Stored alongside the message it belongs to (`conversation_messages
/// .citations`, a JSON array), so a reopened conversation still shows what its
/// answers were built from. An answer that arrives without its sources is the
/// thing this app is trying not to be.
public struct Citation: Sendable, Hashable {
    /// The content unit quoted. Opening the citation opens this unit.
    public let contentId: Int
    /// The work's title, or "Unknown source" when the corpus has none.
    public let source: String
    public let author: String?
    public let tradition: String?
    /// Where the text came from, when the corpus records it.
    public let sourceURL: String?

    public init(contentId: Int, source: String, author: String? = nil, tradition: String? = nil,
                sourceURL: String? = nil) {
        self.contentId = contentId
        self.source = source
        self.author = author
        self.tradition = tradition
        self.sourceURL = sourceURL
    }

    /// Whether the passage's origin is recorded. The UI uses this to tell a
    /// properly sourced edition from a legacy stub with no recorded origin; a
    /// passage pinned from the reader carries no URL on purpose (see
    /// `ChatPrompt`), and reads as "origin not recorded".
    public var isTraceable: Bool {
        guard let sourceURL else { return false }
        return !sourceURL.isEmpty
    }

    /// How the passage is described to the model, as opposed to the reader:
    /// "source — author — tradition tradition", leaving out what is missing or
    /// empty.
    ///
    /// The tradition is included deliberately: a comparative question is
    /// exactly the case where the model needs to know which camp a passage
    /// speaks for, and without it the answer attributes positions by guesswork.
    public var promptLabel: String {
        var parts = [source]
        if let author, !author.isEmpty { parts.append(author) }
        if let tradition, !tradition.isEmpty { parts.append("\(tradition) tradition") }
        return parts.joined(separator: " — ")
    }

    // MARK: - JSON, as Dart's toJson / fromJson

    /// Dart's `toJson()`: every key present, in this order, nil written as
    /// `null`, and the URL under `sourceUrl` (Dart's spelling, which is what
    /// stored blobs carry).
    var json: OrderedJSON {
        .object([
            ("contentId", .int(contentId)),
            ("source", .string(source)),
            ("author", author.map(OrderedJSON.string) ?? .null),
            ("tradition", tradition.map(OrderedJSON.string) ?? .null),
            ("sourceUrl", sourceURL.map(OrderedJSON.string) ?? .null),
        ])
    }

    /// Dart's `fromJson`: a missing `contentId` is 0 and a missing `source` is
    /// "Unknown source".
    ///
    /// More forgiving than the Dart in one way: a value of the wrong type
    /// (`"contentId": "42"`) reads as missing, where Dart's `as int?` throws
    /// and takes the whole reopened conversation down with it.
    init(json: OrderedJSON) {
        contentId = json["contentId"]?.intValue ?? 0
        source = json["source"]?.stringValue ?? "Unknown source"
        author = json["author"]?.stringValue
        tradition = json["tradition"]?.stringValue
        sourceURL = json["sourceUrl"]?.stringValue
    }

    /// The JSON text the Flutter app writes for these citations
    /// (`jsonEncode([for (c in citations) c.toJson()])`), byte for byte.
    public static func jsonText(_ citations: [Citation]) -> String {
        OrderedJSON.array(citations.map(\.json)).dartEncoded
    }

    /// Citations read back from stored JSON text.
    ///
    /// Nil when the text isn't a JSON array of objects: that is the Dart
    /// `StoredMessage.fromRow` tolerance, where a malformed blob costs the
    /// citations on one message and never the message itself.
    public static func decode(jsonText: String) -> [Citation]? {
        guard let items = OrderedJSON.parse(jsonText)?.arrayValue, items.allSatisfy(\.isObject) else {
            return nil
        }
        return items.map(Citation.init(json:))
    }
}
