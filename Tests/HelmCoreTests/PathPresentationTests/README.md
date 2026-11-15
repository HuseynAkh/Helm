# PathPresentation regression tests — K37

Six XCTest methods exercise P15's value-only PathPresentation requirements and edge cases.
Run with the sourced Linux toolchain:

    swift test --scratch-path /tmp/build-K37 --filter PathPresentationTests

See Sources/HelmCore/PathPresentation/README.md for policy and native integration limits.
Tests do not invoke system services or perform external actions.
