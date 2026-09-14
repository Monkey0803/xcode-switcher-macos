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

    /// Runtimes live outside every Xcode bundle and routinely account for tens of
    /// gigabytes on their own.
    static func simulatorRuntimePaths(fileManager: FileManager = .default) -> [URL] {
        let directory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Profiles/Runtimes", isDirectory: true)
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { $0.pathExtension == "simruntime" }.sorted { $0.path < $1.path }
    }
}
