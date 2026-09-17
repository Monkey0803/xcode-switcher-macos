import AppKit
import SwiftUI

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
        query.apply(to: model.allReleases, installedBuilds: model.installedBuilds)
    }

    /// Looked up in the whole catalogue rather than the filtered list, so narrowing the
    /// filters does not blank a sidebar the user is reading.
    private var selectedRelease: XcodeReleaseInfo? {
        guard let selectedBuild else { return nil }
        return model.allReleases.first { $0.build == selectedBuild }
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

        case .loaded(let cachedAt, let refreshFailed):
            // A split view rather than a fixed 300 pt column: the two sides trade
            // width with the window, and the divider can be dragged.
            HSplitView {
                list(cachedAt: cachedAt, refreshFailed: refreshFailed)
                    .frame(minWidth: 420, maxWidth: .infinity)

                if !isDetailsCollapsed {
                    ReleaseInfoSidebar(release: selectedRelease)
                        .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
                }
            }
        }
    }

    @ViewBuilder
    private func list(cachedAt: Date?, refreshFailed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if refreshFailed, let cachedAt {
                Label(
                    "无法刷新，显示的是 \(cachedAt.formatted(date: .abbreviated, time: .shortened)) 的缓存副本。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .textRole(.warning)
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
                if let download = release.downloadURL {
                    Link("下载", destination: download).font(.subheadline)
                }
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
                if let download = release.downloadURL {
                    Link("下载", destination: download).font(.subheadline)
                }
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
