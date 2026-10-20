import CFtopSys

/// The pointer, for the panel's resize cursors.
public enum Pointer {
    /// Lets the app set the cursor while another app is active. ftop never becomes the
    /// active app, and macOS otherwise ignores a background app's cursor. Returns false
    /// when the system refused.
    @discardableResult
    public static func setCursorInBackground(_ allowed: Bool) -> Bool {
        ftop_cursor_in_background(allowed ? 1 : 0) == 0
    }
}
