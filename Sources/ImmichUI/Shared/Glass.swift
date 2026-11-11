import ImmichKit
import SwiftUI

extension View {
    /// Liquid Glass on iOS 26 / macOS 26 (like the Photos app's floating buttons), a material before that.
    @ViewBuilder
    func photosGlass<S: Shape>(in shape: S, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

/// A round glass button with an SF Symbol, the shape of the Photos app's toolbar buttons.
struct GlassIconButton: View {
    let systemImage: String
    let label: String
    var size: CGFloat = 48
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .medium))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .photosGlass(in: Circle())
        .accessibilityLabel(label)
    }
}

#Preview("Glass buttons") {
    let _ = MockImmichService.preview
    HStack {
        GlassIconButton(systemImage: "chevron.left", label: "Back") {}
        GlassIconButton(systemImage: "heart", label: "Favorite") {}
    }
    .padding(40)
    .background(LinearGradient(colors: [.orange, .blue], startPoint: .top, endPoint: .bottom))
}
