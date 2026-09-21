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
./Scripts/audit_unlocalized_strings.py   # 需要上面那次构建产出的 .stringsdata
```

The Xcode project, `Package.swift` and `build_app.sh` must all keep working;
see `docs/superpowers/plans/` for the migration notes and the constraints
behind the unusual build settings.

### Known environmental failure: Xcode 27 and the SwiftPM path

Verified 2026-09-21, with **Xcode 27.1 beta** as the active developer directory:
`swift build` / `swift test` — and therefore `run_smoke_test.sh` — fails while
compiling the CLI target,

```
error: unable to open dependencies file (…/xcodeswitcher-p.build/Objects-normal/arm64/CLIEntryPoint.d)
```

It is **not** caused by the change at hand: the same failure reproduces on a clean
tree (`git stash` the sources, `rm -rf .build/out`, rebuild). The same tree builds
with `Build complete!` and zero errors when the toolchain is pinned:

```bash
DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer ./run_smoke_test.sh
```

CI runs on `macos-26`, so the gate stays green there. Do not read a red `swift test`
on a machine whose active Xcode has been switched to 27 as a defect in the sources —
check `xcode-select -p` first, then re-run with `DEVELOPER_DIR` pinned.

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

`Scripts/sync_string_catalog.sh` skips a `.stringsdata` that no longer belongs to its
source and says so loudly (`skipping stale <File>.stringsdata (its recorded locations no
longer line up with the source; rebuild the app target)`). Merging a stale one would
resurrect keys that no longer exist, or — right after they are removed — strip keys that
still do.

**The decision is a content one, not an mtime one**, and that matters because mtime
produced a false alarm in two situations, both verified 2026-09-18:

- The source's content is unchanged but its mtime moved — a `cp` of an identical file,
  a `git checkout`/`stash` restoring the same content, a `touch` — so it is not
  recompiled.
- The source *did* change but its **extracted strings** did not (an edit that touches
  no string literal, e.g. renaming an enum case). The file is recompiled — its `.o`,
  `.d` and `.dia` all get fresh mtimes — while the `.stringsdata` output is reused from
  the build cache **without being rewritten**, so it keeps an old mtime.

Under the old mtime comparison, either case marked every string that file contributes as
`"extractionState": "stale"`, and `verify_string_catalog.sh` treats stale as a hard error
— the gate went red with the strings themselves perfectly fine. It did so twice on
2026-09-21 alone (204 keys once), which is why the comparison was replaced. The judgment
now lives in `Scripts/stringsdata_freshness.py`, shared with
`audit_unlocalized_strings.py` so the two gates cannot drift: a `.stringsdata` records
each key's `startingLine`/`startingColumn` (the column points at the literal's opening
quote, in **UTF-8 bytes**), and a file whose recorded positions all still land on a quote
still lines up with its source. Run it by hand when a sync looks wrong:

```bash
./Scripts/stringsdata_freshness.py build/DerivedData/…/ReleaseStore.stringsdata
# 0 = current；1 = 有文件被跳过（原因在 stderr）；2 = 没给参数
```

The ordering in CI is what makes the gate sound: the build runs first, so a source edit
that *did* change the extraction was already recompiled and re-extracted.

When a file really is out of date (or `sync` says it is), delete its **whole artifact
set** — not just the `.stringsdata` — and rebuild:

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

## `audit_unlocalized_strings.py` and the localization gate

`verify` and `sync` only ever look at strings that are *already* in the catalog, so
neither notices a Chinese literal written as a plain `String` — which is how about
forty user-visible strings stayed Chinese in the English UI until 2026-09-21.
`Scripts/audit_unlocalized_strings.py` closes that gap and runs in CI right after the
build. It compares the Chinese literals under `Sources/` and `SourcesCLI/` against the
`.stringsdata` the compiler wrote, whose location is the source of truth for "this
literal is localizable".

Three things about that data, each of which produced a round of false results:

- **`startingColumn` counts UTF-8 bytes, not characters.** A column that follows any
  CJK text is inflated by the extra bytes. On
  `.accessibilityLabel(isListCollapsed ? "显示列表" : "隐藏列表")` the second literal is
  at character column 50 and byte column 58, and only 58 matches the compiler.
- **mtime cannot be used as a freshness test.** A source whose *extracted strings* did
  not change gets its `.stringsdata` reused without being rewritten, so the file keeps
  an old mtime while staying perfectly correct — the same trap `sync` documents above.
  The judgment lives in `Scripts/stringsdata_freshness.py`, shared with `sync`: every
  recorded position must still land on the literal's opening quote, which catches the
  shifts that actually break the comparison.
- **The literal's own text excludes its interpolations.** In
  `"\(String(localized: "未知命令：\(command)"))\n\n\(Self.help)"` the Chinese belongs
  to the inner literal; a scanner that reports the outer one invents a problem. The
  scanner walks into interpolations and reports the inner literals separately.

A Chinese literal that is deliberately left alone is waived on its own line, and the
waiver count is printed rather than applied silently:

```swift
public static let unknownValue = "未知"  // unlocalized-audit:ok：参与相等比较的哨兵，只应在显示时本地化
```

A multi-line literal cannot carry a trailing comment, so the line above counts too —
that is where the AppleScript template's waiver sits.

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

### Assertions must not hard-code localized text

CI runs with an **English** locale while a developer machine is usually Chinese, so a
test that compares a localized message against its source text passes locally and fails
in CI. Reproduce CI's locale locally instead of guessing:

```bash
xcodebuild -project XcodeSwitcher.xcodeproj -scheme "Xcode Switcher" \
  -configuration Debug -derivedDataPath build/DerivedData test -testLanguage en
```

Two shapes are correct:

- **Compare against the same lookup**, `String(localized: "…")`. The key has to be the
  real one: spelling it with a value baked in (`…（退出码 1）。`) does not match the
  generated key (`…（退出码 %d）。` — `status` is an `Int32`), and a lookup that misses
  silently falls back to the source text, which is exactly the failure it was meant to
  avoid.
- **Compare against the same source of truth in code**, for example
  `XcodeTooling.deletionReason(result) == result.failureDescription`, which involves no
  lookup at all.

Both failure modes have been paid for: `eb443b3` (a substring assertion on 「另一个」)
and the CI run for `124b3cb` (two assertions on the newly localized GitHub Releases
messages, plus that hand-written key). Note that `-testLanguage en` also catches the
symmetric mistake — a fixture input that is a catalog key and would be translated under
the developer's own locale.
