import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var description: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            if let description {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

struct InstallationRow: View {
    @EnvironmentObject private var model: XcodeViewModel
    let installation: XcodeInstallation

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: installation.appURL.path))
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.alias(for: installation).isEmpty ? installation.name : model.alias(for: installation)).font(.headline)
                    if installation.developerURL.path == model.activeDeveloperPath {
                        Text("当前激活").font(.caption).foregroundStyle(.green)
                    }
                    if model.isFavorite(installation) {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
                    }
                }
                Text(installation.displayVersion).font(.subheadline)
                if !model.alias(for: installation).isEmpty {
                    Text(installation.name).font(.caption).foregroundStyle(.secondary)
                }
                Text(installation.appURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([installation.appURL])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示")
            .accessibilityLabel("在 Finder 中显示 \(installation.name)")
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button(model.isFavorite(installation) ? "取消收藏" : "收藏") { model.toggleFavorite(installation) }
            Button("打开 Xcode") { model.select(installation); model.openSelectedXcode() }
            Button("打开终端") { model.openTerminal(for: installation) }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: XcodeViewModel
    @State private var isShowingSettings = false
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        TextField("搜索版本或路径", text: $model.filter)
                            .textFieldStyle(.roundedBorder)
                            .focused($isSearchFieldFocused)
                        Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                            .disabled(model.isRefreshing || model.isSwitching)
                            .help("重新扫描")
                    }
                    .padding(10)
                    if !model.installations.isEmpty {
                        List(selection: Binding(
                            get: { model.selectedID },
                            set: { selection in
                                // Clicking the empty area of a macOS List sends nil.
                                // Keep the current Xcode selected instead of replacing
                                // the detail pane with the empty-state view.
                                guard let selection,
                                      let installation = model.installations.first(where: { $0.id == selection }) else { return }
                                model.select(installation)
                            }
                        )) {
                            ForEach(model.filteredInstallations) { installation in
                                InstallationRow(installation: installation).tag(installation.id)
                            }
                        }
                    } else {
                        EmptyStateView(title: "未发现 Xcode", systemImage: "hammer", description: "请重新扫描，或在设置中添加搜索目录。")
                    }
                    HStack {
                        Text("\(model.installations.count) 个版本").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            isShowingSettings = true
                        } label: {
                            Label("项目设置…", systemImage: "gear")
                        }
                    }
                    .padding(10)
                }
                .frame(minWidth: 360, idealWidth: 410)

                Group {
                    if let installation = model.selectedInstallation {
                        XcodeDetailView(installation: installation)
                    } else {
                        EmptyStateView(title: "选择一个 Xcode", systemImage: "cursorarrow.click")
                    }
                }
                .frame(minWidth: 500)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack(spacing: 12) {
                Text(model.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(model.isError ? .red : .secondary)
                    .lineLimit(2)
                Spacer()
                if let selected = model.selectedInstallation {
                    Button {
                        model.toggleFavorite(selected)
                    } label: {
                        Image(systemName: model.isFavorite(selected) ? "star.fill" : "star")
                    }
                    .buttonStyle(.borderless)
                    .help("收藏当前版本")
                }
                Button(model.selectedInstallation.map { model.isActive($0) } == true ? "已激活" : "激活所选 Xcode") {
                    model.activateSelection()
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedInstallation == nil || model.selectedInstallation.map { model.isActive($0) } == true || model.isSwitching)
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            // SwiftUI may make the first TextField the window's first responder.
            // Keep the initial window neutral; the global shortcut explicitly
            // requests focus when the user wants to search.
            isSearchFieldFocused = false
            DispatchQueue.main.async {
                isSearchFieldFocused = false
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .task { model.refresh() }
        .onReceive(model.$installations) { installations in
            guard model.selectedInstallation == nil, let first = installations.first else { return }
            model.select(first)
        }
        .onReceive(model.$searchFocusRequest.dropFirst()) { _ in
            isSearchFieldFocused = true
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
                .environmentObject(model)
                .frame(width: 760, height: 600)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let url = object as? NSURL else { return }
                Task { @MainActor in model.addProject(url as URL) }
            }
            return true
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}

struct XcodeDetailView: View {
    @EnvironmentObject private var model: XcodeViewModel
    let installation: XcodeInstallation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: installation.appURL.path))
                        .resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(installation.name).font(.largeTitle.bold())
                        Text(installation.displayVersion).font(.title3).foregroundStyle(.secondary)
                        Text(installation.appURL.path).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                TextField("版本别名（可选）", text: Binding(
                    get: { model.alias(for: installation) },
                    set: { model.updateAlias(for: installation, value: $0) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)

                HStack {
                    Button(model.isActive(installation) ? "已激活" : "激活此版本") { model.activate(installation) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isActive(installation) || model.isSwitching)
                    Button("打开 Xcode") { model.openSelectedXcode() }
                    Button("打开终端") { model.openTerminal(for: installation) }
                }

                GroupBox("环境诊断") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.diagnostics(for: installation)) { item in
                            HStack(alignment: .top) {
                                Text(item.title).frame(width: 125, alignment: .leading).foregroundStyle(.secondary)
                                Text(item.value).textSelection(.enabled)
                                    .foregroundStyle(item.isWarning ? .orange : .primary)
                                Spacer()
                            }
                        }
                    }
                    .padding(4)
                }

                GroupBox("环境体检") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button(model.environmentReportsByID[installation.id] == nil ? "开始体检" : "重新体检") {
                                model.runEnvironmentDoctor(for: installation)
                            }
                            .disabled(model.isEnvironmentDoctorRunning(for: installation))
                            if model.isEnvironmentDoctorRunning(for: installation) {
                                ProgressView().controlSize(.small)
                                Text("正在检查工具链、License、Runtime、Simulator、Rosetta 和磁盘空间…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.environmentReportsByID[installation.id] != nil {
                                Button("复制报告") { model.copyEnvironmentReport(for: installation) }
                                Button("导出报告…") { model.exportEnvironmentReport(for: installation) }
                            }
                        }
                        if let report = model.environmentReportsByID[installation.id] {
                            Text("完成于 \(report.generatedAt.formatted(date: .abbreviated, time: .standard)) · \(report.issueCount) 项需要关注")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(report.checks) { check in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: environmentIcon(check.severity))
                                        .foregroundStyle(environmentColor(check.severity))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(check.title).font(.subheadline.weight(.medium))
                                        Text(check.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                        if let remediation = check.remediation {
                                            Text("建议：\(remediation)").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                    .padding(4)
                }

                GroupBox("Simulator Runtime") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let runtimes = model.runtimesByID[installation.id], !runtimes.isEmpty {
                            ForEach(runtimes) { runtime in
                                HStack {
                                    Image(systemName: runtime.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(runtime.isAvailable ? .green : .orange)
                                    Text(runtime.name)
                                    Text(runtime.version).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(runtime.isAvailable ? "可用" : "不可用").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } else if model.isLoadingDetails(for: installation) {
                            ProgressView("正在读取运行时…")
                        } else {
                            Text("未检测到 Simulator Runtime。")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button(model.hasAvailableRuntime(for: installation) ? "Runtime 已安装" : "下载 iOS Runtime") {
                                model.downloadRuntime()
                            }
                            .disabled(model.isDownloadingRuntime || model.hasAvailableRuntime(for: installation))
                            if model.isDownloadingRuntime {
                                Button("取消") { model.cancelRuntimeDownload() }
                            }
                            Button("打开 Xcode Settings") { model.openXcodeSettings(for: installation) }
                            if model.isDownloadingRuntime { ProgressView().controlSize(.small) }
                        }
                        if !model.runtimeDownloadProgress.isEmpty {
                            Text(model.runtimeDownloadProgress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(4)
                }
            }
            .padding(28)
        }
        .navigationTitle(installation.name)
    }

    private func environmentIcon(_ severity: EnvironmentCheckSeverity) -> String {
        switch severity {
        case .healthy: return "checkmark.circle.fill"
        case .informational: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func environmentColor(_ severity: EnvironmentCheckSeverity) -> Color {
        switch severity {
        case .healthy: return .green
        case .informational: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

struct MenuBarContentView: View {
    @EnvironmentObject private var model: XcodeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "hammer.fill")
                Text("Xcode Switcher").font(.headline)
                Spacer()
                if let active = model.activeInstallation { Text(active.displayVersion).font(.caption).foregroundStyle(.secondary) }
            }
            Divider()
            ForEach(model.installations) { installation in
                Button {
                    model.select(installation)
                    model.activate(installation)
                } label: {
                    HStack {
                        Image(systemName: installation.developerURL.path == model.activeDeveloperPath ? "checkmark.circle.fill" : "circle")
                        Text(installation.name)
                        Text(installation.displayVersion).foregroundStyle(.secondary)
                        Spacer()
                        if model.isFavorite(installation) { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.isActive(installation) || model.isSwitching)
            }
            if model.installations.isEmpty { Text("未发现 Xcode").foregroundStyle(.secondary) }
            Divider()
            HStack {
                Button("打开主窗口") { model.showMainWindow() }
                Button("重新扫描") { model.refresh() }
            }
            Text("全局快捷键：\(model.globalShortcutDisplayName)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 360)
        .task { if model.installations.isEmpty { model.refresh() } }
    }
}

struct ProjectsSettingsView: View {
    @EnvironmentObject private var model: XcodeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("项目绑定").font(.title2.bold())
                Spacer()
                Button("添加项目…") { addProject() }
            }
            Text("拖拽 .xcodeproj 或 .xcworkspace 到主窗口，也可以在这里添加。每个项目可以固定使用某个 Xcode。")
                .font(.subheadline).foregroundStyle(.secondary)
            if model.configuration.projects.isEmpty {
                EmptyStateView(title: "还没有项目", systemImage: "folder.badge.plus", description: "添加项目后可一键切换并打开。")
            } else {
                List {
                    ForEach(model.configuration.projects) { profile in
                        ProjectProfileRow(profile: profile)
                    }
                    .onDelete { offsets in
                        offsets.map { model.configuration.projects[$0] }.forEach(model.removeProject)
                    }
                }
            }
        }
        .padding(24)
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        // .xcodeproj and .xcworkspace are directory-based file packages. Keep
        // them selectable as files instead of letting the panel treat them as
        // directories that cannot be selected.
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            UTType("com.apple.xcode.project"),
            UTType("com.apple.dt.document.workspace")
        ].compactMap { $0 }
        if panel.runModal() == .OK { panel.urls.forEach(model.addProject) }
    }
}

struct ProjectProfileRow: View {
    @EnvironmentObject private var model: XcodeViewModel
    let profile: ProjectProfile
    @State private var name: String
    @State private var selectedXcodeID: String

    init(profile: ProjectProfile) {
        self.profile = profile
        _name = State(initialValue: profile.name)
        _selectedXcodeID = State(initialValue: profile.xcodeID ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: profile.path.hasSuffix("xcworkspace") ? "rectangle.3.group" : "shippingbox")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 5) {
                    TextField("项目名称", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { save() }
                    Text(profile.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Picker("Xcode", selection: $selectedXcodeID) {
                    Text("自动匹配 / 跟随当前").tag("")
                    if !selectedXcodeID.isEmpty,
                       !model.installations.contains(where: { $0.id == selectedXcodeID }) {
                        Text("绑定版本已丢失").tag(selectedXcodeID)
                    }
                    ForEach(model.installations) { installation in
                        Text("\(installation.name) \(installation.displayVersion)").tag(installation.id)
                    }
                }
                .frame(width: 240)
                Button("应用并打开") { model.applyAndOpen(profile) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.projectIssue(for: profile) != nil)
                Button { NSWorkspace.shared.activateFileViewerSelecting([profile.url]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
            }
            if let issue = model.projectIssue(for: profile) {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            } else if selectedXcodeID.isEmpty, let match = model.automaticMatch(for: profile), match.isInstalled {
                Label(
                    "根据 \(URL(fileURLWithPath: match.requirement.source).lastPathComponent) 自动匹配 Xcode \(match.requirement.normalizedVersion)",
                    systemImage: "wand.and.stars"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .onChange(of: name) { _ in save() }
        .onChange(of: selectedXcodeID) { _ in save() }
    }

    private func save() { model.updateProject(profile, name: name, xcodeID: selectedXcodeID.isEmpty ? nil : selectedXcodeID) }
}

struct SettingsView: View {
    @EnvironmentObject private var model: XcodeViewModel
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "hammer.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Xcode Switcher").font(.headline)
                    Text("管理 Xcode 版本与项目环境").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Picker("设置分类", selection: $selectedTab) {
                Text("通用").tag(SettingsTab.general)
                Text("项目").tag(SettingsTab.projects)
                Text("签名").tag(SettingsTab.signing)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .padding(.bottom, 16)

            Divider()

            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsView()
                case .projects:
                    ProjectsSettingsView()
                case .signing:
                    SigningSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 600)
    }
}

private enum SettingsTab: Hashable {
    case general
    case projects
    case signing
}

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: GlobalShortcut
    @Binding var isRecording: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.onCapture = { captured in
            DispatchQueue.main.async {
                shortcut = captured
                isRecording = false
            }
        }
        view.onRecordingChanged = { recording in
            DispatchQueue.main.async { isRecording = recording }
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        nsView.shortcut = shortcut
        nsView.isRecording = isRecording
        nsView.isEnabled = isEnabled
        nsView.needsDisplay = true
    }
}

final class ShortcutRecorderNSView: NSView {
    var shortcut = GlobalShortcut.default
    var isRecording = false { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }
    var onCapture: ((GlobalShortcut) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setAccessibilityRole(.button)
        setAccessibilityLabel("录制全局快捷键")
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isRecording = true
        onRecordingChanged?(true)
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        capture(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        capture(event)
        return true
    }

    private func capture(_ event: NSEvent) {
        if event.keyCode == 53 {
            isRecording = false
            onRecordingChanged?(false)
            window?.makeFirstResponder(nil)
            return
        }
        guard let captured = GlobalShortcut(event: event) else {
            NSSound.beep()
            return
        }
        onCapture?(captured)
        isRecording = false
        onRecordingChanged?(false)
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        let background = isRecording ? NSColor.controlAccentColor : NSColor.controlBackgroundColor
        (isEnabled ? background : NSColor.controlBackgroundColor.withAlphaComponent(0.5)).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(isEnabled ? 0.8 : 0.4).setStroke()
        path.lineWidth = 1
        path.stroke()

        let title = isRecording ? "请按下快捷键…" : shortcut.displayName
        let color = isRecording ? NSColor.white : (isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: color
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: max(10, (bounds.width - size.width) / 2), y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject private var model: XcodeViewModel
    @State private var isRecordingShortcut = false

    var body: some View {
        Form {
            Section("启动与更新") {
                Toggle("登录时启动", isOn: Binding(
                    get: { model.isLaunchAtLoginEnabled },
                    set: { model.toggleLaunchAtLogin($0) }
                ))
                Toggle("仅在菜单栏运行", isOn: Binding(
                    get: { model.configuration.menuBarOnly },
                    set: { model.toggleMenuBarOnly($0) }
                ))
                Toggle("自动检查更新", isOn: Binding(
                    get: { model.configuration.automaticallyChecksForUpdates },
                    set: { model.toggleAutomaticUpdateChecks($0) }
                ))
                .disabled(!model.isUpdateServiceAvailable)
                HStack {
                    Button("检查更新…") { model.checkForUpdates() }
                        .disabled(!model.isUpdateServiceAvailable)
                    Text(model.updateServiceMessage)
                        .font(.caption)
                        .foregroundStyle(model.isUpdateServiceAvailable ? Color.secondary : Color.orange)
                }
            }

            Section("快捷键") {
                Toggle("启用全局快捷键", isOn: Binding(
                    get: { model.configuration.globalShortcutEnabled },
                    set: { model.toggleGlobalShortcut($0) }
                ))
                HStack {
                    Text("快捷键组合")
                    Spacer()
                    ShortcutRecorderView(
                        shortcut: Binding(
                            get: { model.configuration.globalShortcut },
                            set: { model.updateGlobalShortcut($0) }
                        ),
                        isRecording: $isRecordingShortcut
                    )
                    .frame(width: 190, height: 30)
                    .disabled(!model.configuration.globalShortcutEnabled)
                }
                if model.configuration.globalShortcutEnabled && !model.isGlobalShortcutAvailable {
                    Label("需要在系统设置中允许 Xcode Switcher 使用辅助功能，然后重新打开 App。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("首次使用时，macOS 可能要求授予辅助功能权限。快捷键会唤起主窗口并聚焦搜索框。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("打开辅助功能设置") {
                    XcodeActions.openAccessibilitySettings()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        model.refreshGlobalShortcutPermission()
                    }
                }
            }
            Section("Xcode 搜索目录") {
                Text("默认扫描 /Applications、~/Applications 和 Spotlight；下面的目录会递归扫描。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.configuration.customSearchPaths, id: \.self) { path in
                    HStack {
                        Text(path).textSelection(.enabled)
                        Spacer()
                        Button { model.removeSearchPath(path) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("添加搜索目录…") { model.addSearchPath() }
            }
            Section("配置") {
                HStack {
                    Button("导入配置…") { model.importConfiguration() }
                    Button("导出配置…") { model.exportConfiguration() }
                }
                Text("配置包含收藏、项目绑定、搜索目录和快捷键开关。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

struct SigningSettingsView: View {
    @EnvironmentObject private var model: XcodeViewModel
    @State private var selectedProjectID: UUID?

    private var selectedProject: ProjectProfile? {
        model.configuration.projects.first { $0.id == selectedProjectID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("签名管理").font(.title2.bold())
                        Text("检查证书、Provisioning Profile 与项目签名配置。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.refreshSigning()
                        if let selectedProject {
                            model.refreshSigningReport(
                                for: selectedProject,
                                scheme: model.signingReport?.scheme,
                                configuration: model.signingReport?.configuration
                            )
                        }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRefreshingSigning)
                }

                GroupBox("项目签名诊断") {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.configuration.projects.isEmpty {
                            Text("还没有绑定项目，请先在“项目”页添加 .xcodeproj 或 .xcworkspace。")
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("项目", selection: $selectedProjectID) {
                                Text("选择项目").tag(UUID?.none)
                                ForEach(model.configuration.projects) { profile in
                                    Text(profile.name).tag(Optional(profile.id))
                                }
                            }
                            .onChange(of: selectedProjectID) { _ in
                                if let selectedProject { model.refreshSigningReport(for: selectedProject) }
                            }
                            if let selectedProject {
                                HStack {
                                    Text(selectedProject.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([selectedProject.url]) }
                                }
                                if let report = model.signingReport {
                                    if !report.availableSchemes.isEmpty || !report.availableConfigurations.isEmpty {
                                        HStack {
                                            if !report.availableSchemes.isEmpty {
                                                Picker("Scheme", selection: Binding(
                                                    get: { report.scheme ?? "" },
                                                    set: { model.refreshSigningReport(for: selectedProject, scheme: $0, configuration: report.configuration) }
                                                )) {
                                                    ForEach(report.availableSchemes, id: \.self) { Text($0).tag($0) }
                                                }
                                                .disabled(report.availableSchemes.count < 2)
                                            }

                                            if !report.availableConfigurations.isEmpty {
                                                Picker("Configuration", selection: Binding(
                                                    get: { report.configuration ?? "" },
                                                    set: { model.refreshSigningReport(for: selectedProject, scheme: report.scheme, configuration: $0) }
                                                )) {
                                                    ForEach(report.availableConfigurations, id: \.self) { Text($0).tag($0) }
                                                }
                                                .disabled(report.availableConfigurations.count < 2)
                                            }
                                        }
                                    }
                                }
                                SigningReportView(report: model.signingReport, isLoading: model.isLoadingSigningReport)
                            }
                        }
                    }
                    .padding(4)
                }

                GroupBox("签名证书（Keychain）") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("证书和私钥由 macOS 钥匙串管理，没有普通 Finder 文件路径。导出按钮只导出公钥 .cer，不会导出私钥。")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.isRefreshingSigning && model.signingCertificates.isEmpty {
                            ProgressView("正在读取钥匙串…")
                        } else if model.signingCertificates.isEmpty {
                            Text("未找到代码签名证书。请确认已在钥匙串中安装证书。")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.signingCertificates) { certificate in
                                HStack(spacing: 8) {
                                    Image(systemName: certificate.isValid ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(certificate.isValid ? .green : .orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(certificate.name)
                                        Text(certificate.fingerprint).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(certificate.isValid ? "有效" : "无效").font(.caption).foregroundStyle(.secondary)
                                    Button("导出并显示") { model.exportCertificate(certificate) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                        }
                        Button("打开钥匙串访问") { model.openKeychainAccess() }
                    }
                    .padding(4)
                }

                GroupBox("Provisioning Profiles") {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.provisioningProfiles.isEmpty {
                            Text("未找到本机 Provisioning Profile。")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.provisioningProfiles) { profile in
                                HStack(spacing: 8) {
                                    Image(systemName: profile.isExpired ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                        .foregroundStyle(profile.isExpired ? .orange : .green)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.name)
                                        Text("\(profile.appIdentifier) · Team \(profile.teamID)")
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(profile.isExpired ? "已过期" : "到期 \(profile.displayExpiration)")
                                        .font(.caption).foregroundStyle(profile.isExpired ? .orange : .secondary)
                                    Button("Finder") { SigningService.reveal(profile) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                        }
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("~/Library/MobileDevice/Provisioning Profiles")
                                Text("~/Library/Developer/Xcode/UserData/Provisioning Profiles")
                            }
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Spacer()
                            Button("打开目录") { model.revealProfilesFolder() }
                        }
                    }
                    .padding(4)
                }
            }
            .padding(24)
        }
        .task {
            model.refreshSigning()
            if selectedProjectID == nil, let first = model.configuration.projects.first {
                selectedProjectID = first.id
                model.refreshSigningReport(for: first)
            }
        }
    }
}

struct SigningReportView: View {
    let report: ProjectSigningReport?
    let isLoading: Bool

    var body: some View {
        if let report {
            VStack(alignment: .leading, spacing: 7) {
                if let errorMessage = report.errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                ForEach(report.targets) { target in
                    DisclosureGroup("\(target.targetName) · \(target.configurationName)") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(target.settings) { setting in
                                HStack(alignment: .top) {
                                    Text(setting.key).font(.caption).foregroundStyle(.secondary).frame(width: 220, alignment: .leading)
                                    Text(setting.value).font(.caption).textSelection(.enabled)
                                        .foregroundStyle(setting.isWarning ? .orange : .primary)
                                    Spacer()
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                }
            }
        } else if isLoading {
            ProgressView("正在读取项目签名配置…")
                .controlSize(.small)
        } else {
            Text("请选择项目以读取签名配置。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
