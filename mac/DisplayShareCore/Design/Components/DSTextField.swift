import SwiftUI

/// The Mac's one text field (Command 7 of the UI/UX audit).
///
/// `.roundedBorder` draws the system's field, which is light-grey chrome on a
/// dark surface and shares nothing with the receiver's inputs — the two apps
/// did not read as one product. This matches the receiver's `.ds-input`
/// exactly: 36px, 6px radius, a strong-border hairline on the raised surface,
/// and the same focus ring every other control uses.
public struct DSTextField: View {
    private let placeholder: String
    @Binding private var text: String
    private let onSubmit: (() -> Void)?

    @FocusState private var focused: Bool

    public init(_ placeholder: String, text: Binding<String>, onSubmit: (() -> Void)? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.onSubmit = onSubmit
    }

    public var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: DSFont.f3))
            .foregroundStyle(DSColor.text)
            .focused($focused)
            .onSubmit { onSubmit?() }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                    .fill(DSColor.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                    .strokeBorder(
                        focused ? DSColor.accent : DSColor.borderStrong,
                        lineWidth: 1
                    )
            )
            // The field draws its own ring rather than relying on the system's,
            // which `.plain` removes along with the border.
            .overlay(DSFocusRing(radius: DSRadius.sm, visible: focused))
            .animation(DSMotion.ease(), value: focused)
    }
}
