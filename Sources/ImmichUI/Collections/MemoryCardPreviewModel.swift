import CoreGraphics
import ImmichKit
import Observation

/// The photo a memory card shows, cycling through up to six of the memory's photos.
///
/// Only one decoded image is kept. A failed next photo keeps the current one on screen and is
/// skipped next time; a newer `prepare` (other candidates) always wins over an older one still
/// loading, and a cancelled load never publishes.
@MainActor @Observable
final class MemoryCardPreviewModel {
    static let maxCandidates = 6

    private(set) var image: CGImage?
    private(set) var assetID: String?
    /// Increases each time a new photo is shown; drives the crossfade and the zoom direction.
    private(set) var revision = 0
    private(set) var candidateIDs: [String] = []
    var canAdvance: Bool { candidateIDs.count > 1 }

    @ObservationIgnored private var currentIndex: Int?
    @ObservationIgnored private var nextIndex = 0
    @ObservationIgnored private var generation = 0

    func prepare(assetIDs: [String], loader: ImageLoader) async {
        var seen = Set<String>()
        let candidates = Array(assetIDs.filter { seen.insert($0).inserted }.prefix(Self.maxCandidates))
        generation += 1
        let started = generation
        candidateIDs = candidates
        // The photo on screen stays if it is still one of the memory's photos.
        if let assetID, let index = candidates.firstIndex(of: assetID) {
            currentIndex = index
            nextIndex = candidates.isEmpty ? 0 : (index + 1) % candidates.count
            return
        }
        currentIndex = nil
        nextIndex = 0
        for index in candidates.indices {
            if await show(index, generation: started, loader: loader) { return }
            guard !Task.isCancelled, generation == started else { return }
        }
    }

    func advance(loader: ImageLoader) async {
        guard canAdvance else { return }
        let started = generation
        let index = nextIndex % candidateIDs.count
        if !(await show(index, generation: started, loader: loader)), generation == started {
            // Keep the current photo and try the one after it next time.
            nextIndex = (index + 1) % candidateIDs.count
        }
    }

    /// Loads and shows candidate `index`. Returns whether it is now on screen.
    private func show(_ index: Int, generation started: Int, loader: ImageLoader) async -> Bool {
        let id = candidateIDs[index]
        guard let data = try? await loader.data(for: ImageKey(assetID: id, size: .preview)),
              !Task.isCancelled, generation == started else { return false }
        guard let decoded = await ThumbnailDecoder.decode(data, maxPixelSize: 900),
              !Task.isCancelled, generation == started else { return false }
        image = decoded
        assetID = id
        currentIndex = index
        nextIndex = (index + 1) % candidateIDs.count
        revision += 1
        return true
    }
}
