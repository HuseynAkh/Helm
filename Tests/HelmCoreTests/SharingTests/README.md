# Sharing regression tests — K37

Six XCTest methods exercise P15's value-only Sharing requirements and edge cases.
Run with the sourced Linux toolchain:

    swift test --scratch-path /tmp/build-K37 --filter SharingTests

See Sources/HelmCore/Sharing/README.md for policy and native integration limits.
Tests do not invoke system services or perform external actions.
