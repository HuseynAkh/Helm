// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
/// F-035 listings inspect metadata only; evicted cloud placeholders never trigger content reads.
/// Unknown also covers providers that do not report ubiquitous-item metadata.
public enum CloudAvailability: String, Hashable, Sendable, Codable {
    case local, evicted, downloading, unknown
}

