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

## Translations

Read [TRANSLATION.md](TRANSLATION.md) before adding or changing translations in
`Resources/Localizable.xcstrings`. It holds the glossary, the do-not-translate
list, the tone guidance and the placeholder rules. After editing, run
`./Scripts/sync_string_catalog.sh` and `./Scripts/verify_string_catalog.sh`.
