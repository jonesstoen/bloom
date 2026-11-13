import ImmichKit
import SwiftUI

/// Chooses which albums are backed up. Tapping cycles an album through included, excluded and
/// neither; excluded albums subtract their photos from the included ones.
struct BackupAlbumPicker: View {
    let model: BackupModel

    var body: some View {
        List {
            Section {
                ForEach(model.albums) { album in
                    Button { model.cycle(album) } label: { row(for: album) }
                        .buttonStyle(.plain)
                        .accessibilityValue(label(for: model.state(of: album)))
                }
            } footer: {
                Text(tr("Tap an album to include it, tap again to exclude it, and once more to clear it. Recents is a good place to start."))
            }
        }
        .navigationTitle(tr("Albums"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func row(for album: DeviceAlbum) -> some View {
        HStack(spacing: 12) {
            icon(for: model.state(of: album))
                .font(.title3)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                if album.id == model.suggestedAlbumID {
                    Text(tr("Suggested"))
                        .font(.footnote)
                        .foregroundStyle(.tint)
                }
            }
            Spacer()
            Text(album.count, format: .number)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private func icon(for state: BackupModel.AlbumState) -> some View {
        switch state {
        case .included: Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
        case .excluded: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        case .neither: Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }

    private func label(for state: BackupModel.AlbumState) -> String {
        switch state {
        case .included: tr("Included")
        case .excluded: tr("Excluded")
        case .neither: tr("Not Included")
        }
    }
}

#Preview("Album picker") {
    let model = BackupModel.preview(selected: ["favorites"], excluded: ["screenshots"])
    NavigationStack { BackupAlbumPicker(model: model) }
        .task { await model.load() }
}

#Preview("Album picker, first setup") {
    let model = BackupModel.preview()
    NavigationStack { BackupAlbumPicker(model: model) }
        .task { await model.load() }
}
