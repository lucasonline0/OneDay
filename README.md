# OneDay

**One day = one photo.**

OneDay is a private, local-first iPhone app that lets you capture exactly one photo for each local calendar day and browse your life as a minimal photographic timeline.

## MVP principles

- iPhone only, iOS 26+
- SwiftUI + SwiftData + AVFoundation
- no account, backend, analytics, ads, social layer, AI, filters, or photo-library import
- originals remain inside the app sandbox
- portable `.oneday` export/import for device migration

## Validation

The `feat/initial-mvp` branch is validated in CI on macOS 26 / Xcode 26.6:

- iOS Simulator build passes
- unit tests pass
- critical date, uniqueness, backup integrity, path-safety, and conflict-resolution logic is covered

Physical-device acceptance is still required for the real camera pipeline, haptics, visual camera morph, and the complete export/reinstall/import flow before the MVP is merged to `main`.
