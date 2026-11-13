import SwiftUI
#if os(iOS)
import UIKit
#endif

extension View {
    /// A confirmation dialog for an asynchronous action (move to trash, restore).
    ///
    /// The dialog is shown while `isPending` is true. Dismissing it any other way than through
    /// the action button calls `onCancel`; once the action button is tapped, the dialog closing
    /// no longer counts as a cancel, so the pending items stay in place while `perform` runs.
    func confirmedAction(
        _ title: String,
        isPending: Bool,
        actionTitle: String,
        role: ButtonRole? = nil,
        message: String,
        onCancel: @escaping () -> Void,
        perform: @escaping () async -> Void
    ) -> some View {
        modifier(ConfirmedActionDialog(title: title, isPending: isPending, actionTitle: actionTitle, role: role,
                                       message: message, onCancel: onCancel, perform: perform))
    }

    /// An alert shown while `message` is non-nil, with a single OK button that calls `onDismiss`.
    func errorAlert(_ title: String, message: String?, onDismiss: @escaping () -> Void) -> some View {
        alert(title, isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { onDismiss() } }
        )) {
            Button(tr("OK"), role: .cancel) { onDismiss() }
        } message: {
            if let message { Text(message) }
        }
    }
}

private struct ConfirmedActionDialog: ViewModifier {
    let title: String
    let isPending: Bool
    let actionTitle: String
    let role: ButtonRole?
    let message: String
    let onCancel: () -> Void
    let perform: () async -> Void
    @State private var submitted = false

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: Binding(
            get: { isPending },
            set: { if !$0 && !submitted { onCancel() } }
        ), titleVisibility: .visible) {
            Button(actionTitle, role: role) {
                submitted = true
                Task {
                    await perform()
                    submitted = false
                }
            }
            Button(tr("Cancel"), role: .cancel) { onCancel() }
        } message: {
            Text(message)
        }
    }
}

#if os(iOS)
/// The system share sheet. `owner` (for example the object holding the prepared temporary
/// files) is retained until the sheet is gone, even if the view that presented it disappears.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    var owner: AnyObject?

    final class Coordinator {
        let owner: AnyObject?
        init(owner: AnyObject?) { self.owner = owner }
    }

    func makeCoordinator() -> Coordinator { Coordinator(owner: owner) }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

#Preview("Error alert") {
    Text(verbatim: "Bloom")
        .errorAlert(tr("Couldn't Share"), message: tr("The original file couldn't be downloaded. Please try again.")) {}
}
