import Foundation
import XcodeSwitcherKit

/// The persisted configuration and the object that owns it.
///
/// A store that owns part of the configuration mutates it through this instead of
/// taking one closure per key: the search folders, favourites and activation
/// history belong to the installation domain, the shortcuts and the login item to
/// the settings domain, and they all live in the same `AppConfiguration`.
@MainActor
protocol ConfigurationOwning: AnyObject {
    var configuration: AppConfiguration { get set }
    func persist()
}
