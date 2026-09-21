import Foundation
import os

/// Structured logging for the operations that are hard to diagnose from the UI alone.
///
/// Why it exists: a failure surfaces as one line in the status bar, and what a bug
/// report needs is the detail behind it — which path, which exit code, whether the
/// identifier was already gone. On 2026-09-21, diagnosing a failed
/// `simctl runtime delete` meant reading the code and re-running the command by hand,
/// because there was nothing in the log to consult.
///
/// The subsystem is the bundle identifier, so the whole app can be filtered at once:
///
///     log show --last 10m --predicate 'subsystem == "com.yostar.xcodeswitcher"' --info
///
/// Values are logged `privacy: .public` on purpose: this is a local developer tool and
/// the log is meant to be read by the person hitting the problem. The environment
/// report's redaction is a separate, shareable artifact.
public enum AppLog {
    /// One category per domain, named after the store that owns it.
    public enum Category: String, Sendable {
        /// The very first line of every run, so a report can be placed.
        case launch
        case switching
        case cleanup
        case runtime
        case release
        case projects
        case environment
        case settings
    }

    public static let subsystem = "com.yostar.xcodeswitcher"

    public static func logger(_ category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }
}
