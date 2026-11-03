/// The reader's own data: highlights, notes, conversations, bookmarks.
///
/// Mirrors `UserDatabase` in lib/src/services/user_database.dart. Kept apart
/// from the corpus so a corpus update never touches it; the native app opens
/// the same file in place after installing over the Flutter one.
public enum UserDatabase {
    public static let fileName = "council_user.db"
}
