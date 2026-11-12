import ImmichKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The viewer's share button: downloads the original file from Immich, then opens the system
/// share sheet (save to Photos, AirDrop, Messages, …).
struct ShareAssetButton: View {
    let asset: Asset
    let service: any ImmichService
    var onPrepare: () -> Void = {}
    var onBusyChanged: (Bool) -> Void = { _ in }
    @State private var isPreparing = false
    @State private var file: SharedFile?
    @State private var failed = false

    var body: some View {
        Button {
            guard !isPreparing, file == nil else { return }
            isPreparing = true
            onBusyChanged(true)
            onPrepare()
            Task { await prepare() }
        } label: {
            ZStack {
                if isPreparing {
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
        .disabled(isPreparing)
        .accessibilityLabel(tr("Share"))
        #if os(iOS)
        .sheet(item: $file, onDismiss: { onBusyChanged(false) }) { file in
            ActivityView(items: [file.url])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        #endif
        .alert(tr("Couldn't Share"), isPresented: $failed) {
            Button(tr("OK"), role: .cancel) {}
        } message: {
            Text(tr("The original file couldn't be downloaded. Please try again."))
        }
    }

    private func prepare() async {
        defer { isPreparing = false }
        do {
            let data = try await service.original(assetID: asset.id)
            let prepared = SharedFile(url: try SharedFile.write(data, for: asset))
            #if os(iOS)
            file = prepared
            #else
            // This button has no share-sheet presentation on macOS.
            _ = prepared
            onBusyChanged(false)
            #endif
        } catch is CancellationError {
            onBusyChanged(false)
        } catch {
            onBusyChanged(false)
            failed = true
        }
    }
}

struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }

    /// Writes the original under its file name in a temporary folder, replacing earlier shares.
    static func write(_ data: Data, for asset: Asset) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImmichShare", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName(for: asset))
        try data.write(to: url, options: .atomic)
        return url
    }

    static func fileName(for asset: Asset) -> String {
        let name = asset.originalFileName?
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        return asset.id + (asset.isVideo ? ".mov" : ".jpg")
    }
}

#if os(iOS)
private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

#Preview("Share button") {
    ShareAssetButton(asset: MockLibrary.standard.assets[0], service: MockImmichService.preview)
        .padding()
        .background(.black)
}
