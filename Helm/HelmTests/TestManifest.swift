import Testing

@_cdecl("helm_register_tests")
func helm_register_tests() {
    registerNavigationStateTests()
    registerFileSystemServiceTests()
    registerRecentItemsServiceTests()
    registerSearchRankingTests()
    registerStarredFilesServiceTests()
    registerFileManagerFlowTests()
}
