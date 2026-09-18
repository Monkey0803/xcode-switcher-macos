import SwiftUI

/// One typographic role per kind of information.
///
/// Emphasis should follow what a piece of text *is*, not be re-chosen at every call
/// site. The detail pane had drifted to 67 uses of `.font(.caption)` out of roughly
/// 90 text styles, which meant size and weight no longer distinguished anything: a
/// field's label, its value and its footnote all rendered identically, and the whole
/// burden of showing importance fell on colour alone.
///
/// Two rules keep this honest:
///
/// * Every font is a **semantic** one (`.headline`, `.body`, `.caption`), never a
///   fixed point size, so the system's text-size setting still applies.
/// * Colour carries **meaning only**. `.secondary`/`.tertiary` de-emphasise, orange
///   asks for attention, red reports a failure, green confirms. Nothing here is
///   tinted for decoration.
enum TextRole {
    /// A group box heading.
    case sectionTitle
    /// The primary name of a row: a device, a runtime, a certificate.
    case itemTitle
    /// The key half of a key/value pair.
    case fieldLabel
    /// The value half of a key/value pair.
    case fieldValue
    /// The value the reader most likely came for: a version, a build number.
    case fieldValueStrong
    /// Explanatory text belonging to the row above it.
    case note
    /// A machine identifier: a path, a build string, a hash, a bundle identifier.
    /// Monospaced, because these are compared character by character rather than read.
    case identifier
    /// Something that needs attention but is not a failure.
    case warning
    /// Something that failed.
    case failure
    /// Something that passed.
    case success

    var font: Font {
        switch self {
        case .sectionTitle: return .headline
        case .itemTitle: return .body
        case .fieldLabel: return .caption
        case .fieldValue: return .body
        case .fieldValueStrong: return .body.weight(.semibold)
        case .note: return .caption
        case .identifier: return .caption.monospaced()
        case .warning, .failure, .success: return .caption
        }
    }

    /// `AnyShapeStyle` rather than `Color`: the hierarchy styles are what express
    /// de-emphasis, and mixing them with `Color` in one return type needs erasing.
    var style: AnyShapeStyle {
        switch self {
        case .sectionTitle, .itemTitle, .fieldValue, .fieldValueStrong:
            return AnyShapeStyle(.primary)
        case .fieldLabel, .note:
            return AnyShapeStyle(.secondary)
        case .identifier:
            return AnyShapeStyle(.tertiary)
        case .warning:
            return AnyShapeStyle(Color.orange)
        case .failure:
            return AnyShapeStyle(Color.red)
        case .success:
            return AnyShapeStyle(Color.green)
        }
    }
}

private struct TextRoleModifier: ViewModifier {
    let role: TextRole
    /// Applied only when the caller wants the role's own emphasis changed, which is
    /// how a value is shown as a problem without inventing a separate role.
    let overrideStyle: AnyShapeStyle?

    func body(content: Content) -> some View {
        content
            .font(role.font)
            .foregroundStyle(overrideStyle ?? role.style)
    }
}

extension View {
    /// Applies one of the semantic roles above.
    func textRole(_ role: TextRole, emphasis: AnyShapeStyle? = nil) -> some View {
        modifier(TextRoleModifier(role: role, overrideStyle: emphasis))
    }
}
