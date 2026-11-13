import ImmichKit
import SwiftUI

/// Step by step: creating an Immich API key with only the permissions the chosen access needs.
struct KeySetupView: View {
    let access: APIKeyAccess

    var body: some View {
        Form {
            Section {
                Label(tr("Bloom can't create the key for you. You make it yourself in Immich on the web and paste it into Bloom. This page only explains how."),
                      systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            Section {
                step(1, tr("Open Immich on the web and go to Account Settings › API Keys."))
                step(2, tr("Create a new key and name it, for example Bloom."))
                step(3, tr("Select only the permissions below."))
                step(4, tr("Copy the key and paste it into Bloom."))
                if access == .organize {
                    step(5, tr("After signing in, turn on Allow Changes in the account menu."))
                }
            } header: {
                Text(tr("Steps"))
            } footer: {
                Text(Self.refusesInDetail(access))
            }
            permissionSection(APIKeyPermissions.readOnly,
                              header: access == .organize ? tr("For Viewing") : tr("Permissions"))
            if access == .organize {
                permissionSection(APIKeyPermissions.changes, header: tr("Also for Changes"))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(tr("Create the Key in Immich"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func permissionSection(_ permissions: [String], header: String) -> some View {
        Section {
            ForEach(permissions, id: \.self) { permission in
                Text(verbatim: permission)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
        } header: {
            Text(header)
        }
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
        case .organize: tr("Everything in View Only, plus favorites, trash and albums")
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
