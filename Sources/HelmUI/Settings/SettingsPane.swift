import SwiftUI
import HelmCore

/// Settings leaf categories regroup the legacy forms without changing keys (F-065).
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general = "General", view = "View", appearance = "Appearance", search = "Search", advanced = "Advanced"
    public var id: String { rawValue }
    /// The toolbar symbol, as in System Settings and Finder's own settings.
    public var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .view: return "square.grid.2x2"
        case .appearance: return "circle.lefthalf.filled"
        case .search: return "magnifyingglass"
        case .advanced: return "slider.horizontal.3"
        }
    }
    /// Each pane's height, so the window resizes to fit it without scrolling.
    public var height: CGFloat {
        switch self {
        case .general: return 540
        case .view: return 440
        case .appearance: return 364
        case .search: return 354
        case .advanced: return 536
        }
    }
}

/// Snapshot bindings emit intent only; the host owns persistence and refreshed snapshots (B-059).
public struct SettingsPaneView: View {
    let pane: SettingsPane
    let snapshot: SettingsSnapshot
    let supportsSingleClick: Bool
    #if os(macOS)
    let fileViewer: FileViewerModel?
    #endif
    let change: (SettingKey, SettingValue) -> Void
    #if os(macOS)
    public init(pane: SettingsPane, snapshot: SettingsSnapshot, supportsSingleClick: Bool = false, fileViewer: FileViewerModel? = nil,
                change: @escaping (SettingKey, SettingValue) -> Void) {
        self.pane = pane; self.snapshot = snapshot
        self.supportsSingleClick = supportsSingleClick; self.fileViewer = fileViewer; self.change = change
    }
    #else
    public init(pane: SettingsPane, snapshot: SettingsSnapshot, supportsSingleClick: Bool = false,
                change: @escaping (SettingKey, SettingValue) -> Void) {
        self.pane = pane; self.snapshot = snapshot
        self.supportsSingleClick = supportsSingleClick; self.change = change
    }
    #endif
    public var body: some View {
        Form {
            switch pane {
            case .general: general
            case .view: viewSettings
            case .appearance: appearance
            case .search: search
            case .advanced: advanced
            }
        }
        .formStyle(.grouped)
    }
    func bool(_ key: SettingKey) -> Binding<Bool> {
        Binding(get: { snapshot.bool(key) }, set: { change(key, .bool($0)) })
    }
    func string(_ key: SettingKey) -> Binding<String> {
        Binding(get: { snapshot.string(key) }, set: { change(key, .string($0)) })
    }
    func number(_ key: SettingKey) -> Binding<Double> {
        Binding(get: { snapshot.double(key) }, set: { change(key, .double($0)) })
    }
    func integer(_ key: SettingKey) -> Binding<Int> {
        Binding(get: { snapshot.integer(key) }, set: { change(key, .integer($0)) })
    }
    /// A caption under a section, in the system's secondary style.
    func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}
