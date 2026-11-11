import ImmichKit
import SwiftUI

public struct AssetInfoView: View {
    let asset: Asset
    public init(asset: Asset) { self.asset = asset }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(asset.originalFileName ?? tr("Photo information")).font(.headline)
                    Text(asset.localDateTime.formatted(Date.FormatStyle(locale: Localization.locale, calendar: Asset.localCalendar, timeZone: .gmt).day().month(.wide).year().hour().minute()))
                    if let size = asset.size { LabeledContent(tr("Dimensions"), value: "\(size.width) × \(size.height)") }
                    if let bytes = asset.exif?.fileSizeInBytes { LabeledContent(tr("File size"), value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
                }
                if let exif = asset.exif {
                    Section(tr("Camera")) {
                        if let camera = exif.cameraName { Text(camera) }
                        if let lens = exif.lensModel { Text(lens) }
                        if let aperture = exif.fNumber { LabeledContent(tr("Aperture"), value: "ƒ/\(aperture.formatted())") }
                        if let iso = exif.iso { LabeledContent(tr("ISO"), value: iso.formatted()) }
                        if let exposure = exif.exposureTime { LabeledContent(tr("Exposure"), value: exposure) }
                        if let focal = exif.focalLength { LabeledContent(tr("Focal length"), value: "\(focal.formatted()) mm") }
                    }
                    if let place = exif.locationName { Section(tr("Location")) { Label(place, systemImage: "mappin.and.ellipse") } }
                    if let caption = exif.description, !caption.isEmpty { Section(tr("Caption")) { Text(caption) } }
                } else {
                    Text(tr("No camera metadata available")).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(tr("Information"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
}

#Preview("Information") {
    let _ = MockImmichService.preview
    AssetInfoView(asset: MockLibrary.standard.assets[0])
}
