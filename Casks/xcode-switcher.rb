cask "xcode-switcher" do
  version "1.3.0,1"
  sha256 "8a9fd41e66867b5b685f7be800d8dc2f4b72fef72e2c633ed7474e29d24192f2"

  url "https://github.com/Monkey0803/xcode-switcher-macos/releases/download/v#{version.csv.first}/Xcode-Switcher-#{version.csv.first}-#{version.csv.second}-local.zip"
  name "Xcode Switcher"
  desc "Discover, diagnose and switch between installed Xcode versions"
  homepage "https://github.com/Monkey0803/xcode-switcher-macos"

  # The published builds are ad-hoc signed and deliberately not notarized, which
  # fails the Gatekeeper checks that the official homebrew/cask requires. This
  # cask therefore lives in a custom tap; see the caveats for what users hit.
  depends_on arch: :arm64
  depends_on macos: :ventura

  app "Xcode Switcher.app"
  # Link the CLI that ships inside the bundle, so `xcodeswitcher` lands on PATH.
  binary "#{appdir}/Xcode Switcher.app/Contents/MacOS/xcodeswitcher"

  caveats <<~EOS
    Xcode Switcher is ad-hoc signed and not notarized, so a quarantined copy is
    blocked by Gatekeeper on first launch. Either skip the quarantine attribute:

      brew install --cask --no-quarantine #{token}

    or approve it once under System Settings → Privacy & Security.

    The global shortcut additionally needs Accessibility permission for
    Xcode Switcher.
  EOS
end
