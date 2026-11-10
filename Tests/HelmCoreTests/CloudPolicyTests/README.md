# CloudPolicy regression tests — K37

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04

Six XCTest methods exercise P15's value-only CloudPolicy requirements and edge cases.
Run with the sourced Linux toolchain:

    swift test --scratch-path /tmp/build-K37 --filter CloudPolicyTests

See Sources/HelmCore/CloudPolicy/README.md for policy and native integration limits.
Tests do not invoke system services or perform external actions.
