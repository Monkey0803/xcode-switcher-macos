cask "xcode-switcher" do
  # Pinned to v1.3.0 on purpose. The v1.4.0 artifact published on 2026-09-11
  # crashes on launch: the `xcodebuild archive` release path signs the bundle in a
  # way that makes dyld reject the embedded Sparkle.framework — "mapping process
  # and mapped file (non-platform) have different Team IDs", then SIGABRT.
  # The script build path (`build_app.sh` + `Scripts/sign_bundle.sh`) is not
  # affected, which is why v1.3.0 launches. Move this back to 1.4.x once the
  # archive path re-signs with sign_bundle.sh and the result has been launched,
  # not merely verified with `codesign --verify`.
  version "1.3.0,1"
  sha256 "8a9fd41e66867b5b685f7be800d8dc2f4b72fef72e2c633ed7474e29d24192f2"

  url "https://github.com/Monkey0803/xcode-switcher-macos/releases/download/v#{version.csv.first}/Xcode-Switcher-#{version.csv.first}-#{version.csv.second}-local.zip"
  name "Xcode Switcher"
  desc "Discover, diagnose and switch between installed Xcode versions"
  homepage "https://github.com/Monkey0803/xcode-switcher-macos"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "Xcode Switcher.app"
  # A command wrapper, not a symlink: Foundation derives Bundle.main from the
  # invocation path, so a bare symlink in /opt/homebrew/bin makes the CLI miss the
  # app's String Catalog and silently fall back to the source language.
  command_wrapper "xcodeswitcher", executable: "#{appdir}/Xcode Switcher.app/Contents/MacOS/xcodeswitcher"

  caveats <<~EOS
    This build is ad-hoc signed and not notarized, so Gatekeeper blocks its first
    launch. Homebrew 6 no longer accepts `--no-quarantine`, so approve the app
    once under System Settings → Privacy & Security, or clear the attribute
    yourself after checking the download's SHA256SUMS:

      xattr -dr com.apple.quarantine "/Applications/Xcode Switcher.app"

    Until the app is approved, the bundled `xcodeswitcher` CLI is blocked as
    well: Gatekeeper kills every executable inside a quarantined bundle, and the
    failure is a silent `Killed: 9`.

    Homebrew refuses to replace an app it does not manage. To upgrade over an
    existing copy, add --force:

      brew install --cask --force #{token}
  EOS
end
