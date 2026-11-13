import ImmichKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The viewer's share button: downloads the original file from Immich, then opens the system
/// share sheet (save to Photos, AirDrop, Messages, …).
struct ShareAssetButton: View {
    let asset: Asset
    var onPrepare: () -> Void = {}
    var onBusyChanged: (Bool) -> Void = { _ in }
    @State private var model: ViewerShareModel
    @State private var preparationTask: Task<Void, Never>?

    init(
        asset: Asset, service: any ImmichService, downloader: OriginalFileDownloader = .live,
        onPrepare: @escaping () -> Void = {},
        onBusyChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.asset = asset
        self.onPrepare = onPrepare
        self.onBusyChanged = onBusyChanged
        _model = State(initialValue: ViewerShareModel(service: service, downloader: downloader))
    }

    var body: some View {
        @Bindable var model = model
        Button {
            guard !model.isBusy else { return }
            let selectedAsset = asset
            onPrepare()
            preparationTask = Task {
                await model.prepare(asset: selectedAsset)
                #if !os(iOS)
                // This button has no share-sheet presentation on macOS.
                if !Task.isCancelled { model.finishSharing() }
                #endif
            }
        } label: {
            ZStack {
                if model.isPreparing {
                    ProgressView()
                } else {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 19, weight: .medium))
                }
            }
            .frame(width: 48, height: 48)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .photosGlass(in: Circle())
        .disabled(model.isPreparing)
        .accessibilityLabel(tr("Share"))
        #if os(iOS)
        .sheet(item: $model.sharedFiles, onDismiss: { model.finishSharing() }) { files in
            ActivityView(items: files.urls, owner: model)
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        #endif
        .onChange(of: model.isBusy, initial: true) { _, busy in
            onBusyChanged(busy)
        }
        .onDisappear {
            preparationTask?.cancel()
            preparationTask = nil
            if model.isPreparing {
                model.cancelPreparation()
                onBusyChanged(model.isBusy)
            }
        }
        .alert(tr("Couldn't Share"), isPresented: $model.failed) {
            Button(tr("OK"), role: .cancel) {}
        } message: {
            Text(tr("The original file couldn't be downloaded. Please try again."))
        }
    }
}

#if os(iOS)
private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    let owner: ViewerShareModel

    // Retain the files' owner even if the originating viewer disappears during sharing.
    final class Coordinator {
        let owner: ViewerShareModel
        init(owner: ViewerShareModel) { self.owner = owner }
    }

    func makeCoordinator() -> Coordinator { Coordinator(owner: owner) }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

#Preview("Share button") {
    ShareAssetButton(asset: MockLibrary.standard.assets[0], service: MockImmichService.preview,
                     downloader: OriginalFileDownloader { request, destination in
                         try MockImmichService.placeholderData(assetID: request.assetID, size: .preview).write(to: destination)
                     })
        .padding()
        .background(.black)
}
