import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import XcodeSwitcherKit

/// Prominent actions adopt Liquid Glass on macOS 26 and later; older systems keep
/// the previous bordered style. SwiftUI ships glass only as button styles on this
/// platform — `.glassEffect()` and `GlassEffectContainer` are not available for
/// macOS, where Liquid Glass is an AppKit feature.
private struct ProminentActionButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        // The decision is pure and tested in both directions; this call site can
        // only ever see the `true` one. See `AppearanceDecisions`.
        if #available(macOS 26.0, *),
           AppearanceDecisions.prominentButtonStyle(glassAvailable: true) == .glass {
            content.buttonStyle(.glassProminent)
        } else {
            // Must stay the concrete style: routing this back through
            // `prominentActionStyle()` would recurse forever on systems without
            // glass, which is the branch `glassAvailable: false` describes.
            content.buttonStyle(.borderedProminent)
        }
    }
}

extension View {
    func prominentActionStyle() -> some View {
        modifier(ProminentActionButtonStyle())
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var description: String?
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 34

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize))
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
            Image(nsImage: model.icon(for: installation))
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
                if let newer = model.newerRelease(for: installation) {
                    Label("有新版 \(newer.version)", systemImage: "arrow.up.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("发布索引里已有 \(newer.version)（\(newer.build)），本机是 \(installation.version)。")
                }
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
            Button("打开终端（注入 DEVELOPER_DIR）") { model.openTerminal(for: installation) }
            Button("复制 export DEVELOPER_DIR 命令") { model.copyDeveloperDirectoryExport(for: installation) }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: XcodeViewModel
    @FocusState private var isSearchFieldFocused: Bool
    /// Folding the list hands its width to the detail pane. The divider between the
    /// two panes stays draggable, so the button is a shortcut, not the only way to
    /// rebalance them.
    @State private var isListCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                if !isListCollapsed {
                    VStack(spacing: 0) {
                        HStack {
                            TextField("搜索版本或路径", text: $model.filter)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("xcode-search-field")
                                .focused($isSearchFieldFocused)
                            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                                .disabled(model.isRefreshing || model.isSwitching)
                                .help("重新扫描")
                                .accessibilityIdentifier("refresh-xcodes-button")
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
                            EmptyStateView(title: String(localized: "未发现 Xcode"), systemImage: "hammer", description: String(localized: "请重新扫描，或在设置中添加搜索目录。"))
                        }
                        HStack {
                            Text("\(model.installations.count) 个版本").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            // The window needs its own way in: the menu command is only
                            // reachable while the app is frontmost, which a menu bar utility
                            // usually is not.
                            Button {
                                model.showAllVersions()
                            } label: {
                                Label("所有版本…", systemImage: "list.bullet.rectangle")
                            }
                            .accessibilityIdentifier("all-versions-button")
                            .help("列出索引中的全部 Xcode 版本，可筛选与排序")
                            Button {
                                model.showSettings()
                            } label: {
                                Label("项目设置…", systemImage: "gear")
                            }
                        }
                        .padding(10)
                    }
                    .frame(minWidth: 360, idealWidth: 410)
                }

                Group {
                    if let installation = model.selectedInstallation {
                        XcodeDetailView(installation: installation)
                    } else {
                        EmptyStateView(title: String(localized: "选择一个 Xcode"), systemImage: "cursorarrow.click")
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
                    .accessibilityLabel(model.isFavorite(selected) ? "取消收藏 \(selected.name)" : "收藏 \(selected.name)")
                }
                Button(model.selectedInstallation.map { model.isActive($0) } == true ? "已激活" : "激活所选 Xcode") {
                    model.activateSelection()
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedInstallation == nil || model.selectedInstallation.map { model.isActive($0) } == true || model.isSwitching)
                    .accessibilityIdentifier("activate-selected-xcode-button")
                Button("回滚上一个") { model.rollbackToPreviousXcode() }
                    .accessibilityIdentifier("rollback-xcode-button")
                    .disabled(model.configuration.activationHistory.count < 2 || model.isSwitching)
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The title bar is where macOS puts a sidebar toggle. Icon only, as the
        // system apps do; the tooltip and the accessibility label carry the words.
        // The divider itself stays draggable, so this is a shortcut, not the only
        // way to rebalance the panes.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    isListCollapsed.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help(isListCollapsed ? "显示列表" : "隐藏列表")
                .accessibilityLabel(isListCollapsed ? "显示列表" : "隐藏列表")
                .accessibilityIdentifier("list-pane-toggle-button")
            }
        }
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
        .onReceive(model.installationsPublisher) { installations in
            guard model.selectedInstallation == nil, let first = installations.first else { return }
            model.select(first)
        }
        .onReceive(model.$searchFocusRequest.dropFirst()) { _ in
            isSearchFieldFocused = true
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            let viewModel = model
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let url = object as? NSURL else { return }
                Task { @MainActor in viewModel.addProject(url as URL) }
            }
            return true
        }
        .confirmationDialog(
            "项目推荐使用另一版本的 Xcode",
            isPresented: Binding(
                get: { model.pendingProjectOpen != nil },
                set: { if !$0 { model.cancelPendingProjectOpen() } }
            ),
            titleVisibility: .visible
        ) {
            Button("切换系统默认并打开") {
                model.switchAndOpenPendingProject()
            }
            Button("用推荐版本打开（不改系统设置）") {
                model.openPendingProjectWithRecommendedXcode()
            }
            Button("取消", role: .cancel) {
                model.cancelPendingProjectOpen()
            }
        } message: {
            if let request = model.pendingProjectOpen {
                Text("项目：\(request.profile.name)\n当前：\(request.currentInstallation.name) \(request.currentInstallation.displayVersion)\n推荐：\(request.recommendedInstallation.name) \(request.recommendedInstallation.displayVersion)\n依据：\(request.source.displayName)")
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}

struct XcodeDetailView: View {
    @EnvironmentObject private var model: XcodeViewModel
    let installation: XcodeInstallation

    /// One kind of information at a time.
    ///
    /// The pane used to be a single scroll of every section, which ran past 80 rows
    /// on this machine — the simulator device list alone is 27 — so seeing anything
    /// near the bottom meant a long scroll. Splitting it also gives the sections a
    /// home: actions, environment health, version facts, simulators, disk.
    private enum Category: String, CaseIterable, Identifiable {
        case overview
        case environment
        case version
        case simulators
        case cleanup

        var id: Self { self }

        var title: String {
            switch self {
            case .overview: return String(localized: "概览")
            case .environment: return String(localized: "环境")
            case .version: return String(localized: "版本与兼容")
            case .simulators: return String(localized: "模拟器")
            case .cleanup: return String(localized: "磁盘清理")
            }
        }
    }

    @State private var category: Category = .overview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The header and the category picker stay outside the scroll view, so
            // switching category never requires scrolling back to the top.
            header
            Divider()
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
        }
        .navigationTitle(installation.name)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: model.icon(for: installation))
                    .resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(installation.name).font(.title2.bold())
                    Text(installation.displayVersion).font(.caption).foregroundStyle(.secondary)
                    Text(installation.appURL.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
            }
            Picker("分类", selection: $category) {
                ForEach(Category.allCases) { category in
                    Text(category.title).tag(category)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch category {
        case .overview:
            VStack(alignment: .leading, spacing: 20) {
                TextField("版本别名（可选）", text: Binding(
                    get: { model.alias(for: installation) },
                    set: { model.updateAlias(for: installation, value: $0) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)

                GroupBox("系统级切换") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button(model.isActive(installation) ? "已激活" : "设为系统默认 Xcode") { model.activate(installation) }
                                .prominentActionStyle()
                                .disabled(model.isActive(installation) || model.isSwitching)
                            Button("打开 Xcode") { model.openSelectedXcode() }
                            Spacer()
                        }
                        Text("执行 xcode-select --switch，需要管理员授权，并会改变全机的开发者目录：所有终端、脚本与新开的 Xcode 都会受影响。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                GroupBox("不改系统设置（不需要管理员授权）") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button("打开已注入 DEVELOPER_DIR 的终端") { model.openTerminal(for: installation) }
                                .accessibilityIdentifier("open-developer-dir-terminal-\(installation.id)")
                            Button("复制 export 命令") { model.copyDeveloperDirectoryExport(for: installation) }
                                .help("复制 export DEVELOPER_DIR='…'，粘贴到任意终端即可让该会话使用这个 Xcode")
                            Spacer()
                        }
                        Text("只影响新打开的那个终端会话，不改 xcode-select。想让它在进入项目目录时自动生效，可在「设置 → Shell 集成」启用 zsh Hook。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }

        case .environment:
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("环境诊断") {
                    // A Grid sizes each column to its content instead of pinning a
                    // fixed width, so longer labels and larger text do not truncate.
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                        ForEach(model.diagnostics(for: installation)) { item in
                            GridRow {
                                Text(item.title).textRole(.fieldLabel)
                                Text(item.value).textSelection(.enabled)
                                    .textRole(.fieldValue, emphasis: item.isWarning ? AnyShapeStyle(Color.orange) : nil)
                                    .gridColumnAlignment(.leading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                GroupBox("环境体检") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button(model.environmentReportsByID[installation.id] == nil ? "开始体检" : "重新体检") {
                                model.runEnvironmentDoctor(for: installation)
                            }
                            .accessibilityIdentifier("environment-doctor-button-\(installation.id)")
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
                                Button("复制脱敏报告") { model.copyRedactedEnvironmentReport(for: installation) }
                                Button("导出脱敏报告…") { model.exportRedactedEnvironmentReport(for: installation) }
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
                                        Text(check.title).textRole(.itemTitle)
                                        Text(check.detail).textRole(.note).textSelection(.enabled)
                                        if let remediation = check.remediation {
                                            Text("建议：\(remediation)").textRole(.warning).textSelection(.enabled)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                    .padding(4)
                }
            }

        case .version:
            VersionInfoSectionView(installation: installation)

        case .simulators:
            RuntimeSectionView(installation: installation, download: model.runtimeDownload)

        case .cleanup:
            CleanupSectionView(installation: installation)
        }
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

/// One cleanup candidate — a row of `CleanupSectionView`.
///
/// Split out of that view's `body`: once the shared code moved into a separate
/// module, the single composite body exceeded the type-checker's budget and the
/// compiler asked for it to be broken up. This is the part carrying the most
/// expression, so it is the one that moved.
private struct CleanupEntryRow: View {
    @EnvironmentObject private var model: XcodeViewModel
    let entry: XcodeCleanupEntry
    let safety: XcodeCleanupSafety
    let xcodeRunning: Bool
    @Binding var entryToRemove: XcodeCleanupEntry?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: safety == .safe ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(safety == .safe ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label).textRole(.itemTitle)
                Text(entry.displaySize).textRole(.fieldValue)
                Text(entry.note).textRole(.note)
                Text(entry.path).textRole(.identifier).textSelection(.enabled)
            }
            Spacer()
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
            }
            .buttonStyle(.borderless)
            Button("清理") { entryToRemove = entry }
                .buttonStyle(.bordered)
                .disabled(xcodeRunning || model.isRemovingCleanupEntry(entry))
        }
        .padding(.vertical, 3)
    }
}

private struct CleanupSectionView: View {
    @EnvironmentObject private var model: XcodeViewModel
    let installation: XcodeInstallation
    @State private var entryToRemove: XcodeCleanupEntry?

    private var entries: [XcodeCleanupEntry] { model.cleanupEntries(for: installation) }
    private var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        // Sampled once per body. Inside the `ForEach` below this would enumerate
        // every running application again for each row.
        let xcodeRunning = model.isAnyXcodeRunning
        GroupBox("Xcode 磁盘清理") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("这些目录由所有 Xcode 版本共享。清理不会删除 Xcode.app、项目或签名文件。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("重新扫描") { model.loadCleanupEntries(for: installation, force: true) }
                        .disabled(model.isCleanupLoading(for: installation))
                }
                if xcodeRunning {
                    Label("检测到 Xcode 正在运行。请退出所有 Xcode 后再清理。", systemImage: "pause.circle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if model.isCleanupLoading(for: installation) {
                    ProgressView("正在扫描目录…")
                } else if entries.isEmpty {
                    Text("未发现可清理目录。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("共 \(entries.count) 个目录，可释放约 \(DiskUsageFormatter.humanReadable(bytes: totalBytes))。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(XcodeCleanupSafety.allCases) { safety in
                        let group = entries.filter { $0.safety == safety }
                        if !group.isEmpty {
                            Text(safety.title).font(.subheadline.weight(.semibold))
                            ForEach(group) { entry in
                                CleanupEntryRow(
                                    entry: entry,
                                    safety: safety,
                                    xcodeRunning: xcodeRunning,
                                    entryToRemove: $entryToRemove
                                )
                            }
                        }
                    }
                }
            }
            .padding(4)
        }
        .confirmationDialog(
            "确认清理目录？",
            isPresented: Binding(
                get: { entryToRemove != nil },
                set: { if !$0 { entryToRemove = nil } }
            ),
            presenting: entryToRemove
        ) { entry in
            Button("清理 \(entry.label)", role: .destructive) {
                model.removeCleanupEntry(entry)
                entryToRemove = nil
            }
            Button("取消", role: .cancel) { entryToRemove = nil }
        } message: { entry in
            Text("\(entry.displaySize)\n\(entry.note)")
        }
    }
}

/// What is known about one Xcode version: everything the installed bundle states
/// locally, plus — when the community release index can be reached — the release
/// date, the channel and the official SDK and toolchain versions.
private struct VersionInfoSectionView: View {
    @EnvironmentObject private var model: XcodeViewModel
    let installation: XcodeInstallation

    private var details: XcodeInstallDetails? { model.installDetails(for: installation) }
    private var release: XcodeReleaseInfo? { model.releaseInfo(for: installation) }

    /// Built as a property rather than inside the view builder: a mutating statement
    /// in an `if let` there is not a view, which the builder rejects.
    private var toolchainLabels: [String] {
        guard let release else { return [] }
        var values: [String] = []
        if let swift = release.swift { values.append("Swift \(swift.label)") }
        if let clang = release.clang { values.append("Clang \(clang.label)") }
        return values
    }

    var body: some View {
        GroupBox("版本详细信息") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    row("版本", installation.version, role: .fieldValueStrong)
                    row("构建", details?.build ?? installation.build, role: .identifier)
                    if let release, let date = release.releaseDateText() {
                        row("发布日期", "\(date) · \(release.channel.label)")
                    }
                    if let minimum = release?.minimumMacOS ?? details?.minimumMacOS {
                        row("最低 macOS", minimum)
                    }
                    if let platform = details?.platformVersion {
                        row("平台版本", platform, role: .identifier)
                    }
                    if let sdk = details?.sdkBuild {
                        row("iPhoneOS SDK 构建", sdk, role: .identifier)
                    }
                    row("安装路径", installation.appURL.path, role: .identifier)
                }

                if let release, !release.sdks.isEmpty {
                    detailList("随附 SDK", values: release.sdks.map(\.label))
                }
                if !toolchainLabels.isEmpty {
                    detailList("编译器", values: toolchainLabels)
                }

                upgradeNotice

                releaseStatus

                Button {
                    model.showAllVersions()
                } label: {
                    Label("所有版本…", systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("all-versions-button-detail")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func row(
        _ title: LocalizedStringKey,
        _ value: String,
        role: TextRole = .fieldValue
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .textRole(.fieldLabel)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .textRole(role)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func detailList(_ title: LocalizedStringKey, values: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .textRole(.fieldLabel)
                .frame(width: 130, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                // SDK builds and toolchain versions are read character by character,
                // so they get the monospaced identifier role.
                ForEach(values, id: \.self) { value in
                    Text(value).textRole(.identifier).textSelection(.enabled)
                }
            }
            Spacer()
        }
    }

    /// The release index knows a shipped release on this Xcode's own major line that
    /// is newer than the installed one.
    ///
    /// Deliberately a hint rather than an action: the app has no download path — see
    /// the "不做索引内下载安装" decision recorded in `docs/superpowers/plans/` — so the
    /// honest thing is to say what exists and leave the version window to it.
    @ViewBuilder
    private var upgradeNotice: some View {
        if let newer = model.newerRelease(for: installation) {
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "有新版本可用：\(newer.version)（\(newer.build)）",
                    systemImage: "arrow.up.circle.fill"
                )
                .textRole(.warning)
                Text("本机安装的是 \(installation.version)。")
                    .textRole(.note)
            }
        }
    }

    /// The release index is fetched automatically, so this reports how that went —
    /// distinguishing "still fetching" from "unreachable" from "showing a stale copy"
    /// rather than silently showing older data as current.
    @ViewBuilder
    private var releaseStatus: some View {
        switch model.releaseCatalogState {
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在获取发布信息…").textRole(.note)
            }
        case .loaded(let cachedAt, let failure):
            VStack(alignment: .leading, spacing: 4) {
                if let failure, let cachedAt {
                    Label(
                        "无法刷新，显示的是 \(cachedAt.formatted(date: .abbreviated, time: .shortened)) 的缓存副本。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .textRole(.warning)
                    Text(failure).textRole(.note)
                }
                if release == nil {
                    Text("发布信息索引里没有构建号 \(installation.build) 对应的条目。")
                        .textRole(.note)
                }
                if let release {
                    HStack(spacing: 12) {
                        if let notes = release.notesURL {
                            Link("发行说明", destination: notes).font(.subheadline)
                        }
                        if let download = release.downloadURL {
                            Link("下载", destination: download).font(.subheadline)
                        }
                        if !release.downloadArchitectures.isEmpty {
                            Text(release.downloadArchitectures.joined(separator: " / "))
                                .textRole(.identifier)
                        }
                        Spacer()
                    }
                }
            }
        case .unavailable(let message):
            Label("无法获取发布信息：\(message)", systemImage: "wifi.slash")
                .textRole(.warning)
        }
    }
}

private struct SimulatorDevicesView: View {
    @EnvironmentObject private var model: XcodeViewModel
    let installation: XcodeInstallation

    private enum PendingDeviceAction {
        case erase(SimulatorDevice)
        case delete(SimulatorDevice)
        case deleteUnavailable(Int)
    }

    /// Clone and rename differ only in the verb, so they share one dialog with a name
    /// field instead of growing two.
    private enum NamingRequest {
        case clone(SimulatorDevice)
        case rename(SimulatorDevice)

        var isClone: Bool {
            if case .clone = self { return true }
            return false
        }

        var dialogTitle: String {
            switch self {
            case .clone: return String(localized: "克隆 Simulator 设备")
            case .rename: return String(localized: "重命名 Simulator 设备")
            }
        }

        var confirmTitle: String {
            switch self {
            case .clone: return String(localized: "克隆")
            case .rename: return String(localized: "重命名")
            }
        }
    }

    @State private var pending: PendingDeviceAction?
    @State private var naming: NamingRequest?
    @State private var newName = ""
    @State private var isCreating = false

    private var devices: [SimulatorDevice] { model.simulatorDevices(for: installation) }
    private var unavailableCount: Int { devices.filter { !$0.isAvailable }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("Simulator 设备").font(.headline)
                Spacer()
                Button("新建…") {
                    model.loadSimulatorDeviceTypes(for: installation)
                    isCreating = true
                }
            }
            if devices.isEmpty {
                Text("未检测到 Simulator 设备。可在 Xcode 或 simctl 中创建。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(devices) { device in
                    HStack(spacing: 8) {
                        Image(systemName: device.isBooted ? "power.circle.fill" : "circle")
                            .foregroundStyle(device.isBooted ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).textRole(.itemTitle)
                            Text(device.state).textRole(.note)
                            if !device.isAvailable {
                                Text("当前 Xcode 不再支持，无法启动或抹掉。")
                                    .textRole(.warning)
                            }
                        }
                        Spacer()
                        if device.isBooted {
                            Button("关闭") { model.performSimulatorAction("shutdown", device: device, installation: installation) }
                        } else {
                            Button("启动") { model.performSimulatorAction("boot", device: device, installation: installation) }
                        }
                        Button("抹掉") { pending = .erase(device) }
                            .foregroundStyle(.red)
                        Button("删除") { pending = .delete(device) }
                            .foregroundStyle(.red)
                        Menu {
                            Button("克隆…") {
                                newName = String(localized: "\(device.name) 副本")
                                naming = .clone(device)
                            }
                            Button("重命名…") {
                                newName = device.name
                                naming = .rename(device)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    // Unavailable rows cannot boot, be erased or deleted through the
                    // per-device actions, which is exactly why they pile up; the bulk
                    // action below is the only way to remove them.
                    .disabled(!device.isAvailable)
                }
                if unavailableCount > 0 {
                    HStack(spacing: 8) {
                        Text("有 \(unavailableCount) 个设备已不被当前 Xcode 支持。")
                            .textRole(.note)
                        Spacer()
                        Button("删除不可用设备") { pending = .deleteUnavailable(unavailableCount) }
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .confirmationDialog(
            dialogTitle,
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            presenting: pending
        ) { action in
            switch action {
            case .erase(let device):
                Button("抹掉 \(device.name)", role: .destructive) {
                    model.performSimulatorAction("erase", device: device, installation: installation)
                    pending = nil
                }
            case .delete(let device):
                Button("删除 \(device.name)", role: .destructive) {
                    model.performSimulatorAction("delete", device: device, installation: installation)
                    pending = nil
                }
            case .deleteUnavailable:
                Button("删除不可用设备", role: .destructive) {
                    model.deleteUnavailableDevices(for: installation)
                    pending = nil
                }
            }
            Button("取消", role: .cancel) { pending = nil }
        } message: { action in
            switch action {
            case .erase:
                Text("这会删除设备中的应用和数据，且无法撤销。")
            case .delete:
                Text("这会永久删除该设备及其数据，且无法撤销。")
            case .deleteUnavailable(let count):
                Text("将永久删除 \(count) 个不被当前 Xcode 支持的设备，且无法撤销。")
            }
        }
        .alert(
            naming?.dialogTitle ?? "",
            isPresented: Binding(
                get: { naming != nil },
                set: { if !$0 { naming = nil } }
            ),
            presenting: naming
        ) { request in
            TextField("名称", text: $newName)
            Button(request.confirmTitle) {
                switch request {
                case .clone(let device):
                    model.cloneSimulatorDevice(device, newName: newName, installation: installation)
                case .rename(let device):
                    model.renameSimulatorDevice(device, newName: newName, installation: installation)
                }
                naming = nil
            }
            Button("取消", role: .cancel) { naming = nil }
        }
        .sheet(isPresented: $isCreating) {
            CreateSimulatorSheet(
                deviceTypes: model.simulatorDeviceTypes(for: installation),
                runtimes: model.runtimesByID[installation.id] ?? [],
                onCreate: { name, deviceType, runtime in
                    model.createSimulatorDevice(
                        name: name,
                        deviceType: deviceType,
                        runtime: runtime,
                        installation: installation
                    )
                    isCreating = false
                },
                onCancel: { isCreating = false }
            )
        }
    }

    private var dialogTitle: LocalizedStringKey {
        switch pending {
        case .erase: return "抹掉 Simulator 设备？"
        case .delete: return "删除 Simulator 设备？"
        case .deleteUnavailable: return "删除不可用 Simulator 设备？"
        case nil: return "Simulator 设备"
        }
    }
}

/// Creating a device needs a runtime and a device type, which is one picker more than an
/// alert holds, so it gets a small sheet of its own.
private struct CreateSimulatorSheet: View {
    let deviceTypes: [SimulatorDeviceType]
    let runtimes: [SimulatorRuntime]
    let onCreate: (String, SimulatorDeviceType, SimulatorRuntime) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var deviceTypeID: String?
    @State private var runtimeID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建 Simulator 设备").font(.headline)

            TextField("名称", text: $name, prompt: Text(selectedType?.name ?? String(localized: "名称")))
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)

            if runtimes.isEmpty {
                Text("当前 Xcode 没有可用的 Simulator 运行系统，请先下载一个再新建。")
                    .textRole(.note)
                    .frame(width: 320, alignment: .leading)
            } else if deviceTypes.isEmpty {
                Text("正在读取设备类型…")
                    .textRole(.note)
            } else {
                // The runtime reports which device types it can host, so the second picker
                // offers only those instead of all 130 of them.
                Picker("运行系统", selection: runtimeBinding) {
                    ForEach(runtimes) { runtime in
                        Text(runtime.name).tag(runtime.id)
                    }
                }
                .fixedSize()

                Picker("设备类型", selection: deviceTypeBinding) {
                    ForEach(compatibleTypes) { type in
                        Text(type.name).tag(type.id)
                    }
                }
                .fixedSize()
            }

            HStack {
                Spacer()
                Button("取消") { onCancel() }
                Button("创建") {
                    guard let type = selectedType, let runtime = selectedRuntime else { return }
                    onCreate(resolvedName, type, runtime)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedType == nil || selectedRuntime == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var selectedRuntime: SimulatorRuntime? {
        runtimes.first { $0.id == runtimeID } ?? runtimes.first
    }

    /// An empty `supportedDeviceTypes` means the runtime does not say, which is read as no
    /// restriction rather than as "nothing fits".
    private var compatibleTypes: [SimulatorDeviceType] {
        guard let runtime = selectedRuntime, !runtime.supportedDeviceTypes.isEmpty else { return deviceTypes }
        let supported = Set(runtime.supportedDeviceTypes)
        return deviceTypes.filter { supported.contains($0.id) }
    }

    private var selectedType: SimulatorDeviceType? {
        compatibleTypes.first { $0.id == deviceTypeID } ?? compatibleTypes.first
    }

    /// The typed name, or the device type's own name when it was left empty — creating a
    /// device requires a name, and making the user type one is busywork.
    private var resolvedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (selectedType?.name ?? "") : trimmed
    }

    private var runtimeBinding: Binding<String> {
        Binding(get: { selectedRuntime?.id ?? "" }, set: { runtimeID = $0 })
    }

    private var deviceTypeBinding: Binding<String> {
        Binding(get: { selectedType?.id ?? "" }, set: { deviceTypeID = $0 })
    }
}

/// Runtime images dominate a developer Mac's disk — each iOS runtime is several
/// gigabytes, and several seeds of one version can coexist. Per-image deletion uses
/// the size and `deletable` flag simctl reports; the bulk actions reuse simctl's own
/// selectors and preview them with simctl's `--dry-run`.
private struct RuntimeReclaimView: View {
    @EnvironmentObject private var model: XcodeViewModel
    let installation: XcodeInstallation

    private enum PendingReclaim {
        case deleteRuntime(DiskUsageReporter.SimulatorRuntime)
        case bulk(SimulatorRuntimeReclaim)
    }

    @State private var pending: PendingReclaim?

    private var runtimes: [DiskUsageReporter.SimulatorRuntime] { model.runtimeSizes(for: installation) }
    private var totalBytes: Int64 { runtimes.reduce(0) { $0 + $1.bytes } }

    /// simctl reports which images qualify but not how much they add up to, so the
    /// total is summed from the sizes the listing already carries.
    private func reclaimPreviewHeadline(_ preview: SimulatorRuntimeReclaimPreview) -> String {
        guard preview.resolvedCount > 0 else {
            return String(localized: "将清理 \(preview.lines.count) 项。")
        }
        return String(
            localized: "将清理 \(preview.resolvedCount) 个 Runtime，可回收约 \(DiskUsageFormatter.humanReadable(bytes: preview.totalBytes))。"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("Runtime 磁盘占用").font(.headline)
                Spacer()
                Button("重新测量") { model.loadRuntimeSizes(for: installation, force: true) }
                    .disabled(model.isLoadingRuntimeSizes(for: installation) || model.isReclaimingRuntimes)
            }

            if model.isLoadingRuntimeSizes(for: installation) {
                ProgressView("正在读取 Runtime…")
            } else if runtimes.isEmpty {
                Text("未检测到 Simulator Runtime。")
                    .textRole(.note)
            } else {
                Text("共 \(runtimes.count) 个 Runtime，占用约 \(DiskUsageFormatter.humanReadable(bytes: totalBytes))。")
                    .textRole(.note)
                ForEach(runtimes, id: \.identifier) { runtime in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(runtime.label).textRole(.itemTitle)
                            Text(DiskUsageFormatter.humanReadable(bytes: runtime.bytes))
                                .textRole(.fieldValue)
                            if let used = runtime.lastUsedAt {
                                Text("最近使用：\(used.formatted(date: .abbreviated, time: .omitted))")
                                    .textRole(.note)
                            }
                        }
                        Spacer()
                        Button("删除") { pending = .deleteRuntime(runtime) }
                            .foregroundStyle(.red)
                            .disabled(!runtime.isDeletable || model.isReclaimingRuntimes)
                    }
                }
            }

            Text("批量清理").font(.subheadline.weight(.semibold))
            Text("由 simctl 判断哪些镜像符合条件，预览即 simctl 的 --dry-run 输出。")
                .textRole(.note)
            ForEach(SimulatorRuntimeReclaim.allCases) { reclaim in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reclaim.title).textRole(.itemTitle)
                        Text(reclaim.note).textRole(.note)
                    }
                    Spacer()
                    Button("预览") { model.previewRuntimeReclaim(reclaim, for: installation) }
                        .disabled(model.isReclaimingRuntimes)
                    Button("清理") { pending = .bulk(reclaim) }
                        .foregroundStyle(.red)
                        .disabled(model.isReclaimingRuntimes)
                }
            }
            if model.isReclaimingRuntimes { ProgressView().controlSize(.small) }
            if let preview = model.runtimeReclaimPreview {
                VStack(alignment: .leading, spacing: 3) {
                    if preview.isEmpty {
                        Text("没有需要清理的 Runtime。")
                            .textRole(.note)
                    } else {
                        Text(reclaimPreviewHeadline(preview))
                            .textRole(.note)
                        // Resolved rows show the version, build and size; a line that
                        // could not be resolved is shown as simctl printed it rather
                        // than dropped, which would understate the removal.
                        ForEach(preview.lines) { line in
                            Text(line.summary)
                                .textRole(line.isResolved ? .identifier : .warning)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "确认清理 Runtime？",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            presenting: pending
        ) { action in
            switch action {
            case .deleteRuntime(let runtime):
                Button("删除 \(runtime.label)", role: .destructive) {
                    model.deleteRuntime(runtime, for: installation)
                    pending = nil
                }
            case .bulk(let reclaim):
                Button("清理\(reclaim.title)的 Runtime", role: .destructive) {
                    model.reclaimRuntimes(reclaim, for: installation)
                    pending = nil
                }
            }
            Button("取消", role: .cancel) { pending = nil }
        } message: { action in
            switch action {
            case .deleteRuntime(let runtime):
                Text("将删除 \(runtime.label)，占用约 \(DiskUsageFormatter.humanReadable(bytes: runtime.bytes))。该 Runtime 需要重新下载才能恢复。")
            case .bulk(let reclaim):
                Text("删除前可先用「预览」查看 simctl 将删除哪些镜像。\(reclaim.note)")
            }
        }
    }
}

/// Observes only the download state, which changes on every line of
/// `xcodebuild` output. Keeping it out of `XcodeDetailView` means a running
/// download no longer invalidates the whole detail pane on each chunk.
struct RuntimeSectionView: View {
    @EnvironmentObject private var model: XcodeViewModel
    let installation: XcodeInstallation
    @ObservedObject var download: RuntimeDownloadState

    var body: some View {
        GroupBox("Simulator Runtime") {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private var content: some View {
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
            .accessibilityIdentifier("download-runtime-button-\(installation.id)")
            .disabled(download.isDownloading || model.hasAvailableRuntime(for: installation))
            if download.isDownloading {
                Button("取消") { model.cancelRuntimeDownload() }
            }
            Button("打开 Xcode Settings") { model.openXcodeSettings(for: installation) }
            if download.isDownloading { ProgressView().controlSize(.small) }
        }
        if !download.progress.isEmpty {
            Text(download.progress)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
        }

        RuntimeReclaimView(installation: installation)

        SimulatorDevicesView(installation: installation)
    }
}

struct ProjectsSettingsView: View {
    @EnvironmentObject private var model: XcodeViewModel
    @State private var filter = ""

    private var visibleProjects: [ProjectProfile] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.configuration.projects }
        return model.configuration.projects.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.path.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("项目绑定").font(.title2.bold())
                Spacer()
                if !model.invalidProjects.isEmpty {
                    Button("清理失效项目") { model.removeInvalidProjects() }
                        .accessibilityIdentifier("remove-invalid-projects-button")
                }
                Button("添加项目…") { addProject() }
                    .accessibilityIdentifier("add-project-button")
            }
            Text("拖拽 .xcodeproj 或 .xcworkspace 到主窗口，也可以在这里添加。每个项目可以固定使用某个 Xcode。")
                .font(.subheadline).foregroundStyle(.secondary)
            TextField("搜索项目名称或路径", text: $filter)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("project-search-field")
            if model.configuration.projects.isEmpty {
                EmptyStateView(title: String(localized: "还没有项目"), systemImage: "folder.badge.plus", description: String(localized: "添加项目后可一键切换并打开。"))
            } else if visibleProjects.isEmpty {
                EmptyStateView(title: String(localized: "没有匹配的项目"), systemImage: "magnifyingglass", description: String(localized: "尝试搜索其他名称或路径。"))
            } else {
                List {
                    ForEach(visibleProjects) { profile in
                        ProjectProfileRow(profile: profile)
                    }
                    .onDelete { offsets in offsets.map { visibleProjects[$0] }.forEach(model.removeProject) }
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
                        .onSubmit { model.flushPendingProjectUpdate() }
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
                .frame(minWidth: 180, idealWidth: 240)
                Button("应用并打开") { model.applyAndOpen(profile) }
                    .prominentActionStyle()
                    .disabled(model.projectIssue(for: profile) != nil)
                    .accessibilityIdentifier("open-project-button-\(profile.id.uuidString)")
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
        // macOS 14 起 `onChange(of:perform:)`（单参数闭包）废弃；抬到 15 后它以
        // 废弃警告的形式被 `-warnings-as-errors` 拦下，改为两参数形式。
        .onChange(of: name) { _, _ in scheduleSave() }
        .onChange(of: selectedXcodeID) { _, _ in scheduleSave() }
        .onDisappear { model.flushPendingProjectUpdate() }
    }

    private func scheduleSave() {
        model.scheduleProjectUpdate(profile, name: name, xcodeID: selectedXcodeID.isEmpty ? nil : selectedXcodeID)
    }
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

/// Label that never swallows clicks, so the whole control stays clickable.
final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Custom control for recording a global shortcut.
///
/// macOS exposes Liquid Glass through AppKit (`NSGlassEffectView`); SwiftUI only
/// ships the glass *button styles* on this platform. From macOS 26 on the control
/// uses a glass background. The label lives in its own `NSTextField` because a
/// view's own `draw(_:)` output renders behind its subviews — the previous
/// implementation painted both the background and the text itself. Older systems
/// keep the hand-drawn rounded rectangle.
final class ShortcutRecorderNSView: NSView {
    var shortcut = GlobalShortcut.default {
        didSet {
            updateAccessibilityValue()
            updateTitle()
        }
    }
    var isRecording = false {
        didSet {
            needsDisplay = true
            updateAccessibilityValue()
            updateTitle()
            updateGlassTint()
        }
    }
    var isEnabled = true {
        didSet {
            needsDisplay = true
            updateTitle()
        }
    }
    var onCapture: ((GlobalShortcut) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    private let titleField = PassthroughLabel(labelWithString: "")
    private var glassBackground: NSView?
    private static let cornerRadius: CGFloat = 6

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleField.alignment = .center
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.setAccessibilityHidden(true)
        addSubview(titleField)
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // The control must stay a single accessibility element: the label is a
        // real NSTextField now, so without this AX would expose the bare shortcut
        // text instead of the recordable button.
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "录制全局快捷键"))
        updateAccessibilityValue()
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installGlassBackgroundIfAvailable()
    }

    /// Adds the Liquid Glass background on macOS 26 and later. Kept separate from
    /// `viewDidMoveToWindow` so it can be exercised without a window.
    func installGlassBackgroundIfAvailable() {
        guard AppearanceDecisions.shouldInstallGlass(
            glassAvailable: AppearanceDecisions.isGlassAvailable,
            alreadyInstalled: glassBackground != nil
        ) else { return }
        // Only the reference to the macOS 26 type needs the check itself.
        guard #available(macOS 26.0, *) else { return }
        let glass = NSGlassEffectView()
        glass.cornerRadius = Self.cornerRadius
        glass.style = .regular
        // `effectIsInteractive` (pointer/hover reaction) is macOS 27 only, and
        // using it would raise the *build* requirement to the macOS 27 SDK —
        // including for CI. Interactivity is deliberately left off so the project
        // builds with the macOS 26 SDK; see the migration notes for restoring it.
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        glassBackground = glass
        updateGlassTint()
        updateTitle()
    }

    private func updateGlassTint() {
        guard #available(macOS 26.0, *), let glass = glassBackground as? NSGlassEffectView else { return }
        glass.tintColor = isRecording ? .controlAccentColor : nil
    }

    private func updateTitle() {
        titleField.stringValue = isRecording
            ? String(localized: "请按下快捷键…")
            : shortcut.displayName
        // White reads on the filled accent fallback; the glass surface keeps the
        // standard label colour so it stays legible in both appearances.
        let usesGlass = glassBackground != nil
        switch AppearanceDecisions.shortcutTitleColor(
            isRecording: isRecording,
            usesGlass: usesGlass,
            isEnabled: isEnabled
        ) {
        case .white: titleField.textColor = .white
        case .label: titleField.textColor = .labelColor
        case .disabled: titleField.textColor = .disabledControlTextColor
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, !isRecording else { return false }
        beginRecording()
        return true
    }

    private func updateAccessibilityValue() {
        setAccessibilityValue(isRecording ? String(localized: "正在录制") : shortcut.displayName)
    }

    private func beginRecording() {
        isRecording = true
        onRecordingChanged?(true)
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        beginRecording()
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
        // The glass background covers this drawing on macOS 26 and later.
        guard glassBackground == nil else { return }
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        let background = isRecording ? NSColor.controlAccentColor : NSColor.controlBackgroundColor
        (isEnabled ? background : NSColor.controlBackgroundColor.withAlphaComponent(0.5)).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(isEnabled ? 0.8 : 0.4).setStroke()
        path.lineWidth = 1
        path.stroke()
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
                        .disabled(model.isCheckingRelease)
                    Button("打开 GitHub Releases") { model.openReleasePage() }
                    Text(model.updateServiceMessage)
                        .font(.caption)
                        .foregroundStyle(model.isError ? Color.orange : Color.secondary)
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
            Section("Shell 集成（不需要管理员授权）") {
                Text("在 zsh 中加入下面这行后，进入绑定了 Xcode 的项目目录会自动设置 DEVELOPER_DIR。它只影响当前 Shell，不会执行 xcode-select --switch，因此不需要授权，也不改变全机设置。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(XcodeViewModel.shellIntegrationCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("复制") { model.copyShellIntegrationCommand() }
                        .accessibilityIdentifier("copy-shell-integration-command")
                }
                Text("需要先把 App 内的 CLI 放到 PATH，例如链接到 ~/.local/bin：")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    // Show the path instead of the whole link command: that command
                    // is far wider than the settings window and would truncate.
                    Text(XcodeViewModel.cliExecutablePath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("复制链接命令") { model.copyCLILinkCommand() }
                        .accessibilityIdentifier("copy-cli-link-command")
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
                    Button("恢复上次备份") { model.restoreConfigurationBackup() }
                        .disabled(!model.hasConfigurationBackup)
                }
                if let saveError = model.configurationSaveError {
                    Label("配置保存失败：\(saveError)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("配置包含收藏、项目绑定、搜索目录、快捷键和最近切换记录；每次保存前会保留一份备份，历史备份最多保留 10 份。")
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
                            .onChange(of: selectedProjectID) { _, _ in
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
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                            ForEach(target.settings) { setting in
                                GridRow {
                                    Text(setting.key).font(.caption).foregroundStyle(.secondary)
                                        .gridColumnAlignment(.leading)
                                    Text(setting.value).font(.caption).textSelection(.enabled)
                                        .foregroundStyle(setting.isWarning ? .orange : .primary)
                                        .gridColumnAlignment(.leading)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
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
