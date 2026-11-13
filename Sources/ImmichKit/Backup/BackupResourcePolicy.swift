import Foundation

/// Which PhotoKit resources of an asset get uploaded. Matches what the Immich app uploads
/// (established by an on-device spike): the edited full-size file when there is one, else the original;
/// for Live Photos the motion part as well.
public enum BackupResourcePolicy {
    public static func upload(from resources: [DeviceResource]) -> [DeviceResource] {
        func first(_ type: DeviceResourceType) -> DeviceResource? { resources.first { $0.type == type } }
        let picks = [
            first(.fullSizePhoto) ?? first(.photo),
            first(.fullSizePairedVideo) ?? first(.pairedVideo),
            first(.fullSizeVideo) ?? first(.video),
        ]
        return picks.compactMap { $0 }
    }
}
