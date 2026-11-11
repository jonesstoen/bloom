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
    @State private var isPreparing = false
    @State private var file: SharedFile?
    @State private var failed = false

    var body: some View {
        Button { Task { await prepare() } } label: {
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
        .accessibilityLabel("Share")
        #if os(iOS)
        .sheet(item: $file) { file in
            ActivityView(items: [file.url])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        #endif
        .alert("Couldn't Share", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The original file couldn't be downloaded. Please try again.")
        }
    }

    private func prepare() async {
        isPreparing = true
        defer { isPreparing = false }
        do {
            let data = try await service.original(assetID: asset.id)
            file = SharedFile(url: try SharedFile.write(data, for: asset))
        } catch is CancellationError {
            return
        } catch {
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
