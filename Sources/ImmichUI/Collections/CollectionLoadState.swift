import ImmichKit
import SwiftUI

/// The loading / error / empty ladder shared by the full Albums and People screens.
///
/// With no items it shows a spinner, an error with a retry button, or the empty state. With
/// items it shows `content`, preceded by a small error line with a retry button when a reload
/// failed. Placed in a stack, the error line and `content` are separate children of that stack.
struct CollectionLoadState<Content: View>: View {
    let isEmpty: Bool
    let isLoading: Bool
    let hasLoaded: Bool
    let error: String?
    let errorTitle: String
    let emptyTitle: String
    let emptySymbol: String
    let emptyDescription: String
    let retry: () async -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        if isEmpty {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
            } else if let error {
                ContentUnavailableView {
                    Label(errorTitle, systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    RetryButton(action: retry)
                }
            } else if hasLoaded {
                ContentUnavailableView(emptyTitle, systemImage: emptySymbol, description: Text(emptyDescription))
            }
        } else {
            if let error {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                    RetryButton(action: retry)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            content()
        }
    }
}

/// "Try Again" with a full-height tap target.
struct RetryButton: View {
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            Text(tr("Try Again"))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
    }
}

#Preview("Collection load error") {
    VStack(alignment: .leading, spacing: 24) {
        CollectionLoadState(isEmpty: true, isLoading: false, hasLoaded: true,
                            error: tr("Please try again."), errorTitle: tr("Can't Load Albums"),
                            emptyTitle: tr("No Albums"), emptySymbol: "rectangle.stack",
                            emptyDescription: tr("Albums you create in Immich appear here."),
                            retry: {}) { EmptyView() }
    }
    .padding()
}
