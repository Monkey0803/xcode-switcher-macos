class XcodeSwitcher < Formula
  desc "Discover, diagnose and switch between installed Xcode versions"
  homepage "https://github.com/Monkey0803/xcode-switcher-macos"
  license "MIT"
  head "https://github.com/Monkey0803/xcode-switcher-macos.git", branch: "main"

  # Enable the stable URL once a release tarball exists — Homebrew needs the real
  # sha256 of the downloaded tarball, which can only be computed after tagging:
  #
  #   url "https://github.com/Monkey0803/xcode-switcher-macos/archive/refs/tags/v1.4.0.tar.gz"
  #   sha256 "..."
  #
  # Verify with: curl -sL <url> | shasum -a 256

  # The app is arm64 only, and building it needs the macOS 26 SDK because
  # NSGlassEffectView is a macOS 26 API that `#available` cannot guard at compile
  # time. Xcode 26.3 runs on macOS 15.6 and later.
  depends_on arch: :arm64
  depends_on macos: :sequoia
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
