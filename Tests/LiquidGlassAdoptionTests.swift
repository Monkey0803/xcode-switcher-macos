import AppKit
import Testing
@testable import XcodeSwitcher

/// macOS adopts Liquid Glass through AppKit (`NSGlassEffectView`); SwiftUI only
/// ships the glass button styles here. These tests run the macOS 26 branch for
/// real on a current machine.
@MainActor
@Suite("Liquid Glass 适配")
struct LiquidGlassAdoptionTests {
    /// Matches by type name so the check itself does not require macOS 26, which
    /// would make the "no glass on older systems" expectation unverifiable.
    private func glassSubviews(of view: NSView) -> [NSView] {
        view.subviews.filter { String(describing: type(of: $0)) == "NSGlassEffectView" }
    }

    private func makeRecorder() -> ShortcutRecorderNSView {
        ShortcutRecorderNSView(frame: NSRect(x: 0, y: 0, width: 190, height: 30))
    }

    @Test("安装玻璃背景前后：macOS 26+ 有且仅有 1 个，更早系统为 0")
    func recorderUsesGlassBackgroundOnlyWhenAvailable() {
        let view = makeRecorder()
        #expect(glassSubviews(of: view).isEmpty, "安装前不应有玻璃视图")

        view.installGlassBackgroundIfAvailable()

        if #available(macOS 26.0, *) {
            #expect(glassSubviews(of: view).count == 1)
        } else {
            #expect(glassSubviews(of: view).isEmpty)
        }
    }

    @Test("重复安装不会叠加玻璃视图")
    func installingGlassIsIdempotent() {
        let view = makeRecorder()
        view.installGlassBackgroundIfAvailable()
        view.installGlassBackgroundIfAvailable()
        view.installGlassBackgroundIfAvailable()
        #expect(glassSubviews(of: view).count <= 1)
    }

    @Test("录制状态用玻璃着色表达，而不是重绘背景")
    func recordingTintsGlassSurface() throws {
        let view = makeRecorder()
        view.installGlassBackgroundIfAvailable()
        guard #available(macOS 26.0, *) else { return }
        let glass = try #require(glassSubviews(of: view).first as? NSGlassEffectView)
        #expect(glass.tintColor == nil)

        view.isRecording = true
        #expect(glass.tintColor != nil, "录制时应给玻璃加上强调色")

        view.isRecording = false
        #expect(glass.tintColor == nil)
    }

    @Test("控件自身是可访问元素，标签不单独暴露")
    func recorderExposesSingleAccessibilityElement() {
        let view = makeRecorder()
        #expect(view.accessibilityRole()?.rawValue == "AXButton")
        // accessibilityLabel() already returns String?; a cast here is a no-op
        // and fails the build under -warnings-as-errors.
        #expect(view.accessibilityLabel()?.isEmpty == false)
        #expect(view.accessibilityValue() != nil)
    }

    @Test("覆盖标签不吞掉点击")
    func passthroughLabelIgnoresHitTesting() {
        let label = PassthroughLabel(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        #expect(label.hitTest(NSPoint(x: 50, y: 10)) == nil)
    }
}
