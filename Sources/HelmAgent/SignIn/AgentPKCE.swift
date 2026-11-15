import Foundation

/// The proof a ChatGPT sign-in carries that the code it exchanges is its own (PKCE, with S256): a verifier made of
/// random bytes, kept in memory for one sign-in, and its challenge, which goes to the browser.
public struct AgentPKCE: Sendable {
    /// 43 characters, from 32 random bytes.
    public let verifier: String
    public static let method = "S256"

    public init() { verifier = AgentSignInRandom.text() }
    /// A verifier given whole, for tests.
    init(verifier: String) { self.verifier = verifier }

    /// The verifier's SHA-256, in base64url with no padding.
    public var challenge: String { AgentBase64URL.encode(AgentSHA256.digest(Array(verifier.utf8))) }
}

/// Random text for a sign-in's state, nonce and PKCE verifier.
public enum AgentSignInRandom {
    /// `count` bytes from the system's random number generator, which on macOS is a cryptographically secure one.
    static func bytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    /// `count` random bytes as base64url text, 43 characters for the usual 32.
    public static func text(_ count: Int = 32) -> String { AgentBase64URL.encode(bytes(count)) }
}

/// Base64 with the address-safe alphabet and no padding, as tokens and PKCE write it.
enum AgentBase64URL {
    static func encode<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Nil for text with a character outside the alphabet, or a length no encoding gives.
    static func decode(_ text: String) -> Data? {
        guard text.unicodeScalars.allSatisfy(isAlphabet) else { return nil }
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        switch base.count % 4 {
        case 0: break
        case 2: base += "=="
        case 3: base += "="
        default: return nil
        }
        return Data(base64Encoded: base)
    }

    private static func isAlphabet(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
            || scalar == "-" || scalar == "_"
    }
}

/// SHA-256 (FIPS 180-4), written out because AI mode's module may import Foundation, Security and HelmCore alone and
/// none of them offers a plain digest. It makes the PKCE challenge and nothing else.
enum AgentSHA256 {
    static func digest(_ message: [UInt8]) -> [UInt8] {
        var hash: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var padded = message
        let bitCount = UInt64(message.count) &* 8
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { padded.append(UInt8(truncatingIfNeeded: bitCount >> UInt64(shift))) }

        var words = [UInt32](repeating: 0, count: 64)
        for block in stride(from: 0, to: padded.count, by: 64) {
            for index in 0..<16 {
                let at = block + index * 4
                var word = UInt32(padded[at]) << 24
                word |= UInt32(padded[at + 1]) << 16
                word |= UInt32(padded[at + 2]) << 8
                word |= UInt32(padded[at + 3])
                words[index] = word
            }
            for index in 16..<64 {
                let low = words[index - 15], high = words[index - 2]
                let sigma0 = rotate(low, 7) ^ rotate(low, 18) ^ (low >> 3)
                let sigma1 = rotate(high, 17) ^ rotate(high, 19) ^ (high >> 10)
                words[index] = words[index - 16] &+ sigma0 &+ words[index - 7] &+ sigma1
            }
            var a = hash[0], b = hash[1], c = hash[2], d = hash[3]
            var e = hash[4], f = hash[5], g = hash[6], h = hash[7]
            for index in 0..<64 {
                let sum1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choice = (e & f) ^ (~e & g)
                let first = h &+ sum1 &+ choice &+ rounds[index] &+ words[index]
                let sum0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let second = sum0 &+ majority
                h = g; g = f; f = e; e = d &+ first
                d = c; c = b; b = a; a = first &+ second
            }
            hash[0] = hash[0] &+ a; hash[1] = hash[1] &+ b; hash[2] = hash[2] &+ c; hash[3] = hash[3] &+ d
            hash[4] = hash[4] &+ e; hash[5] = hash[5] &+ f; hash[6] = hash[6] &+ g; hash[7] = hash[7] &+ h
        }
        return hash.flatMap { word in
            [UInt8(truncatingIfNeeded: word >> 24), UInt8(truncatingIfNeeded: word >> 16),
             UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word)]
        }
    }

    private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 { (value >> count) | (value << (32 - count)) }

    private static let rounds: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]
}
