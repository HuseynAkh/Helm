import Foundation

/// Preserves F-064 status labels and bullet spacing, with injected free space (B-058).
public enum StatusText {
    public static func format(itemCount: Int, selectedCount: Int = 0,
                              selectedBytes: Int64? = nil, freeBytes: Int64? = nil,
                              style: ByteCountText.Style = .decimal) -> String {
        let count = max(0, itemCount)
        var parts = [count == 1 ? "1 item" : "\(count) items"]
        if selectedCount > 0 {
            parts.append("\(selectedCount) selected")
            if let bytes = selectedBytes, bytes >= 0 { parts.append(ByteCountText.format(bytes, style: style)) }
        }
        if let bytes = freeBytes, bytes >= 0 { parts.append("\(ByteCountText.format(bytes, style: style)) free") }
        return parts.joined(separator: "  •  ")
    }
}
