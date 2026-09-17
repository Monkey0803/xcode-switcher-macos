import SwiftUI

/// Every Xcode release in the community index, with the ones installed here marked.
///
/// The list is the whole index — 453 entries, 387 distinct builds — so it is
/// narrowed by a query rather than shown raw: filters for channel and installation
/// state, a search over version and build, and an order by version or release date.
/// It lives in its own window so the installed-Xcode detail pane stays usable next
/// to it.
struct AllVersionsView: View {
    @EnvironmentObject private var model: XcodeViewModel
    @State private var query = XcodeReleaseQuery()

    private var releases: [XcodeReleaseInfo] {
        query.apply(to: model.allReleases, installedBuilds: model.installedBuilds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            Divider()
            content
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { model.loadReleaseCatalog() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("搜索版本号或构建号", text: $query.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)

                Picker("渠道", selection: $query.channelScope) {
                    ForEach(XcodeReleaseQuery.ChannelScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .frame(width: 150)

                Picker("安装状态", selection: $query.installationScope) {
                    ForEach(XcodeReleaseQuery.InstallationScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .frame(width: 130)

                Spacer()
            }

            HStack(spacing: 10) {
                Picker("排序", selection: $query.sort) {
                    ForEach(XcodeReleaseQuery.Sort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                .frame(width: 150)

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
                    List(releases, id: \.build) { release in
                        row(for: release)
                    }
                    .listStyle(.inset)
                }
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
