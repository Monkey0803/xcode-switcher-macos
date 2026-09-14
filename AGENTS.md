# Repository notes for agents

## Layout

- `Sources/` — the app; `SourcesCLI/` — the `xcodeswitcher` command line tool.
- `Tests/` — XCTest + Swift Testing suites.
- `XcodeSwitcher.xcodeproj` — **generated**. Run
  `python3 Scripts/generate_xcode_project.py` after changing targets, build
  settings or adding source files instead of editing the project file.
- `Resources/Localizable.xcstrings` — String Catalog (source language zh-Hans).

## Build and verify

```bash
xcodebuild -project XcodeSwitcher.xcodeproj -scheme "Xcode Switcher" \
  -configuration Debug -derivedDataPath build/DerivedData build test
./run_smoke_test.sh        # swift test + the script build path + packaged launch
```

The Xcode project, `Package.swift` and `build_app.sh` must all keep working;
see `docs/superpowers/plans/` for the migration notes and the constraints
behind the unusual build settings.

## SwiftUI `@State` (SDK 27)

SDK 27 turns `@State` into a macro, which changes what an initializer may do. In a
view that has an explicit `init`, declare `@State` **without** an initial value and
assign it in the `init`:

```swift
@State private var name: String                 // no initial value here
@State private var selectedXcodeID: String

init(profile: ProjectProfile) {
    self.profile = profile                      // other stored properties first
    _name = State(initialValue: profile.name)
    _selectedXcodeID = State(initialValue: profile.xcodeID ?? "")
}
```

Two traps, per Apple's SDK 27 guidance:

- `self.name = ...` in the `init` is a **silent** mistake, not a compile error —
  `body` keeps seeing the value from the declaration. Use `_name = State(initialValue:)`.
- Giving the declaration an initial value *and* assigning it in the `init` can fail
  to compile, or silently ignore the assignment. Reordering the assignments is not
  the fix; dropping the declarative initial value is.

Related, verified 2026-09-14: the `SwiftUIMacros.StateMacro could not be found`
errors that appear when building inside Homebrew's formula sandbox are
environmental — the sandbox blocks `swift-plugin-server`. Building outside it with
Xcode 26 **or** Xcode 27 succeeds, and all `@State` sites in `Sources/` follow the
shape above.

## Translations

Read [TRANSLATION.md](TRANSLATION.md) before adding or changing translations in
`Resources/Localizable.xcstrings`. It holds the glossary, the do-not-translate
list, the tone guidance and the placeholder rules. After editing, run
`./Scripts/sync_string_catalog.sh` and `./Scripts/verify_string_catalog.sh`.
