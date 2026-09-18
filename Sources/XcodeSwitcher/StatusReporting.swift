import Foundation

/// Where a store reports a user-visible result.
///
/// `XcodeViewModel` conforms by writing its own `statusMessage` and `isError`, so
/// the call sites inside a store keep the shape they had before the split —
/// `status?.statusMessage = …` next to `status?.isError = …`, in whatever order the
/// branch needs, including the many cases where the two are not adjacent. Pairing
/// them into one call was tried and rejected: the two statements are sometimes
/// reversed and sometimes separated by other work.
@MainActor
protocol StatusReporting: AnyObject {
    var statusMessage: String { get set }
    var isError: Bool { get set }
}
