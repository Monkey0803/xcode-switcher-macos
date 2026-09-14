import Foundation

/// Human-readable byte sizes. Pure, so the formatting is covered on every machine
/// even though the numbers it prints come from the filesystem.
enum DiskUsageFormatter {
    /// `du -k` reports kibibytes; the rest of the app talks in bytes.
    static func bytes(fromDuKilobytes kilobytes: Int64) -> Int64 {
        kilobytes * 1024
    }

    /// One decimal for gigabytes and up, none below, so the CLI columns stay
    /// readable without pulling in a locale-dependent formatter.
    static func humanReadable(bytes: Int64) -> String {
        let value = Double(max(bytes, 0))
        let units: [(threshold: Double, divisor: Double, suffix: String, decimals: Int)] = [
            (1_000_000_000_000, 1_000_000_000_000, "TB", 1),
            (1_000_000_000, 1_000_000_000, "GB", 1),
            (1_000_000, 1_000_000, "MB", 0),
            (1_000, 1_000, "KB", 0),
        ]
        for unit in units where value >= unit.threshold {
            return String(format: "%.\(unit.decimals)f %@", value / unit.divisor, unit.suffix)
        }
        return String(format: "%.0f B", value)
    }
}

/// Measures how much disk an Xcode installation or a simulator runtime occupies.
///
/// `du` rather than a `FileManager` walk: an Xcode bundle holds hundreds of
/// thousands of files, and enumeration there takes far longer than a single
/// process. Its output is parsed by a pure function, so the parsing is tested
/// without touching the filesystem.
enum DiskUsageReporter {
    struct Entry: Equatable, Sendable {
        let label: String
        let path: String
        let bytes: Int64
    }

    /// `du -sk <path>` prints one line: "<kibibytes>\t<path>".
    static func parseDuOutput(_ output: String) -> Int64? {
        guard let firstLine = output.split(whereSeparator: \.isNewline).first,
              let kilobytes = Int64(firstLine.split(whereSeparator: \.isWhitespace).first ?? "")
        else { return nil }
        return DiskUsageFormatter.bytes(fromDuKilobytes: kilobytes)
    }

    static func allocatedBytes(ofPath path: String) -> Int64? {
        guard let output = ProcessRunner.output(executable: "/usr/bin/du", arguments: ["-sk", path]) else {
            return nil
        }
        return parseDuOutput(output)
    }

    /// A simulator runtime as `simctl` reports it.
    struct SimulatorRuntime: Equatable, Sendable {
        let name: String
        /// Several seeds of the same version can be installed side by side, so the
        /// version alone does not identify an image — the build does.
        let build: String
        let path: String
        let bytes: Int64

        var label: String { build.isEmpty ? name : "\(name) (\(build))" }
    }

    /// `xcrun simctl runtime list -j` is a dictionary keyed by runtime identifier.
    /// It reports the bundle path *and* the size, which matters on current Xcode:
    /// newer runtimes are cryptex images mounted under
    /// `/Library/Developer/CoreSimulator/Volumes`, not directories inside
    /// `~/Library/Developer/CoreSimulator/Profiles/Runtimes`, so scanning that
    /// folder finds nothing at all.
    static func parseSimulatorRuntimes(_ json: String) -> [SimulatorRuntime] {
        struct Entry: Decodable {
            let runtimeBundlePath: String?
            let sizeBytes: Int64?
            let build: String?
        }
        guard let data = json.data(using: .utf8),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [] }
        return entries.values.compactMap { entry in
            guard let path = entry.runtimeBundlePath, let bytes = entry.sizeBytes else { return nil }
            let name = (path as NSString).lastPathComponent
                .replacingOccurrences(of: ".simruntime", with: "")
            return SimulatorRuntime(name: name, build: entry.build ?? "", path: path, bytes: bytes)
        }
        .sorted { $0.label < $1.label }
    }

    static func simulatorRuntimes() -> [SimulatorRuntime] {
        guard let output = ProcessRunner.output(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "runtime", "list", "-j"]
        ) else { return [] }
        return parseSimulatorRuntimes(output)
    }
}
