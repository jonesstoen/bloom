import Foundation

/// How Bloom keeps photos and library metadata it caches on the device.
public enum CacheProtection {
    /// Cached files are only readable while the device is unlocked. Bloom never reads its caches
    /// in the background, so a locked phone loses nothing but a cache write, which is harmless.
    public static var writingOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtection]
        #else
        .atomic
        #endif
    }

    /// Applies the same protection to a file that was moved into place rather than written.
    public static func protect(_ url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }

    /// Removes every per-account cache directory under `root` except `keeping`. Only one account
    /// is signed in at a time, so the others are left over from earlier sessions (a crash before
    /// sign-out, or a replaced API key) and would otherwise stay on the device indefinitely.
    public static func removeOtherAccounts(in root: URL = DiskImageCache.defaultDirectory, keeping: URL?) {
        let files = FileManager.default
        guard let children = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let kept = keeping?.standardizedFileURL.lastPathComponent
        for child in children where child.standardizedFileURL.lastPathComponent != kept {
            try? files.removeItem(at: child)
        }
    }
}
