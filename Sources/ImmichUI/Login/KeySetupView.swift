import ImmichKit
import SwiftUI

/// Step by step: creating an Immich API key with only the permissions the chosen access needs.
struct KeySetupView: View {
    let access: APIKeyAccess

    var body: some View {
        Form {
            Section {
                step(1, tr("Open Immich on the web and go to Account Settings › API Keys."))
                step(2, tr("Create a new key and name it, for example Bloom."))
                step(3, tr("Select only the permissions below."))
                step(4, tr("Copy the key and paste it into Bloom."))
                if access == .organize {
                    step(5, tr("After signing in, turn on Allow Changes in the account menu."))
                }
            }
            Section {
                ForEach(access.permissions, id: \.self) { permission in
                    Text(verbatim: permission)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            } header: {
                Text(tr("Permissions"))
            } footer: {
                Text(Self.refusesInDetail(access))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Self.title(of: access))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func step(_ number: Int, _ text: String) -> some View {
        Label(text, systemImage: "\(number).circle")
    }

    static func title(of access: APIKeyAccess) -> String {
        switch access {
        case .view: tr("View Only")
        case .organize: tr("View and Organize")
        }
    }

    /// One short line: what a key with this access lets Bloom do.
    static func allows(_ access: APIKeyAccess) -> String {
        switch access {
        case .view: tr("Browse, search, play videos and share")
        case .organize: tr("Also favorites, Recently Deleted and albums")
        }
    }

    /// One short line: what such a key can't do, even if it leaks.
    static func refuses(_ access: APIKeyAccess) -> String {
        switch access {
        case .view: tr("Can't change, delete or upload anything")
        case .organize: tr("Can't upload anything")
        }
    }

    static func refusesInDetail(_ access: APIKeyAccess) -> String {
        switch access {
        case .view:
            tr("A key with only these permissions can't change, delete or upload anything, even if it leaks.")
        case .organize:
            tr("Bloom only moves items to Recently Deleted, where they can be restored. But a leaked key with asset.delete could delete items permanently, so choose View Only if you don't need changes.")
        }
    }
}

#Preview("View only") {
    NavigationStack { KeySetupView(access: .view) }
}

#Preview("View and organize") {
    NavigationStack { KeySetupView(access: .organize) }
}
