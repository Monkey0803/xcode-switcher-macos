import AppKit

extension NSPasteboard {
    /// Replaces the contents with `text`, which is what every "copy that command"
    /// action does — kept in one place rather than in each caller.
    func replaceContents(with text: String) {
        clearContents()
        setString(text, forType: .string)
    }
}
