# Apple Silicon Release Validation Design

## Goal

Prepare the current 1.2.0 work for release with documentation and automated checks that accurately describe an Apple Silicon-only application.

## Scope

- Update release documentation from the obsolete 1.0.0 checklist to 1.2.0.
- Declare Apple Silicon (`arm64`) as the sole supported architecture.
- Ensure build and smoke-test validation assert `arm64` rather than Universal Binary output.
- Run the strict CI-equivalent Swift test command and the full smoke test.

## Out of Scope

- Intel compatibility or `x86_64` validation.
- Actual Xcode selection, administrator authorization, Accessibility permission, Gatekeeper approval, and release installation validation. These require a real Apple Silicon Mac and user interaction.
- Signing, notarization, tagging, committing, or publishing a release.

## Implementation

Documentation will consistently identify 1.2.0 as the release candidate and Apple Silicon as the supported platform. Build and smoke-test scripts will retain their existing behavior except where their architecture configuration or assertions still require Universal Binary output.

## Verification

1. Run `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`.
2. Run `./run_smoke_test.sh`.
3. Inspect the final diff and verify no text claims Intel or Universal Binary support.
4. Record the Apple Silicon manual acceptance scenarios that remain for release operators.
