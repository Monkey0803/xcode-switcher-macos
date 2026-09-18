# Repository notes for agents

## Layout

- `Sources/XcodeSwitcherKit/` — the module the app and the CLI share;
  `Sources/XcodeSwitcher/` — the app (SwiftUI views, AppKit lifecycle, Sparkle);
  `SourcesCLI/` — the `xcodeswitcher` command line tool. The **directory is the
  target**: `Package.swift`, `Scripts/generate_xcode_project.py` and
  `build_app.sh` all read these three, so a new file belongs to whichever module
  its directory names — there is no list to update.
- `Tests/` — XCTest + Swift Testing suites. Test files that touch shared types
  need both `@testable import XcodeSwitcher` and `@testable import XcodeSwitcherKit`.
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

## Release artifacts and the cask checksum

`Casks/xcode-switcher.rb`'s `sha256` must come from the **published** Release, never
from a local `./build_local_release.sh` — the script is not reproducible across
machines. For v1.6.0 the same tag and build number produced
`8c2b8c5766ad265f…` locally and `958c6d6509f94ad619…` on the CI runner, so a
checksum taken from `release/local/` would make every `brew install --cask` fail.

Read it from the Release, and prefer re-hashing the downloaded asset over copying
`SHA256SUMS` blind:

```bash
gh release download v1.6.0 --dir /tmp --pattern "*-local.zip" --clobber
shasum -a 256 /tmp/Xcode-Switcher-1.6.0-6-local.zip   # 应等于 Release 里 SHA256SUMS 的对应行
```

Run that from inside the repository: `gh release download` needs a git context and
fails with `fatal: not a git repository` from `/tmp`.

Pushing a `v*` tag **is** the release action. `.github/workflows/release.yml` then
validates the tag against `Info.plist`, builds with `build_local_release.sh`, and
publishes the ZIP, DMG and `SHA256SUMS` itself. `build_release.sh` is the separate
notarized path that needs Developer ID and notary credentials, and is not part of it.

The post-release commit that bumps `Casks/` and `Formula/` must also bump the version
line under the README title — both `当前版本：…` and the previous stable release.
That step was dropped in v1.5.1 and again in v1.6.0, so the README advertised 1.5.0
two releases after it shipped. `9fd8a3d` (v1.5.0) is the only one that got it right
and is the model to copy.

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

## `sync_string_catalog.sh` and stale `.stringsdata`

`Scripts/sync_string_catalog.sh` decides a `.stringsdata` is stale by **mtime** and
skips it with a warning (`skipping stale <File>.stringsdata (source is newer; rebuild
the app target)`). That comparison produces a false alarm in **two** situations, both
verified 2026-09-18:

- The source's content is unchanged but its mtime moved — a `cp` of an identical file,
  a `git checkout` restoring the same content, a `touch` — so it is not recompiled.
- The source *did* change but its **extracted strings** did not (an edit that touches
  no string literal, e.g. renaming an enum case). The file is recompiled — its `.o`,
  `.d` and `.dia` all get fresh mtimes — while the `.stringsdata` output is reused from
  the build cache **without being rewritten**, so it keeps an old mtime. Observed:
  `ReleaseStore.o/.d/.dia` at 13:41:30 next to `ReleaseStore.stringsdata` still at
  12:27:11, after an edit that only changed a case label.

Either way the file's *content* is correct and only its mtime is old. What follows is a
false alarm that fails the catalog gate: every string that file contributes gets marked
`"extractionState": "stale"`, and `verify_string_catalog.sh` treats stale as a hard
error, so the gate goes red with the strings themselves perfectly fine.

Delete that file's **whole artifact set** (not just the `.stringsdata`) and rebuild:

```bash
find build/DerivedData/Build/Intermediates.noindex -name "ReleaseStore.*" -delete
xcodebuild -project XcodeSwitcher.xcodeproj -scheme "Xcode Switcher" \
  -configuration Debug -derivedDataPath build/DerivedData build
./Scripts/sync_string_catalog.sh   # 期望「已合并 N 个 .stringsdata」，且没有 skipping stale
```

Deleting only the `.stringsdata` is the trap: it does **not** make the build system
re-emit it — its database still counts that output as up to date — so the file stays
missing and those strings become *genuinely* stale. That is worse than the false alarm,
and it is how 5 keys ended up marked stale by hand during a session on 2026-09-18.
Afterwards `git diff -- Resources/Localizable.xcstrings` must be empty.

### Reading the two scripts' output

Both hide their bad news, so neither may be judged through a truncated pipe:

- `sync` prints the `skipping stale …` warning next to the merge count, so `tail -1`
  hides exactly it.
- `verify` prints its problem list to **stderr** and its counts to **stdout**. Under
  `2>&1 | tail -2` the unbuffered stderr is flushed *before* the block-buffered stdout,
  so `tail` shows the counts and hides the failure — and the pipeline's exit status is
  `tail`'s `0`, not the script's. Verified: a catalog with one manually stale key
  printed only the two count lines and reported success through that pipe, and exit 1
  when run directly.

Run them directly, or check the script's own exit code (with `set -o pipefail` if you
must pipe).
## The shared module has to stay an Xcode target

`XcodeSwitcherKit` is a target of the generated project, not a product of the local
package — and it has to be. Taking it from the package builds fine and looks
simpler, but a SwiftPM package target does not carry `SWIFT_EMIT_LOC_STRINGS`, so
every `String(localized:)` in the module (about a hundred, most in
`EnvironmentDoctor`) stops reaching `Resources/Localizable.xcstrings`. Verified
2026-09-18: with the package product, sync merged 10 `.stringsdata` instead of 17,
the catalog dropped to 444 keys and about 65 were marked stale.

Because the Kit owns strings, `Scripts/sync_string_catalog.sh` lists the target
directories it reads by name. A new target that owns localized strings has to be
added to that `find` expression too, or its keys silently leave the catalog.

## `XcodeViewModel` is a coordinator over stores

The view model used to own every domain at once (1574 lines, 41 `@Published`). Each
domain is now its own type, and the view model forwards to it:

| Store | Owns |
| --- | --- |
| `InstallationStore` | the installed Xcodes, their details, simulators and runtime downloads |
| `SigningStore` | signing identities, provisioning profiles, the signing report |
| `DiskCleanupStore` | disk cleanup, runtime sizes, runtime reclamation |
| `ReleaseStore` | the release index, per-installation build details, the update check |
| `EnvironmentStore` | environment checks and their reports |
| `ProjectStore` | project profiles, resolution, opening, the debounced edit |
| `SettingsStore` | the configuration, its persistence, and the settings built on it |

Three rules keep this from turning back into one big class:

- **Views and tests never change.** `XcodeViewModel` keeps same-named forwards and
  subscribes to each store's `objectWillChange` to re-publish, so the views still see a
  single `@EnvironmentObject`; the `init` parameters are forwarded rather than
  replaced, so tests keep constructing the model the way they always did.
- **A store never reaches back into the model.** Whatever it needs is injected at
  construction: a closure for a query or an action that belongs elsewhere, or the
  `StatusReporting` protocol for reporting a result. `ProjectStore` is the widest case
  — the profile list is shared with the configuration through a read/write closure
  pair instead of a second copy.
- **Split by concept, not by adjacency.** `diagnostics(for:)` sits next to the release
  lookup but renders installation facts, so it belongs to `InstallationStore`;
  `filteredInstallations` is installation state, but the search text the views bind to
  stays on the model and the store takes the query as an argument.

Reporting goes through `StatusReporting` on purpose. Folding `statusMessage = …` and
`isError = …` into one call was tried and rejected: the two statements are sometimes
reversed and sometimes separated by other work, so the protocol form — which keeps the
original assignment shape — is the reliable one.

Configuration is shared through `ConfigurationOwning` (the model conforms) rather than
one closure per key: the search folders, favourites and activation history belong to the
installation domain, the shortcuts and login item to the settings domain, and they live
in the same `AppConfiguration`.

Every domain has been extracted. What is left in `XcodeViewModel` is the composition
root: the store properties and their wiring, the same-named forwards, `onSearchPathsChanged`,
the four application commands (`requestSearchFocus`, `showMainWindow`, `showSettings`,
`showAllVersions`), and the one place that knows about all the stores — the reload that
runs after a refresh or a selection.

## Translations

Read [TRANSLATION.md](TRANSLATION.md) before adding or changing translations in
`Resources/Localizable.xcstrings`. It holds the glossary, the do-not-translate
list, the tone guidance and the placeholder rules. After editing, run
`./Scripts/sync_string_catalog.sh` and `./Scripts/verify_string_catalog.sh`.
