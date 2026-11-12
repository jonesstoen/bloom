import ImmichKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Observes selection per visible cell, without copying its ID set through the grid parent.
struct LibrarySelectableCell: View {
    let asset: Asset
    let model: LibraryGridModel
    let selection: LibrarySelectionModel
    let fillsCell: Bool
    let onOpen: (Asset) -> Void

    private var isSelected: Bool { selection.selectedIDs.contains(asset.id) }

    var body: some View {
        Button {
            if selection.isSelecting { selection.toggle(asset) }
            else { onOpen(asset) }
        } label: {
            ThumbnailCell(asset: asset, loader: model.loader, images: model.images, fillsCell: fillsCell)
                .overlay(alignment: .bottomTrailing) {
                    if selection.isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, isSelected ? Color.blue : Color.clear)
                            .background(isSelected ? Color.blue : Color.black.opacity(0.18), in: Circle())
                            .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                            .padding(5)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(selection.isBusy || selection.pendingTrashAssets != nil || selection.pendingRestoreAssets != nil)
        .accessibilityAddTraits(selection.isSelecting && isSelected ? .isSelected : [])
        .accessibilityValue(selection.isSelecting ? (isSelected ? tr("Selected") : tr("Not Selected")) : "")
    }
}

struct LibrarySelectionCount: View {
    let selection: LibrarySelectionModel

    var body: some View {
        Text(tr("%lld Selected", Int64(selection.selectedCount)))
            .font(.subheadline.weight(.semibold))
            .contentTransition(.numericText())
    }
}

struct LibrarySelectionCancelButton: View {
    let selection: LibrarySelectionModel

    var body: some View {
        Button(tr("Cancel")) { selection.cancel() }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .photosGlass(in: Capsule())
            .disabled(selection.isBusy || selection.pendingTrashAssets != nil || selection.pendingRestoreAssets != nil)
    }
}

struct LibrarySelectionToolbar: View {
    let selection: LibrarySelectionModel
    var allowsTrash = false
    var allowsRestore = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                if !allowsRestore {
                    Button { Task { await selection.prepareShare() } } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 20, weight: .medium))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(tr("Share"))
                    .disabled(selection.selectedCount == 0 || selection.isBusy || selection.pendingTrashAssets != nil || selection.pendingRestoreAssets != nil)
                }
                VStack(spacing: 3) {
                    if selection.isPreparingShare {
                        Text(tr("Preparing to Share…"))
                            .font(.subheadline.weight(.semibold))
                        Text(tr("%lld of %lld", Int64(selection.completedCount), Int64(selection.totalCount)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 6) {
                            if selection.isBusy { ProgressView().controlSize(.small) }
                            LibrarySelectionCount(selection: selection)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)

                if !allowsRestore {
                    Menu {
                        Button(tr("Add to Favorites"), systemImage: "heart") {
                            Task { await selection.setFavorites(true) }
                        }
                        Button(tr("Remove from Favorites"), systemImage: "heart.slash") {
                            Task { await selection.setFavorites(false) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 20, weight: .medium))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(tr("Favorite Actions"))
                    .disabled(selection.selectedCount == 0 || selection.isBusy || selection.pendingTrashAssets != nil || selection.pendingRestoreAssets != nil)
                }
                if allowsRestore {
                    Button { selection.requestRestore() } label: {
                        Label(tr("Restore"), systemImage: "arrow.uturn.backward")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                    .disabled(selection.selectedCount == 0 || selection.isBusy || selection.pendingRestoreAssets != nil)
                }
                if allowsTrash && !allowsRestore {
                    Button(role: .destructive) { selection.requestTrash() } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 20, weight: .medium))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(tr("Move to Trash"))
                    .disabled(selection.selectedCount == 0 || selection.isBusy || selection.pendingTrashAssets != nil || selection.pendingRestoreAssets != nil)
                }
            }
            if selection.isPreparingShare {
                Button(tr("Cancel Download")) { selection.cancelSharePreparation() }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .photosGlass(in: RoundedRectangle(cornerRadius: 28))
        .padding(.horizontal, 16)
    }
}

/// Keeps the prepared files alive until the system sheet has actually finished dismissing.
struct LibrarySelectionPresentation: ViewModifier {
    let selection: LibrarySelectionModel
    @State private var trashConfirmationSubmitted = false
    @State private var restoreConfirmationSubmitted = false
    @State private var presentedShare: SelectionShareItems?

    func body(content: Content) -> some View {
        content
            .onChange(of: selection.sharedFiles?.id) { _, id in
                if let id, let files = selection.sharedFiles {
                    presentedShare = SelectionShareItems(id: id, urls: files.urls)
                }
            }
            .sheet(item: $presentedShare, onDismiss: { selection.finishSharing() }) { items in
                #if os(iOS)
                LibraryActivityView(urls: items.urls)
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
                #else
                VStack(spacing: 20) {
                    ShareLink(items: items.urls) { Label(tr("Share"), systemImage: "square.and.arrow.up") }
                    Button(tr("Cancel")) { presentedShare = nil }
                }
                .padding(32)
                #endif
            }
            .confirmationDialog(tr("Move %@ items to Recently Deleted?",
                                   (selection.pendingTrashAssets?.count ?? 0).formatted(.number.locale(Localization.locale))),
                                isPresented: Binding(
                                    get: { selection.pendingTrashAssets != nil },
                                    set: { if !$0 && !trashConfirmationSubmitted { selection.cancelTrashConfirmation() } }
                                ), titleVisibility: .visible) {
                Button(tr("Move to Trash"), role: .destructive) {
                    trashConfirmationSubmitted = true
                    Task {
                        await selection.confirmTrash()
                        trashConfirmationSubmitted = false
                    }
                }
                Button(tr("Cancel"), role: .cancel) { selection.cancelTrashConfirmation() }
            } message: {
                Text(tr("You can recover these items from Recently Deleted in Immich until your server removes them."))
            }
            .confirmationDialog(tr("Restore %@ items?",
                                   (selection.pendingRestoreAssets?.count ?? 0).formatted(.number.locale(Localization.locale))),
                                isPresented: Binding(
                                    get: { selection.pendingRestoreAssets != nil },
                                    set: { if !$0 && !restoreConfirmationSubmitted { selection.cancelRestoreConfirmation() } }
                                ), titleVisibility: .visible) {
                Button(tr("Restore")) {
                    restoreConfirmationSubmitted = true
                    Task {
                        await selection.confirmRestore()
                        restoreConfirmationSubmitted = false
                    }
                }
                Button(tr("Cancel"), role: .cancel) { selection.cancelRestoreConfirmation() }
            } message: {
                Text(tr("These items will return to your library."))
            }
            .alert(tr("Couldn't Update Selection"), isPresented: Binding(
                get: { selection.error != nil },
                set: { if !$0 { selection.dismissError() } }
            )) {
                Button(tr("OK"), role: .cancel) { selection.dismissError() }
            } message: {
                if let error = selection.error { Text(error) }
            }
    }
}

private struct SelectionShareItems: Identifiable {
    let id: UUID
    let urls: [URL]
}

#if os(iOS)
private struct LibraryActivityView: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

#Preview("Selection controls") {
    let mock = MockImmichService.preview
    let model = LibraryGridModel(service: mock, loader: ImageLoader(service: mock, disk: nil))
    let selection = LibrarySelectionModel(library: model)
    VStack(spacing: 24) {
        HStack {
            LibrarySelectionCount(selection: selection)
            Spacer()
            LibrarySelectionCancelButton(selection: selection)
        }
        LibrarySelectableCell(asset: MockLibrary.standard.assets[0], model: model,
                              selection: selection, fillsCell: true, onOpen: { _ in })
            .frame(width: 140, height: 140)
        LibrarySelectionToolbar(selection: selection, allowsTrash: true)
    }
    .padding()
    .modifier(LibrarySelectionPresentation(selection: selection))
    .task {
        await model.load()
        await model.loadAllMonths()
        selection.start()
        selection.toggle(MockLibrary.standard.assets[0])
    }
}

#Preview("Restore selection controls") {
    let mock = MockImmichService.preview
    let model = LibraryGridModel(service: mock, options: TimelineOptions(isTrashed: true, visibility: nil),
                                 loader: ImageLoader(service: mock, disk: nil))
    let selection = LibrarySelectionModel(library: model)
    LibrarySelectionToolbar(selection: selection, allowsRestore: true)
        .padding()
        .task {
            await model.load()
            selection.start()
            if let asset = model.months.flatMap(\.assets).first { selection.toggle(asset) }
        }
}
