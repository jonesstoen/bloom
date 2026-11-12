import Foundation

/// The sections of the Collections tab that can be folded away.
enum CollectionSection: String, CaseIterable, Sendable {
    case memories, pinned, albums, people, places, mediaTypes, other

    /// VoiceOver label of the fold button: what tapping it does.
    static func toggleLabel(title: String, isCollapsed: Bool) -> String {
        isCollapsed ? tr("Show %@", title) : tr("Hide %@", title)
    }
}

/// Which Collections sections are folded, stored as one string (`@AppStorage`) so it survives a
/// relaunch. Unknown names (a section removed later) are dropped.
struct CollapsedSections: Equatable, Sendable {
    private var sections: Set<CollectionSection>

    init(rawValue: String) {
        sections = Set(rawValue.split(separator: ",").compactMap { CollectionSection(rawValue: String($0)) })
    }

    var rawValue: String {
        CollectionSection.allCases.filter(sections.contains).map(\.rawValue).joined(separator: ",")
    }

    func contains(_ section: CollectionSection) -> Bool { sections.contains(section) }

    mutating func toggle(_ section: CollectionSection) {
        if sections.contains(section) { sections.remove(section) } else { sections.insert(section) }
    }
}
