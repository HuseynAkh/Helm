/// Navigation intent preserves history and Recent semantics (F-005, F-030).
public enum NavigationIntent: Hashable, Sendable { case push, back, forward, up, home, restore }
/// Selection origin prevents widget feedback from appearing as new user input (F-037, B-033).
public enum SelectionSource: Hashable, Sendable { case user, history, operation, widget }
