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

## `accessibilityIdentifier` and the accessibility tree

`bc08f77`'s message ends with the conclusion that SwiftUI "did not expose it as a
readable `AXIdentifier` on macOS, so this verification did not benefit from it".
**That does not hold for the running app.** Verified 2026-09-17 against the Debug
build, with the main window open:

```bash
osascript -e 'tell application "System Events" to tell (first process whose name is "XcodeSwitcherApp")' \
  -e 'set all to entire contents of window 1' \
  -e 'set acc to {}' \
  -e 'repeat with e in all' \
  -e 'try' \
  -e 'set v to (value of attribute "AXIdentifier" of e) as text' \
  -e 'if v is not "" and v is not "missing value" then set end of acc to v' \
  -e 'end try' \
  -e 'end repeat' \
  -e 'return acc' \
  -e 'end tell'
```

prints every identifier the sources set — `xcode-search-field`,
`refresh-xcodes-button`, `all-versions-button`, `activate-selected-xcode-button`,
`rollback-xcode-button`, `list-pane-toggle-button` and the per-installation
`open-developer-dir-terminal-…` — alongside SwiftUI's own `ListColumn` for the
`List`. `ToolbarItem` buttons are included.

Two ways to "disprove" this by accident:

- `repeat with e in (entire contents of window 1)` silently yields nothing. Assign
  `entire contents` to a variable first, as above.
- The window has to exist: `window 1` is whichever window is open, and the process
  is named `XcodeSwitcherApp` regardless of the bundle's display name.

Still untested: whether XCUITest's `XCUIElement` layer sees these identifiers —
this repository has no UI test target, so nothing exercises that path.

## Translations

Read [TRANSLATION.md](TRANSLATION.md) before adding or changing translations in
`Resources/Localizable.xcstrings`. It holds the glossary, the do-not-translate
list, the tone guidance and the placeholder rules. After editing, run
`./Scripts/sync_string_catalog.sh` and `./Scripts/verify_string_catalog.sh`.
