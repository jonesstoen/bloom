import ImmichKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Backup: a status at the top (how much is on the server, what happens now), notices that need the
/// user, the overview of what remains, the check button, problems, then the settings (switch, albums,
/// cellular). Present it inside a `NavigationStack`.
struct BackupView: View {
    let model: BackupModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        List {
            switch model.access {
            case .denied:
                deniedSection
            case .limited:
                content(limited: true)
            case .full, .notDetermined, nil:
                // Not yet known, or the system prompt is up: show the content, no scan is possible.
                content(limited: false)
            }
            Section {} footer: {
                Text(tr("Bloom never deletes photos from your iPhone."))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
        .navigationTitle(tr("Backup"))
        // Turning the switch on before choosing albums opens the picker; popping it clears the flag.
        .navigationDestination(isPresented: $model.needsAlbumChoice) { BackupAlbumPicker(model: model) }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(tr("Done")) { dismiss() }
            }
        }
        .task { await model.load(); model.runner.backupScreenOpened() }
        // Uploads go on while the screen is open (and after it is closed): look at them every few seconds.
        .task {
            while !Task.isCancelled {
                await model.refreshBackgroundStatus()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        #if os(iOS)
        // Keep the screen awake while a scan or an upload runs: auto-lock would suspend the app and stop
        // a long first run.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = keepsScreenAwake }
        .onChange(of: keepsScreenAwake) { _, awake in UIApplication.shared.isIdleTimerDisabled = awake }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
    }

    #if os(iOS)
    /// While the Backup screen is open, a scan or an upload keeps the screen from locking.
    private var keepsScreenAwake: Bool { model.isScanning || model.runner.isUploading }
    #endif

    @ViewBuilder private func content(limited: Bool) -> some View {
        BackupStatusSection(model: model)
        BackupNoticesSection(model: model, limited: limited)
        BackupCountsSection(model: model)
        BackupCheckSection(model: model)
        BackupFailedItemsSection(model: model)
        settingsSection
        cellularSection
    }

    // MARK: Access

    private var deniedSection: some View {
        Section {
            BackupNotice(
                symbol: "lock.fill", tint: .secondary, title: tr("Photo Access Is Off"),
                message: tr("Allow Bloom to read your photos in Settings so it can check which ones are already on your server."),
                button: BackupNotice.settingsButton)
        }
    }

    // MARK: Settings

    private var settingsSection: some View {
        Section {
            Toggle(tr("Backup"), isOn: Binding(
                get: { model.settings.isEnabled },
                set: { model.setBackupEnabled($0) }))
            NavigationLink {
                BackupAlbumPicker(model: model)
            } label: {
                LabeledContent(tr("Albums"), value: model.selectionSummary)
            }
        } footer: {
            Text(tr("Bloom backs up when it is open and at night while charging. iOS decides the exact time."))
        }
    }

    private var cellularSection: some View {
        Section {
            @Bindable var model = model
            Toggle(tr("Photos over Cellular"), isOn: $model.settings.photosOnCellular)
            Toggle(tr("Videos over Cellular"), isOn: $model.settings.videosOnCellular)
        } footer: {
            Text(tr("Photos that exist only in iCloud are checked on Wi-Fi, unless you allow cellular here."))
        }
    }
}

// MARK: - Status

/// The ring, the title and the one line about what happens now. Its own view: it reads the counts and both
/// progress values, so their changes only rebuild this section.
private struct BackupStatusSection: View {
    let model: BackupModel

    var body: some View {
        let status = BackupHeaderStatus(
            isEnabled: model.settings.isEnabled, hasSelection: !model.selection.included.isEmpty,
            counts: model.counts, checking: model.progress, isScanning: model.isScanning,
            upload: model.runner.uploadProgress, inFlight: model.inFlightCount, lastBackup: model.lastBackup,
            isRedirectBlocked: model.isRedirectBlocked, connection: model.connectionStatus)
        Section {
            BackupStatusHeader(status: status) { action in
                switch action {
                case .chooseAlbums: model.needsAlbumChoice = true
                case .turnOn: model.setBackupEnabled(true)
                }
            }
        }
    }
}

private struct BackupStatusHeader: View {
    let status: BackupHeaderStatus
    var perform: (BackupHeaderStatus.Action) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 14) {
            BackupRing(fraction: status.fraction, symbol: status.symbol, tint: tint,
                       isActive: status.kind == .uploading || status.kind == .checking)
            VStack(spacing: 4) {
                Text(status.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let detail = status.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .monospacedDigit()
            .accessibilityElement(children: .combine)
            if let action = status.action {
                Button {
                    perform(action)
                } label: {
                    Text(action == .turnOn ? tr("Turn On Backup") : tr("Choose Albums"))
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .listRowBackground(Color.clear)
    }

    private var tint: Color {
        switch status.kind {
        case .upToDate: .green
        case .stopped, .problems: .orange
        case .off, .noAlbums, .notChecked: .secondary
        case .checking, .uploading, .remaining: .accentColor
        }
    }
}

/// How much of the selection is on the server, as a ring around the status symbol.
private struct BackupRing: View {
    let fraction: Double
    let symbol: String
    let tint: Color
    var isActive = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 8)
            Circle()
                .trim(from: 0, to: max(0, min(fraction, 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, options: .repeating, isActive: isActive)
        }
        .frame(width: 92, height: 92)
        .animation(.smooth, value: fraction)
        .animation(.smooth, value: symbol)
        .accessibilityHidden(true)
    }
}

// MARK: - Notices

/// Things the user has to fix: a redirect block, Background App Refresh off, limited photo access.
private struct BackupNoticesSection: View {
    let model: BackupModel
    let limited: Bool

    var body: some View {
        if model.isRedirectBlocked {
            Section {
                BackupNotice(
                    symbol: "exclamationmark.triangle.fill", tint: .orange, title: tr("Backup Stopped"),
                    message: tr("Backup stopped: the server redirected an upload to another address. Check your server setup, then tap Try Again."),
                    button: (tr("Try Again"), { Task { await model.retryAfterRedirect() } }))
            }
        }
        if model.isBackgroundRefreshOff && model.settings.isEnabled {
            Section {
                BackupNotice(
                    symbol: "arrow.clockwise.circle.fill", tint: .blue, title: tr("Background App Refresh"),
                    message: tr("Background App Refresh is off for Bloom. Turn it on in Settings to back up when Bloom is closed."),
                    button: BackupNotice.settingsButton)
            }
        }
        if limited {
            Section {
                BackupNotice(
                    symbol: "photo.badge.exclamationmark.fill", tint: .orange, title: tr("Limited Access"),
                    message: tr("Bloom can only see the photos you selected. Allow access to all photos to check your whole library."),
                    button: BackupNotice.settingsButton)
            }
        }
    }
}

/// A notice row: a coloured symbol, a bold title, the explanation and one button.
private struct BackupNotice: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    var button: (String, () -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let button {
                    Button(button.0, action: button.1)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// "Open Settings", only on iOS.
    @MainActor static var settingsButton: (String, () -> Void)? {
        #if os(iOS)
        (tr("Open Settings"), {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        })
        #else
        nil
        #endif
    }
}

// MARK: - Overview

/// Observe changing counts here instead of rebuilding the whole Backup list.
private struct BackupCountsSection: View {
    let model: BackupModel

    var body: some View {
        // Nothing to count before the first check.
        if model.counts.total > 0 {
            Section {
                BackupCountRow(title: tr("On Server"), symbol: "checkmark.circle.fill", tint: .green,
                               value: model.counts.backedUp)
                if model.remaining > 0 {
                    NavigationLink {
                        BackupRemainingList(model: model)
                    } label: { remainingRow }
                } else {
                    remainingRow
                }
                if model.counts.deletedOnServer > 0 {
                    NavigationLink {
                        BackupDeletedOnServerList(model: model)
                    } label: {
                        BackupCountRow(title: tr("Deleted on Server"), symbol: "trash.circle.fill", tint: .gray,
                                       value: model.counts.deletedOnServer)
                    }
                }
                // So that Total always equals On Server + Remaining + Deleted on Server + Problems.
                if model.counts.failed > 0 {
                    BackupCountRow(title: tr("Problems"), symbol: "exclamationmark.circle.fill", tint: .orange,
                                   value: model.counts.failed)
                }
            } header: {
                HStack {
                    Text(tr("Overview"))
                    Spacer()
                    Text(tr("%lld items", Int64(model.counts.total)))
                        .monospacedDigit()
                }
            }
        }
    }

    private var remainingRow: some View {
        BackupCountRow(
            title: tr("Remaining"), symbol: "arrow.up.circle.fill", tint: .blue, value: model.remaining,
            subtitle: model.counts.waitingForWiFi > 0
                ? tr("%lld waiting for Wi-Fi", Int64(model.counts.waitingForWiFi)) : nil)
    }
}

private struct BackupCountRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let value: Int
    var subtitle: String?

    var body: some View {
        LabeledContent {
            Text(value, format: .number)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(tint)
            }
        }
    }
}

// MARK: - Check

/// The check button (Cancel while a check runs; its progress is in the status at the top) and its error.
private struct BackupCheckSection: View {
    let model: BackupModel

    var body: some View {
        Section {
            if model.isScanning || model.progress != nil {
                Button(tr("Cancel"), role: .cancel) { model.cancel() }
                    .frame(maxWidth: .infinity)
            } else {
                Button {
                    model.runner.checkNow()
                } label: {
                    Label(tr("Check Now"), systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!model.canCheck)
            }
        } footer: {
            if let error = model.error {
                Text(error).foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Problems

/// Keep both the failure list and its live count footer out of the parent observation.
private struct BackupFailedItemsSection: View {
    let model: BackupModel

    var body: some View {
        if !model.failedItems.isEmpty {
            Section {
                ForEach(model.failedItems) { item in
                    HStack(spacing: 12) {
                        Label {
                            Text(item.reason)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        Spacer(minLength: 8)
                        Button(tr("Try Again")) { Task { await model.retry([item.id]) } }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                            .disabled(model.isWorking)
                    }
                }
                Button(tr("Try All Again")) { Task { await model.retryAll() } }
                    .disabled(model.isWorking)
            } header: {
                Text(tr("Items with Problems"))
            } footer: {
                if model.counts.failed > model.failedItems.count {
                    Text(tr("Showing the first %lld.", Int64(model.failedItems.count)))
                }
            }
        }
    }
}

// MARK: - Previews

private func previewStatus(
    enabled: Bool = true, hasSelection: Bool = true, counts: BackupCounts, upload: UploadProgress? = nil,
    inFlight: Int = 0, redirect: Bool = false
) -> BackupHeaderStatus {
    BackupHeaderStatus(
        isEnabled: enabled, hasSelection: hasSelection, counts: counts, checking: nil, isScanning: false,
        upload: upload, inFlight: inFlight, lastBackup: .now.addingTimeInterval(-7200),
        isRedirectBlocked: redirect, connection: nil)
}

#Preview("Backup status states") {
    let partial = BackupCounts(total: 12_969, backedUp: 12_345, pending: 624, waitingForWiFi: 40)
    List {
        Section { BackupStatusHeader(status: previewStatus(counts: BackupCounts(total: 10, backedUp: 10))) }
        Section { BackupStatusHeader(status: previewStatus(
            counts: partial, upload: UploadProgress(done: 3, total: 15, currentFilename: "IMG_1234.HEIC"))) }
        Section { BackupStatusHeader(status: previewStatus(counts: partial)) }
        Section { BackupStatusHeader(status: previewStatus(enabled: false, counts: partial)) }
        Section { BackupStatusHeader(status: previewStatus(hasSelection: false, counts: BackupCounts())) }
        Section { BackupStatusHeader(status: previewStatus(counts: partial, redirect: true)) }
    }
}

#Preview("Backup counts") {
    let model = BackupModel.preview(selected: ["recents"])
    List { BackupCountsSection(model: model) }
        .task { await model.load() }
}

#Preview("Backup check") {
    let model = BackupModel.preview(selected: ["recents"])
    List { BackupCheckSection(model: model) }
        .task { await model.load() }
}

#Preview("Backup problems") {
    let model = BackupModel.preview(selected: ["recents"])
    List { BackupFailedItemsSection(model: model) }
        .task { await model.loadPreview(problems: 2) }
}

#Preview("Backup notices") {
    List {
        Section {
            BackupNotice(
                symbol: "exclamationmark.triangle.fill", tint: .orange, title: tr("Backup Stopped"),
                message: tr("Backup stopped: the server redirected an upload to another address. Check your server setup, then tap Try Again."),
                button: (tr("Try Again"), {}))
        }
        Section {
            BackupNotice(
                symbol: "arrow.clockwise.circle.fill", tint: .blue, title: tr("Background App Refresh"),
                message: tr("Background App Refresh is off for Bloom. Turn it on in Settings to back up when Bloom is closed."),
                button: BackupNotice.settingsButton)
        }
    }
}

#Preview("Backup") {
    NavigationStack { BackupView(model: .preview(selected: ["recents"], excluded: ["screenshots"])) }
}

#Preview("Backup, deleted on server and problems") {
    let model = BackupModel.preview(selected: ["recents"], excluded: ["screenshots"])
    NavigationStack { BackupView(model: model) }
        .task { await model.loadPreview(deletedOnServer: 3, problems: 2) }
}

#Preview("Backup, first setup") {
    NavigationStack { BackupView(model: .preview()) }
}

#Preview("Backup, limited access") {
    NavigationStack { BackupView(model: .preview(selected: ["recents"], access: .limited)) }
}

#Preview("Backup, photo access off") {
    NavigationStack { BackupView(model: .preview(access: .denied)) }
}

extension BackupModel {
    /// A model on the preview library and mock server, with its own throwaway index.
    static func preview(
        selected: Set<String> = [], excluded: Set<String> = [], access: PhotoAccess = .full
    ) -> BackupModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupPreview-\(UUID().uuidString)", isDirectory: true)
        let model = BackupModel(
            source: PreviewPhotoLibrary(access: access),
            service: MockImmichService.preview,
            directory: directory,
            network: PreviewNetwork(),
            defaults: UserDefaults(suiteName: "BackupPreview") ?? .standard)
        if !selected.isEmpty || !excluded.isEmpty {
            model.setSelection(BackupSelection(included: selected, excluded: excluded))
        }
        return model
    }
}

private struct PreviewNetwork: NetworkConditions {
    var isOnCellular: Bool { false }
    func changes() -> AsyncStream<NetworkPath> { AsyncStream { $0.finish() } }
}
