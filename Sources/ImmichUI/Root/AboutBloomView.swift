import ImmichKit
import SwiftUI

/// About Bloom: the logo, the app version and the Home Screen icon picker.
struct AboutBloomView: View {
    @State private var icons: AppIconModel
    @Environment(\.dismiss) private var dismiss

    init(icons: AppIconModel) {
        _icons = State(initialValue: icons)
    }

    var body: some View {
        NavigationStack {
            List {
                header
                if icons.isSupported {
                    iconPicker
                }
            }
            .navigationTitle(tr("About Bloom"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Done")) { dismiss() }
                }
            }
            .errorAlert(tr("Couldn't Change App Icon"), message: icons.error, onDismiss: { icons.dismissError() })
        }
    }

    private var header: some View {
        Section {
            VStack(spacing: 10) {
                BloomMark().frame(width: 88, height: 88)
                Text(tr("Bloom"))
                    .font(.title.bold())
                Text(tr("for Immich"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let version = Self.versionText(info: Bundle.main.infoDictionary ?? [:]) {
                    Text(version)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .accessibilityElement(children: .combine)
        }
    }

    private var iconPicker: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                ForEach(AppIconChoice.allCases) { choice in
                    Button {
                        Task { await icons.select(choice) }
                    } label: {
                        VStack(spacing: 6) {
                            BloomIconTile(choice: choice)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                                        .padding(-4)
                                        .opacity(icons.selection == choice ? 1 : 0)
                                }
                            Text(choice.title)
                                .font(.caption)
                                .foregroundStyle(icons.selection == choice ? .primary : .secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.title)
                    .accessibilityAddTraits(icons.selection == choice ? .isSelected : [])
                }
            }
            .padding(.vertical, 8)
            .disabled(icons.isChanging)
        } header: {
            Text(tr("App Icon"))
        } footer: {
            Text(tr("Automatic follows your Home Screen setting for light, dark and tinted icons."))
        }
    }

    /// "Version 1.2 (34)" from the app's Info.plist, or nil when it has no version.
    static func versionText(info: [String: Any]) -> String? {
        guard let version = info["CFBundleShortVersionString"] as? String else { return nil }
        let build = info["CFBundleVersion"] as? String ?? "1"
        return tr("Version %@ (%@)", version, build)
    }
}

#Preview("About Bloom") {
    let _ = MockImmichService.preview
    AboutBloomView(icons: AppIconModel(switcher: InMemoryAppIconSwitcher(current: "AppIcon-Dark")))
}
