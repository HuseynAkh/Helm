/// Preserved caps from completion, Recent and directory batching (F-016, F-017, F-030, F-035).
public enum Limits {
    public static let completionCount: Int = 50
    public static let completionCacheSeconds: Double = 3
    public static let enumerationBatchSize: Int = 512
    public static let recentCount: Int = 180
    public static let recentRecordCount: Int = 300
}
