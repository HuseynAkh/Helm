import Foundation
import Testing
@testable import Helm

func registerNavigationStateTests() {
    TestRuntime.register("NavigationState back/forward") {
        let nav = NavigationState(initialURL: URL(fileURLWithPath: "/Users"))

        try Check.isTrue(!nav.canGoBack, "Back stack should start empty")
        try Check.isTrue(!nav.canGoForward, "Forward stack should start empty")

        nav.navigateTo(URL(fileURLWithPath: "/Users/test"))
        try Check.isTrue(nav.canGoBack, "Back stack should have one entry after navigation")
        try Check.isTrue(!nav.canGoForward, "Forward stack should remain empty after forward navigation")

        nav.goBack()
        try Check.isTrue(!nav.canGoBack, "Back stack should be empty after returning to the start")
        try Check.isTrue(nav.canGoForward, "Forward stack should have one entry after going back")
        try Check.equal(nav.currentURL.path, "/Users", "Current URL should be restored after going back")

        nav.goForward()
        try Check.isTrue(nav.canGoBack, "Back stack should be restored after going forward")
        try Check.isTrue(!nav.canGoForward, "Forward stack should be empty after consuming forward entry")
        try Check.equal(nav.currentURL.path, "/Users/test", "Current URL should be updated after going forward")
    }

    TestRuntime.register("NavigationState clears forward stack on new navigation") {
        let nav = NavigationState(initialURL: URL(fileURLWithPath: "/a"))
        nav.navigateTo(URL(fileURLWithPath: "/b"))
        nav.navigateTo(URL(fileURLWithPath: "/c"))
        nav.goBack()

        try Check.isTrue(nav.canGoForward, "Forward stack should contain one item after going back")

        nav.navigateTo(URL(fileURLWithPath: "/d"))
        try Check.isTrue(!nav.canGoForward, "Forward stack should be cleared after new navigation")
    }
}
