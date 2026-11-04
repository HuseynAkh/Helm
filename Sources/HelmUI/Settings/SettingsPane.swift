// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import SwiftUI
import HelmCore

/// Settings leaf categories regroup the legacy forms without changing keys (F-065).
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general = "General", sidebar = "Sidebar", view = "View", search = "Search", advanced = "Advanced"
    public var id: String { rawValue }
}

/// Snapshot bindings emit intent only; the host owns persistence and refreshed snapshots (B-059).
public struct SettingsPaneView: View {
    let pane: SettingsPane
    let snapshot: SettingsSnapshot
    let supportsSingleClick: Bool
    let change: (SettingKey, SettingValue) -> Void
    public init(pane: SettingsPane, snapshot: SettingsSnapshot, supportsSingleClick: Bool = false,
                change: @escaping (SettingKey, SettingValue) -> Void) {
        self.pane = pane; self.snapshot = snapshot
        self.supportsSingleClick = supportsSingleClick; self.change = change
    }
    public var body: some View {
        Form {
            switch pane {
            case .general: general
            case .sidebar: sidebar
            case .view: viewSettings
            case .search: search
            case .advanced: advanced
            }
        }.padding(16)
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
}
