import Foundation

/// The one way Prompt Relay counts the characters of copied text: Unicode
/// scalars, which is what every copy confirmation, Preview and the hand-off
/// show (an emoji with a skin tone counts as its scalars). File and image
/// sizes are never added.
public enum CharacterCount {
    public static func of(_ text: String) -> Int { text.unicodeScalars.count }
}
