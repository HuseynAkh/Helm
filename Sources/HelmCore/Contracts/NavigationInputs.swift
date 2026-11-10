/// Navigation intent preserves history and Recent semantics (F-005, F-030). `restore` brings back a saved session
/// and `open` starts a new tab or window at a place: neither adds to history, and only `open` counts as a visit in Recent.
public enum NavigationIntent: Hashable, Sendable { case push, back, forward, up, home, restore, open }
/// Selection origin prevents widget feedback from appearing as new user input (F-037, B-033).
public enum SelectionSource: Hashable, Sendable { case user, history, operation, widget }
