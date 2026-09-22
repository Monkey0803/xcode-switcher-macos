cask "xcode-switcher" do
  # v1.4.0 was withdrawn: the `xcodebuild archive` release path signed the bundle
  # in a way that made dyld reject the embedded Sparkle.framework ("mapping process
  # and mapped file (non-platform) have different Team IDs") and the app died with
  # SIGABRT. It is kept as a GitHub pre-release with no assets, so /releases/latest
  # and the in-app update check both fall back to a working version. 1.4.1 fixes
  # the signing and also makes the release scripts launch the artifact before
  # publishing, so this cannot ship again unnoticed.
  version "2.1.1,9"
  sha256 "558dce64afa88d9a1643050e163a51343c9dc373f6e2ca7fffb1bfa6a870fdc4"

  url "https://github.com/Monkey0803/xcode-switcher-macos/releases/download/v#{version.csv.first}/Xcode-Switcher-#{version.csv.first}-#{version.csv.second}-local.zip"
  name "Xcode Switcher"
  desc "Discover, diagnose and switch between installed Xcode versions"
  homepage "https://github.com/Monkey0803/xcode-switcher-macos"

  depends_on arch: :arm64
  depends_on macos: :sequoia

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
