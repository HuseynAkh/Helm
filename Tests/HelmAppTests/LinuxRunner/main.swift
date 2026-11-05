// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest

XCTMain([
    testCase([("testSevenDocumentsFlushDespiteAnySingleFailure", asyncTest(SevenDocumentFlushTests.testSevenDocumentsFlushDespiteAnySingleFailure))]),
    testCase([("testAllocateAndReleaseFrameNames", FrameIdentityTests.testAllocateAndReleaseFrameNames), ("testRepairsReserveLaterValidFrameIdentities", FrameIdentityTests.testRepairsReserveLaterValidFrameIdentities)]),
    testCase([
        ("testColdRequestsWinAndReachFirstContents", LaunchTests.testColdRequestsWinAndReachFirstContents),
        ("testDefaultRestoreAndDisabledRestore", LaunchTests.testDefaultRestoreAndDisabledRestore),
        ("testInvalidRequestsDoNotSilentlyRestoreOrOpenHome", LaunchTests.testInvalidRequestsDoNotSilentlyRestoreOrOpenHome),
        ("testRestorationFallbackAndPreferences", LaunchTests.testRestorationFallbackAndPreferences),
        ("testLateOpenFrameNamesDoNotCollideWithRestoredWindows", LaunchTests.testLateOpenFrameNamesDoNotCollideWithRestoredWindows),
        ("testNonFileSessionLocationFallsBackWithoutAvailabilityLookup", LaunchTests.testNonFileSessionLocationFallsBackWithoutAvailabilityLookup),
        ("testRegistryMaintainsCreationAndActivationOrder", LaunchTests.testRegistryMaintainsCreationAndActivationOrder),
        ("testQuitWaitFlushFailureRetryAndCancel", LaunchTests.testQuitWaitFlushFailureRetryAndCancel)
    ]),
    testCase([
        ("testLiveMigrationPrecedesRegistrationAndRoundTrips", asyncTest(EnvironmentTests.testLiveMigrationPrecedesRegistrationAndRoundTrips)),
        ("testInvalidRootsAndMigrationFailureDoNotRegisterDefaults", asyncTest(EnvironmentTests.testInvalidRootsAndMigrationFailureDoNotRegisterDefaults)),
        ("testMemoryEnvironmentIsolationAndStoreBehaviour", asyncTest(EnvironmentTests.testMemoryEnvironmentIsolationAndStoreBehaviour)),
        ("testFlushAttemptsRemainingStoresAfterFailure", asyncTest(EnvironmentTests.testFlushAttemptsRemainingStoresAfterFailure))
    ])
])
