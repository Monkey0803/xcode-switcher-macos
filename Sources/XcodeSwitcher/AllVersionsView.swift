import AppKit
import SwiftUI
import XcodeSwitcherKit

/// Every Xcode release in the community index, with the ones installed here marked.
///
/// The list is the whole index — 453 entries, 387 distinct builds — so it is narrowed
/// by a query rather than shown raw: filters for channel and installation state, a
/// search over version and build, and an order by version or release date. Selecting a
/// row fills the sidebar with that release's version and compatibility facts. It lives
/// in its own window so the installed-Xcode detail pane stays usable next to it.
struct AllVersionsView: View {
    @EnvironmentObject private var model: XcodeViewModel
    @State private var query = XcodeReleaseQuery()
    @State private var selectedBuild: String?
    @FocusState private var isSearchFieldFocused: Bool
    /// Folding the facts sidebar hands its width to the list. The divider between the
    /// two panes stays draggable, so the button is a shortcut, not the only way to
    /// rebalance them.
    @State private var isDetailsCollapsed = false

    private var releases: [XcodeReleaseInfo] {
        query.apply(
            to: model.allReleases,
            installedBuilds: model.installedBuilds,
            incompatibleBuilds: incompatibleBuilds
        )
    }

    /// Releases this Mac cannot run at all, taken from the whole catalogue so the badges
    /// and the filter always agree. Only the blocking case counts — an x86_64-only build
    /// needs Rosetta 2 but does run here.
    private var incompatibleBuilds: Set<String> {
        Set(model.allReleases.filter { $0.hostCompatibility().isBlocking }.map(\.build))
    }

    /// Looked up in the whole catalogue rather than the filtered list, so narrowing the
    /// filters does not blank a sidebar the user is reading.
    private var selectedRelease: XcodeReleaseInfo? {
        guard let selectedBuild else { return nil }
        return model.allReleases.first { $0.build == selectedBuild }
    }

    /// The index is served from a copy cached for a day, so this only has to respect
    /// the in-flight state — pressing it while it loads would just restart the fetch.
    private var isRefreshingCatalog: Bool {
        if case .loading = model.releaseCatalogState { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            Divider()
            content
        }
        .frame(minWidth: 900, minHeight: 460)
        // Trailing, next to where macOS puts an inspector toggle: the pane it folds
        // lives on the right. Icon only, as the system apps do; the tooltip and the
        // accessibility label carry the words. The divider itself stays draggable.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isDetailsCollapsed.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help(isDetailsCollapsed ? "显示版本详情" : "隐藏版本详情")
                .accessibilityLabel(isDetailsCollapsed ? "显示版本详情" : "隐藏版本详情")
                .accessibilityIdentifier("release-details-toggle-button")
            }
        }
        .onAppear {
            model.loadReleaseCatalog()
            // Opening the window must not start a search. SwiftUI hands a new
            // window's first TextField the focus on appearance, which would leave
            // the query armed for the first keystroke; the list opens neutral, as
            // the main window does, and the field takes focus on a click.
            isSearchFieldFocused = false
            DispatchQueue.main.async {
                isSearchFieldFocused = false
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("搜索版本号或构建号", text: $query.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .accessibilityIdentifier("all-versions-search-field")
                    .focused($isSearchFieldFocused)

                // Next to the search field, as in the main window. The window opens
                // with whatever the day-long cache holds, so this is the only way to
                // ask for a fresh index without reopening it.
                Button { model.loadReleaseCatalog(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(isRefreshingCatalog)
                    .help("刷新版本列表")
                    .accessibilityLabel("刷新版本列表")
                    .accessibilityIdentifier("refresh-release-catalog-button")

                // Deliberately no fixed widths: a menu picker lays out its title and its
                // selected value side by side, so a width chosen in advance truncates the
                // value — 「已安装」 and 「未安装」 were both being elided to an ellipsis.
                Picker("渠道", selection: $query.channelScope) {
                    ForEach(XcodeReleaseQuery.ChannelScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .fixedSize()

                Picker("安装状态", selection: $query.installationScope) {
                    ForEach(XcodeReleaseQuery.InstallationScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .fixedSize()

                Picker("芯片", selection: $query.architectureScope) {
                    ForEach(XcodeReleaseQuery.ArchitectureScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .fixedSize()

                Spacer()
            }

            HStack(spacing: 10) {
                Picker("排序", selection: $query.sort) {
                    ForEach(XcodeReleaseQuery.Sort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                .fixedSize()

                Button {
                    query.direction = query.direction == .descending ? .ascending : .descending
                } label: {
                    Label(query.direction.title, systemImage: query.direction == .descending ? "arrow.down" : "arrow.up")
                }

                Toggle("显示 Xcode Tools", isOn: $query.includesTools)

                Toggle("隐藏本机无法运行的版本", isOn: $query.hidesIncompatible)

                Spacer()

                if case .loaded = model.releaseCatalogState {
                    Text("共 \(releases.count) / \(model.allReleases.count) 个版本")
                        .textRole(.note)
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch model.releaseCatalogState {
        case .idle, .loading:
            centered {
                ProgressView("正在获取版本列表…")
            }

        case .unavailable(let message):
            centered {
                VStack(spacing: 10) {
                    Label("无法获取版本列表：\(message)", systemImage: "wifi.slash")
                        .textRole(.warning)
                    Button("重新加载") { model.loadReleaseCatalog(force: true) }
                }
            }

        case .loaded(let cachedAt, let failure):
            // A split view rather than a fixed 300 pt column: the two sides trade
            // width with the window, and the divider can be dragged.
            HSplitView {
                list(cachedAt: cachedAt, failure: failure)
                    .frame(minWidth: 420, maxWidth: .infinity)

                if !isDetailsCollapsed {
                    ReleaseInfoSidebar(release: selectedRelease)
                        .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
                }
            }
        }
    }

    @ViewBuilder
    private func list(cachedAt: Date?, failure: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let failure, let cachedAt {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        "无法刷新，显示的是 \(cachedAt.formatted(date: .abbreviated, time: .shortened)) 的缓存副本。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .textRole(.warning)
                    // The error itself. A dropped connection and a rejected response
                    // are different problems, and the banner alone cannot tell them apart.
                    Text(failure).textRole(.note)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            if releases.isEmpty {
                centered {
                    Text("没有符合条件的版本。").textRole(.note)
                }
            } else {
                List(selection: $selectedBuild) {
                    ForEach(releases, id: \.build) { release in
                        row(for: release).tag(release.build)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func row(for release: XcodeReleaseInfo) -> some View {
        let installation = model.installation(matching: release)
        // An installed release shows its own bundle's icon; one that is not installed
        // here shows the same artwork taken from a locally installed Xcode.
        let icon = installation.map { model.icon(for: $0) } ?? model.xcodeIcon
        let installed = installation != nil
        return HStack(alignment: .top, spacing: 10) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "hammer").foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(release.version).textRole(.fieldValueStrong)
                    Text(release.channel.label).textRole(.note)
                    if installed {
                        Label("已安装", systemImage: "checkmark.circle.fill")
                            .textRole(.success)
                    } else if release.hostCompatibility().isBlocking {
                        // Only meaningful for something not installed here: an installed
                        // release is by definition one this Mac already runs.
                        Label("本机无法运行", systemImage: "exclamationmark.triangle.fill")
                            .textRole(.warning)
                    } else if case .needsRosetta = release.hostCompatibility() {
                        Label("需 Rosetta 2", systemImage: "info.circle")
                            .textRole(.note)
                    }
                }
                Text("构建 \(release.build)").textRole(.identifier)
                HStack(spacing: 8) {
                    if let date = release.releaseDateText() {
                        Text(date).textRole(.note)
                    }
                    if let minimum = release.minimumMacOS {
                        Text("需要 macOS \(minimum)").textRole(.note)
                    }
                }
            }

            Spacer()

            if !installed {
                if let notes = release.notesURL {
                    Link("发行说明", destination: notes).font(.subheadline)
                }
                DownloadLink(release: release)
            }
        }
        .padding(.vertical, 3)
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer()
            HStack { Spacer(); content(); Spacer() }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Version and compatibility facts for the release selected in the list.
///
/// Everything comes from the index; when the selected release is also installed here,
/// the bundle's own numbers are shown alongside so the two can be compared, and the
/// main window can be pointed at that installation.
/// The download affordance, the same in a row and in the facts sidebar.
///
/// It opens Apple's downloads page rather than the raw `.xip`: that URL needs a developer
/// session cookie, and without one Apple answers with a redirect to `/unauthorized/` — which
/// is what a direct link looked like to anyone not already signed in. The direct link stays
/// available, as its own visible control, for download managers and scripts.
private struct DownloadLink: View {
    let release: XcodeReleaseInfo

    var body: some View {
        HStack(spacing: 12) {
            if let page = release.downloadsPageURL {
                Link("下载", destination: page)
                    .help("在 Apple 开发者网站下载：需要登录并接受许可")
            }
            // A visible control rather than a context menu on the link: the right-click-only
            // version turned out to be undiscoverable in practice — the honest report was
            // 「没有看到」.
            if let direct = release.downloadURL {
                Button("复制直链") {
                    NSPasteboard.general.replaceContents(with: direct.absoluteString)
                }
                .buttonStyle(.link)
                .help(direct.absoluteString)
            }
        }
        .font(.subheadline)
    }
}

private struct ReleaseInfoSidebar: View {
    @EnvironmentObject private var model: XcodeViewModel
    let release: XcodeReleaseInfo?

    private var installation: XcodeInstallation? {
        guard let release else { return nil }
        return model.installation(matching: release)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let release {
                    summary(release)
                    facts(release)
                    if let installation {
                        localFacts(installation)
                        Button("在主窗口中显示") { model.select(installation) }
                    }
                    links(release)
                } else {
                    Text("选择一个版本查看详情。")
                        .textRole(.note)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    @ViewBuilder
    private func summary(_ release: XcodeReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(release.version).font(.title2.bold())
            HStack(spacing: 8) {
                Text(release.channel.label).textRole(.note)
                if installation != nil {
                    Label("已安装", systemImage: "checkmark.circle.fill")
                        .textRole(.success)
                }
            }
        }
    }

    @ViewBuilder
    private func facts(_ release: XcodeReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            field("构建", release.build, role: .identifier)
            if let date = release.releaseDateText() {
                field("发布日期", date)
            }
            if let minimum = release.minimumMacOS {
                field("最低 macOS", minimum)
            }
            if case .needsNewerOS(let required) = release.hostCompatibility() {
                field(
                    "本机兼容性",
                    String(localized: "需 macOS \(required)，本机为 \(XcodeReleaseInfo.runningOSDescription)")
                )
            } else if case .needsRosetta = release.hostCompatibility() {
                field("本机兼容性", String(localized: "需 Rosetta 2"))
            }
            if !release.downloadArchitectures.isEmpty {
                field("架构", release.downloadArchitectures.joined(separator: " / "), role: .identifier)
            }
            if !release.sdks.isEmpty {
                list("随附 SDK", values: release.sdks.map(\.label))
            }
            if !toolchainLabels(release).isEmpty {
                list("编译器", values: toolchainLabels(release))
            }
        }
    }

    /// Read from the bundle, next to the index's own numbers, so a mismatch is visible.
    @ViewBuilder
    private func localFacts(_ installation: XcodeInstallation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("本机安装").textRole(.sectionTitle)
            if let details = model.installDetails(for: installation) {
                if let platform = details.platformVersion {
                    field("平台版本", platform, role: .identifier)
                }
                if let sdk = details.sdkBuild {
                    field("iPhoneOS SDK 构建", sdk, role: .identifier)
                }
                if let minimum = details.minimumMacOS {
                    field("bundle 声明的最低 macOS", minimum)
                }
            }
            field("路径", installation.appURL.path, role: .identifier)
        }
    }

    @ViewBuilder
    private func links(_ release: XcodeReleaseInfo) -> some View {
        if release.notesURL != nil || release.downloadURL != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let notes = release.notesURL {
                    Link("发行说明", destination: notes).font(.subheadline)
                }
                DownloadLink(release: release)
            }
        }
    }

    private func toolchainLabels(_ release: XcodeReleaseInfo) -> [String] {
        var values: [String] = []
        if let swift = release.swift { values.append("Swift \(swift.label)") }
        if let clang = release.clang { values.append("Clang \(clang.label)") }
        return values
    }

    private func field(_ title: LocalizedStringKey, _ value: String, role: TextRole = .fieldValue) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).textRole(.fieldLabel)
            Text(value).textRole(role).textSelection(.enabled)
        }
    }

    private func list(_ title: LocalizedStringKey, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).textRole(.fieldLabel)
            ForEach(values, id: \.self) { value in
                Text(value).textRole(.identifier).textSelection(.enabled)
            }
        }
    }
}
