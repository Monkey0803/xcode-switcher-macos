# Verification status (2026-09-11):
#
#   * Resource and source fetching work, and the offline build path is verified:
#     with .build/artifacts removed and SPARKLE_FRAMEWORK_PATH set, build_app.sh
#     still produces a signed app whose CLI runs.
#   * The formula cannot be exercised on macOS 27 (Golden Gate), by either Xcode:
#       - with Xcode 27 active, the SDK 27 `@State` macro is expanded through
#         swift-plugin-server, which Homebrew's formula build sandbox refuses, so
#         the compiler reports "external macro implementation type
#         'SwiftUIMacros.StateMacro' could not be found";
#       - with Xcode 26 active, Homebrew itself refuses to build: on macOS 27 it
#         requires Xcode 27 ("Your Xcode (26.3) ... is too outdated"), and
#         HOMEBREW_DEVELOPER=1 does not bypass that check.
#     The `depends_on maximum_macos: :tahoe` cap below therefore turns this into a
#     clear "unsupported macOS" message instead of a confusing Xcode error. Use the
#     dedicated stanza: the string form `depends_on macos: "<= :tahoe"` is
#     deprecated, and Homebrew 6 fails outright on it.
#   * On macOS 26 with a matching Xcode the formula is expected to work, because
#     the macOS 26 SDK has no @State macro — but that combination could not be
#     verified here, since this machine runs macOS 27.
#
# On macOS 27 install the cask instead: Casks/xcode-switcher.rb.
class XcodeSwitcher < Formula
  desc "Discover, diagnose and switch between installed Xcode versions"
  homepage "https://github.com/Monkey0803/xcode-switcher-macos"
  license "MIT"
  # Pinned to the v2.0.0 tag through a revision rather than a release tarball:
  # GitHub's generated tag tarballs are not guaranteed to stay byte-stable, so a
  # git source with an explicit revision is the reproducible choice. Bumping this
  # matters for more than freshness: the formula builds with the tag's own
  # build_app.sh, and tags before v1.4.1 compile no String Catalog, so their
  # builds ship Chinese only.
  url "https://github.com/Monkey0803/xcode-switcher-macos.git",
      tag:      "v2.0.0",
      revision: "23d3ac0b06866fda4ba06cfe01949743308f5719"
  head "https://github.com/Monkey0803/xcode-switcher-macos.git", branch: "main"

  # The app is arm64 only, and building it needs the macOS 26 SDK because
  # NSGlassEffectView is a macOS 26 API that `#available` cannot guard at compile
  # time. Xcode 26.3 runs on macOS 15.6 and later.
  depends_on arch: :arm64
  depends_on macos: :sequoia
  depends_on maximum_macos: :tahoe
  depends_on xcode: ["26.0", :build]

  # Exactly the artifact Swift Package Manager fetches for the Sparkle binary
  # target; the checksum is the one declared in Sparkle's own Package.swift, and
  # matches `shasum -a 256` of the downloaded zip.
  resource "sparkle" do
    url "https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-for-Swift-Package-Manager.zip"
    sha256 "8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606"
  end

  def install
    # Formula builds run without network access, so hand build_app.sh the already
    # downloaded framework instead of letting it call `swift package resolve`.
    resource("sparkle").stage(sparkle_root = buildpath/"sparkle")
    framework = sparkle_root/"Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    odie "Sparkle.framework is missing from the staged artifact" unless framework.directory?

    ENV["SPARKLE_FRAMEWORK_PATH"] = framework.to_s
    system "./build_app.sh"

    prefix.install "build/Xcode Switcher.app"
    # Linked rather than copied so the CLI keeps resolving the app bundle, and
    # with it the String Catalog next to it.
    bin.install_symlink prefix/"Xcode Switcher.app/Contents/MacOS/xcodeswitcher" => "xcodeswitcher"
  end

  def caveats
    <<~EOS
      Xcode Switcher.app was installed inside the Homebrew prefix:
        #{opt_prefix}/Xcode Switcher.app
      Open it from there, or drag it into /Applications to keep it in the menu bar.

      This build is ad-hoc signed and not notarized, so the first launch from a
      downloaded copy needs approval in System Settings → Privacy & Security.
      Building from source as this formula does avoids that: the binary carries no
      quarantine attribute.
    EOS
  end

  test do
    assert_match "Xcode", shell_output("#{bin}/xcodeswitcher list")
    assert_match "developer=", shell_output("#{bin}/xcodeswitcher current")
  end
end
