import Darwin
import XCTest
@testable import HelmAgent

/// The sign-in's listener, with a client in the test process that talks to it on 127.0.0.1. Nothing leaves this Mac.
final class AgentLoopbackListenerTests: XCTestCase {
    /// Sends `request` to 127.0.0.1:`port` and gives back what came back, up to the connection's close.
    private func send(_ request: String, to port: Int) -> String? {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var limit = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let joined = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard joined == 0 else { return nil }
        let bytes = Array(request.utf8)
        _ = bytes.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
        var reply = [UInt8](), buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            reply += buffer[0..<count]
        }
        return String(decoding: reply, as: UTF8.self)
    }

    private func get(_ target: String) -> String { "GET \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n" }

    func testItListensOnTheLoopbackAddressAloneOnAPortTheSystemPicks() throws {
        let listener = AgentLoopbackListener()
        let port = try listener.start()
        defer { listener.stop() }
        XCTAssertGreaterThan(port, 0)
        XCTAssertEqual(listener.boundAddressForTesting, "127.0.0.1", "bound to this Mac's loopback address and no other")
        let second = AgentLoopbackListener()
        defer { second.stop() }
        XCTAssertNotEqual(try second.start(), port, "each listener has its own port")
    }

    func testOnlyTheCallbackWithTheRightStateEndsTheWaitAndTheRestAreTurnedAway() async throws {
        let listener = AgentLoopbackListener()
        let port = try listener.start()
        let waiting = Task { try await listener.callback(path: "/auth/callback", timeout: 20) { $0["state"] == "right-state" } }
        let other = await Task.detached { self.send(self.get("/favicon.ico"), to: port) }.value
        XCTAssertTrue(other?.hasPrefix("HTTP/1.1 404") ?? false, other ?? "no reply")
        let forged = await Task.detached { self.send(self.get("/auth/callback?code=forged&state=wrong-state"), to: port) }.value
        XCTAssertTrue(forged?.hasPrefix("HTTP/1.1 400") ?? false, forged ?? "no reply")
        let posted = await Task.detached {
            self.send("POST /auth/callback?code=c&state=right-state HTTP/1.1\r\nContent-Length: 0\r\n\r\n", to: port)
        }.value
        XCTAssertTrue(posted?.hasPrefix("HTTP/1.1 400") ?? false, "only a GET is a callback")
        let twice = await Task.detached { self.send(self.get("/auth/callback?state=right-state&state=right-state"), to: port) }.value
        XCTAssertTrue(twice?.hasPrefix("HTTP/1.1 400") ?? false, "a field named twice is turned away")
        let right = await Task.detached {
            self.send(self.get("/auth/callback?code=test%2Dcode&state=right-state&scope=openid+email"), to: port)
        }.value
        let page = try XCTUnwrap(right)
        XCTAssertTrue(page.hasPrefix("HTTP/1.1 200 OK"), page)
        XCTAssertTrue(page.contains("You can close this tab and go back to Helm."))
        XCTAssertTrue(page.contains("Cache-Control: no-store"))
        XCTAssertTrue(page.contains("Content-Security-Policy: default-src 'none'"))
        let query = try await waiting.value
        XCTAssertEqual(query, ["code": "test-code", "state": "right-state", "scope": "openid email"])
        // Once the callback is in, nothing listens.
        let after = await Task.detached { self.send(self.get("/auth/callback?state=right-state"), to: port) }.value
        XCTAssertNil(after, "the port is closed")
        XCTAssertNil(listener.boundAddressForTesting)
    }

    func testTheWaitEndsAfterItsTimeAndWhenStopped() async throws {
        let slow = AgentLoopbackListener()
        _ = try slow.start()
        do {
            _ = try await slow.callback(path: "/auth/callback", timeout: 0.3) { _ in true }
            XCTFail("nothing came back")
        } catch {
            XCTAssertEqual(error as? AgentSignInFailure, .timedOut)
        }

        let stopped = AgentLoopbackListener()
        let port = try stopped.start()
        let waiting = Task { try await stopped.callback(path: "/auth/callback", timeout: 20) { _ in true } }
        try await Task.sleep(nanoseconds: 100_000_000)
        stopped.stop()
        do {
            _ = try await waiting.value
            XCTFail("a stopped listener hands nothing back")
        } catch {
            XCTAssertEqual(error as? AgentSignInFailure, .cancelled)
        }
        let after = await Task.detached { self.send(self.get("/auth/callback"), to: port) }.value
        XCTAssertNil(after)
        XCTAssertThrowsError(try stopped.start(), "a listener is made for one sign-in")
    }

    func testARequestHeadIsReadAsAGetWithItsPathAndQuery() {
        XCTAssertEqual(AgentCallbackRequest(head: "GET /auth/callback?a=1&b=two%20words HTTP/1.1\r\nHost: x"),
                       AgentCallbackRequest(head: "GET /auth/callback?b=two+words&a=1 HTTP/1.0"))
        XCTAssertEqual(AgentCallbackRequest(head: "GET /auth/callback?a=1 HTTP/1.1")?.query, ["a": "1"])
        XCTAssertEqual(AgentCallbackRequest(head: "GET /auth/callback HTTP/1.1")?.query, [:])
        XCTAssertEqual(AgentCallbackRequest(head: "GET /auth/callback?a=1 HTTP/1.1")?.path, "/auth/callback")
        XCTAssertNotNil(AgentCallbackRequest(head: "GET /auth/callback?a=1&a=2 HTTP/1.1"))
        XCTAssertNil(AgentCallbackRequest(head: "GET /auth/callback?a=1&a=2 HTTP/1.1")?.query, "a field named twice")
        XCTAssertNil(AgentCallbackRequest(head: "GET /auth/callback?a=%zz HTTP/1.1")?.query, "a broken escape")
        XCTAssertNil(AgentCallbackRequest(head: "POST /auth/callback HTTP/1.1"))
        XCTAssertNil(AgentCallbackRequest(head: "GET auth/callback HTTP/1.1"))
        XCTAssertNil(AgentCallbackRequest(head: "GET /auth/callback SPDY/3"))
    }
}
