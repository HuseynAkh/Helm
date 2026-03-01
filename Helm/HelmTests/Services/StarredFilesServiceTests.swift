import Foundation
import Testing
@testable import Helm

func registerStarredFilesServiceTests() {
    TestRuntime.register("StarredFilesService star and unstar flow") {
        let service = StarredFilesService()
        let url = URL(fileURLWithPath: "/tmp/helm-star-\(UUID().uuidString)")

        service.unstar(url: url)
        try Check.isTrue(!service.isStarred(url: url), "URL should start unstarred")

        service.star(url: url)
        try Check.isTrue(service.isStarred(url: url), "URL should be starred after star()")

        service.unstar(url: url)
        try Check.isTrue(!service.isStarred(url: url), "URL should be unstarred after unstar()")
    }

    TestRuntime.register("StarredFilesService toggle flow") {
        let service = StarredFilesService()
        let url = URL(fileURLWithPath: "/tmp/helm-toggle-\(UUID().uuidString)")

        service.unstar(url: url)
        service.toggleStar(url: url)
        try Check.isTrue(service.isStarred(url: url), "toggleStar should star an unstarred URL")

        service.toggleStar(url: url)
        try Check.isTrue(!service.isStarred(url: url), "toggleStar should unstar a starred URL")
    }
}
