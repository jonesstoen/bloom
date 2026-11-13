import ImmichKit
import SwiftUI

/// Scrollable information below the viewer's reduced media area.
public struct AssetInfoView: View {
    let asset: Asset
    let onClose: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var infoPull = ViewerInfoPull()

    public init(asset: Asset, onClose: (() -> Void)? = nil) {
        self.asset = asset
        self.onClose = onClose
    }

    private var metadata: AssetInfoMetadata { AssetInfoMetadata(asset: asset) }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heading
                metadataCard
                if let location = metadata.location {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(tr("Location"), systemImage: "mappin.and.ellipse").font(.headline)
                        Text(location).font(.body).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.always, axes: .vertical)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            if infoPull.updateOffset(offset) { onClose?() }
        }
        .onScrollPhaseChange { _, phase in
            if phase == .tracking { infoPull.begin() }
            else if phase == .idle { infoPull.end() }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let caption = metadata.caption {
                Text(caption).font(.body).textSelection(.enabled)
                    .accessibilityLabel("\(tr("Caption")): \(caption)")
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(asset.localDateTime.formatted(Self.dateStyle)).font(.headline)
                    if let filename = metadata.filename {
                        Text(filename).font(.subheadline).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(.secondary.opacity(0.15), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tr("Close information"))
                }
            }
        }
    }

    private var metadataCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center) {
                    mediaTitle
                    Spacer(minLength: 12)
                    formatBadge
                }
                VStack(alignment: .leading, spacing: 8) {
                    mediaTitle
                    formatBadge
                }
            }
            if metadata.dimensions != nil || metadata.fileSize != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let dimensions = metadata.dimensions {
                        Text(dimensionsText(dimensions)).font(.subheadline)
                            .accessibilityLabel("\(tr("Dimensions")): \(dimensions)")
                    }
                    if let size = metadata.fileSize {
                        Text(size).font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityLabel("\(tr("File size")): \(size)")
                    }
                }
            }
            if let exif = asset.exif {
                if metadata.camera != nil || metadata.lens != nil || exif.fNumber != nil
                    || exif.iso != nil || exif.exposureTime != nil || exif.focalLength != nil {
                    Divider()
                    cameraDetails(exif)
                }
            } else {
                Text(tr("No camera metadata available")).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
    }

    private var mediaTitle: some View {
        Label(mediaPresentation.title, systemImage: mediaPresentation.symbol)
            .font(.headline).fixedSize(horizontal: false, vertical: true)
    }

    private var mediaPresentation: (title: String, symbol: String) {
        switch asset.kind {
        case .image: (asset.isLivePhoto ? tr("Live Photo") : tr("Photo"), asset.isLivePhoto ? "livephoto" : "photo")
        case .video: (tr("Video"), "video")
        case .audio: (tr("Audio"), "waveform")
        case .other: (tr("Media"), "doc")
        }
    }

    @ViewBuilder private var formatBadge: some View {
        if let format = metadata.fileFormat {
            Text(format).font(.caption.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("\(tr("Format")): \(format)")
        }
    }

    private func cameraDetails(_ exif: ExifInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let camera = metadata.camera {
                Label(camera, systemImage: "camera").font(.subheadline.weight(.semibold))
            }
            if let lens = metadata.lens {
                Text(lens).font(.subheadline).foregroundStyle(.secondary)
            }
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            layout {
                if let aperture = exif.fNumber {
                    exposureValue(tr("Aperture"), value: "ƒ/\(aperture.formatted())")
                }
                if let iso = exif.iso { exposureValue(tr("ISO"), value: iso.formatted()) }
                if let exposure = exif.exposureTime?.trimmingCharacters(in: .whitespacesAndNewlines), !exposure.isEmpty {
                    exposureValue(tr("Exposure"), value: exposure)
                }
                if let focal = exif.focalLength {
                    exposureValue(tr("Focal length"), value: "\(focal.formatted()) mm")
                }
            }
        }
    }

    private func exposureValue(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func dimensionsText(_ dimensions: String) -> String {
        guard let megapixels = metadata.megapixels else { return dimensions }
        return "\(megapixels.formatted(.number.precision(.fractionLength(0...1)))) MP · \(dimensions)"
    }

    private static let dateStyle = Date.FormatStyle(locale: Localization.locale, calendar: Asset.localCalendar, timeZone: .gmt).weekday(.wide).day().month(.wide).year().hour().minute()
}

#Preview("Information") {
    let _ = MockImmichService.preview
    AssetInfoView(asset: MockLibrary.standard.assets[0], onClose: {}).preferredColorScheme(.dark)
}
