import Foundation

/// A deterministic fake Immich library for tests and SwiftUI previews.
///
/// The same `seed`, `assetCount` and `referenceDate` always produce the same assets, albums, people
/// and memories, with stable UUID-shaped ids. Assets are clustered into "events" (a day at a place),
/// carry EXIF data (camera, GPS, city), and some are favorites, videos, Live Photos, archived or trashed.
/// Every past year has an event on `referenceDate`'s month and day, so "on this day" memories exist.
public struct MockLibrary: Sendable {
    public let referenceDate: Date
    /// All assets, newest first (including archived and trashed ones).
    public let assets: [Asset]
    public let albums: [Album]
    /// People, most photographed first. Includes one unnamed and one hidden person.
    public let people: [Person]
    /// "On this day" memories for `referenceDate`, most recent year first.
    public let memories: [Memory]
    /// Asset ids per album id, in album order (newest first).
    public let albumAssetIDs: [String: [String]]
    /// Asset ids per person id, newest first.
    public let personAssetIDs: [String: [String]]

    private let assetsByID: [String: Asset]

    /// The library used by previews and most tests: ~400 assets over five years.
    public static let standard = MockLibrary()

    /// A small library for fast tests.
    public static let small = MockLibrary(assetCount: 40)

    /// Fixed default "today" so the library does not change with the clock: 2026-06-15 12:00 UTC.
    public static let defaultReferenceDate = Date(timeIntervalSince1970: 1_781_524_800)

    public init(seed: UInt64 = 42, assetCount: Int = 400, years: Int = 5, referenceDate: Date = MockLibrary.defaultReferenceDate) {
        precondition(assetCount > 0 && years > 0)
        var generator = Generator(seed: seed, referenceDate: referenceDate, years: years)
        let generated = generator.makeAssets(count: assetCount)
        let assets = generated.map(\.asset).sorted { $0.takenAt > $1.takenAt }
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })

        // People: membership drawn per asset in `makeAssets`.
        var personAssets: [String: [String]] = [:]
        for item in generated {
            for person in item.people { personAssets[person, default: []].append(item.asset.id) }
        }
        let newestFirst: ([String]) -> [String] = { ids in ids.sorted { byID[$0]!.takenAt > byID[$1]!.takenAt } }
        personAssets = personAssets.mapValues(newestFirst)
        let people = Generator.personSeeds.enumerated()
            .map { index, seed in
                Person(
                    id: Generator.uuid(kind: 0xB, index: index),
                    name: seed.name,
                    birthDate: seed.birthday,
                    isHidden: seed.hidden,
                    isFavorite: index == 0,
                    updatedAt: referenceDate
                )
            }
            .sorted { (personAssets[$0.id]?.count ?? 0) > (personAssets[$1.id]?.count ?? 0) }

        // Albums: one per place theme, plus favorites-of-a-person and a mixed one.
        var albumAssets: [String: [String]] = [:]
        var albums: [Album] = []
        func addAlbum(_ name: String, description: String = "", shared: Bool = false, ids: [String]) {
            let index = albums.count
            let id = Generator.uuid(kind: 0xA, index: index)
            let ordered = newestFirst(ids)
            albumAssets[id] = ordered
            let dates = ordered.compactMap { byID[$0]?.takenAt }
            albums.append(Album(
                id: id, name: name, description: description, assetCount: ordered.count,
                thumbnailAssetId: ordered.first, startDate: dates.min(), endDate: dates.max(),
                createdAt: dates.min() ?? referenceDate, updatedAt: dates.max() ?? referenceDate,
                isShared: shared
            ))
        }
        let visible = generated.filter { !$0.asset.isTrashed }
        for place in Generator.places where place.album != nil {
            addAlbum(place.album!, ids: visible.filter { $0.asset.exif?.city == place.city }.map(\.asset.id))
        }
        if let first = Generator.personSeeds.first {
            let personID = Generator.uuid(kind: 0xB, index: 0)
            addAlbum("Best of \(first.name)", description: "Shared with family", shared: true,
                     ids: (personAssets[personID] ?? []).filter { byID[$0]!.isFavorite || byID[$0]!.kind == .video })
        }
        addAlbum("Videos", ids: visible.filter { $0.asset.kind == .video }.map(\.asset.id))
        addAlbum("Empty Album", ids: [])

        // On this day: assets on the reference month/day in earlier years.
        let calendar = Asset.localCalendar
        let today = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        var memories: [Memory] = []
        for yearsAgo in 1...years {
            let year = today.year! - yearsAgo
            let dayAssets = assets.filter {
                guard !$0.isTrashed, !$0.isArchived else { return false }
                let parts = calendar.dateComponents([.year, .month, .day], from: $0.localDateTime)
                return parts.year == year && parts.month == today.month && parts.day == today.day
            }.sorted { $0.takenAt < $1.takenAt }
            guard !dayAssets.isEmpty else { continue }
            let memoryAt = calendar.date(from: DateComponents(year: year, month: today.month, day: today.day))!
            memories.append(Memory(
                id: Generator.uuid(kind: 0xC, index: yearsAgo),
                kind: .onThisDay(year: year),
                memoryAt: memoryAt,
                showAt: calendar.startOfDay(for: referenceDate),
                hideAt: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: referenceDate)),
                assets: dayAssets
            ))
        }

        self.referenceDate = referenceDate
        self.assets = assets
        self.assetsByID = byID
        self.people = people
        self.personAssetIDs = personAssets
        self.albums = albums
        self.albumAssetIDs = albumAssets
        self.memories = memories
    }

    public func asset(id: String) -> Asset? { assetsByID[id] }

    /// Assets in an album, newest first. Empty for an unknown album.
    public func assets(inAlbum albumID: String) -> [Asset] {
        (albumAssetIDs[albumID] ?? []).compactMap { assetsByID[$0] }
    }

    /// Assets showing a person, newest first. Empty for an unknown person.
    public func assets(withPerson personID: String) -> [Asset] {
        (personAssetIDs[personID] ?? []).compactMap { assetsByID[$0] }
    }

    /// Map markers for geotagged assets in the main timeline.
    public var mapMarkers: [MapMarker] {
        assets.compactMap { asset in
            guard !asset.isTrashed, !asset.isArchived,
                  let exif = asset.exif, let latitude = exif.latitude, let longitude = exif.longitude
            else { return nil }
            return MapMarker(id: asset.id, latitude: latitude, longitude: longitude,
                             city: exif.city, state: exif.state, country: exif.country)
        }
    }
}

// MARK: - Generation

private struct Generator {
    struct Place {
        var city: String
        var state: String?
        var country: String
        var latitude: Double
        var longitude: Double
        /// Hours ahead of UTC (ignoring DST, it's a mock).
        var utcOffset: Int
        var album: String?
    }

    struct PersonSeed {
        var name: String
        var birthday: DateComponents?
        var hidden: Bool = false
    }

    struct Camera {
        var make: String
        var model: String
        var lens: String
    }

    struct GeneratedAsset {
        var asset: Asset
        var people: [String]
    }

    static let places: [Place] = [
        Place(city: "Oslo", state: "Oslo", country: "Norway", latitude: 59.9139, longitude: 10.7522, utcOffset: 1, album: nil),
        Place(city: "Bergen", state: "Vestland", country: "Norway", latitude: 60.3913, longitude: 5.3221, utcOffset: 1, album: "Bergen"),
        Place(city: "Reine", state: "Nordland", country: "Norway", latitude: 67.9325, longitude: 13.0889, utcOffset: 1, album: "Summer in Lofoten"),
        Place(city: "Tokyo", state: nil, country: "Japan", latitude: 35.6762, longitude: 139.6503, utcOffset: 9, album: "Japan"),
        Place(city: "Lisbon", state: "Lisbon", country: "Portugal", latitude: 38.7223, longitude: -9.1393, utcOffset: 0, album: "Lisbon Weekend"),
        Place(city: "New York", state: "New York", country: "United States", latitude: 40.7128, longitude: -74.0060, utcOffset: -5, album: nil),
        Place(city: "Copenhagen", state: "Capital Region", country: "Denmark", latitude: 55.6761, longitude: 12.5683, utcOffset: 1, album: nil),
    ]

    static let personSeeds: [PersonSeed] = [
        PersonSeed(name: "Emma", birthday: DateComponents(year: 1992, month: 3, day: 14)),
        PersonSeed(name: "Lars", birthday: DateComponents(year: 1990, month: 6, day: 15)),
        PersonSeed(name: "Sofie", birthday: DateComponents(year: 2019, month: 9, day: 2)),
        PersonSeed(name: "Noah", birthday: nil),
        PersonSeed(name: "Ingrid", birthday: DateComponents(year: 1961, month: 11, day: 30)),
        PersonSeed(name: "", birthday: nil),
        PersonSeed(name: "Ex Colleague", birthday: nil, hidden: true),
    ]

    static let cameras: [Camera] = [
        Camera(make: "Apple", model: "iPhone 15 Pro", lens: "iPhone 15 Pro back triple camera 6.765mm f/1.78"),
        Camera(make: "Apple", model: "iPhone 12 mini", lens: "iPhone 12 mini back dual wide camera 4.2mm f/1.6"),
        Camera(make: "SONY", model: "ILCE-7M3", lens: "FE 24-70mm F2.8 GM"),
        Camera(make: "FUJIFILM", model: "X100V", lens: "23mm F2"),
    ]

    var rng: SplitMix64
    let referenceDate: Date
    let years: Int

    init(seed: UInt64, referenceDate: Date, years: Int) {
        rng = SplitMix64(seed: seed)
        self.referenceDate = referenceDate
        self.years = years
    }

    /// Stable UUID-shaped id, e.g. `0000000a-0000-4000-8000-00000000002a` for album 42.
    static func uuid(kind: Int, index: Int) -> String {
        String(format: "%08x-0000-4000-8000-%012x", kind, index)
    }

    mutating func makeAssets(count: Int) -> [GeneratedAsset] {
        let calendar = Asset.localCalendar
        let today = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        let start = calendar.date(byAdding: .year, value: -years, to: calendar.startOfDay(for: referenceDate))!
        // Random events end the day before the reference date, so nothing lies in the future.
        let span = calendar.startOfDay(for: referenceDate).timeIntervalSince(start) - 86_400

        // Event days: one "on this day" event per past year, the rest spread over the span.
        var events: [(day: Date, place: Place)] = []
        for yearsAgo in 1...years {
            let day = calendar.date(from: DateComponents(year: today.year! - yearsAgo, month: today.month, day: today.day))!
            events.append((day, Self.places[yearsAgo % Self.places.count]))
        }
        let eventCount = max(events.count, count / 7)
        while events.count < eventCount {
            let offset = rng.double() * span
            let day = calendar.startOfDay(for: start.addingTimeInterval(offset))
            events.append((day, Self.places[rng.weightedIndex([5, 2, 2, 1, 1, 1, 1])]))
        }

        var result: [GeneratedAsset] = []
        result.reserveCapacity(count)
        var liveIndex = 0
        for index in 0..<count {
            // First give every event one asset, then distribute the rest randomly.
            let event = index < events.count ? events[index] : events[rng.int(events.count)]
            let place = event.place
            let camera = Self.cameras[rng.weightedIndex([5, 3, 1, 1])]
            // Wall-clock time between 08:00 and 21:59 on the event day.
            let seconds = Double(8 * 3600 + rng.int(14 * 3600))
            let local = event.day.addingTimeInterval(seconds)
            let takenAt = local.addingTimeInterval(-Double(place.utcOffset * 3600))
            let isVideo = rng.chance(0.08)
            let isLive = !isVideo && camera.make == "Apple" && rng.chance(0.2)
            let portrait = rng.chance(0.35)
            let size: PixelSize
            if isVideo {
                size = portrait ? PixelSize(width: 1080, height: 1920) : PixelSize(width: 1920, height: 1080)
            } else if rng.chance(0.08) {
                size = PixelSize(width: 3024, height: 3024)
            } else {
                size = portrait ? PixelSize(width: 3024, height: 4032) : PixelSize(width: 4032, height: 3024)
            }
            let id = Self.uuid(kind: 0, index: index)
            var livePhotoVideoId: String?
            if isLive {
                livePhotoVideoId = Self.uuid(kind: 1, index: liveIndex)
                liveIndex += 1
            }
            let fileExtension = isVideo ? "MOV" : (camera.make == "Apple" ? "HEIC" : "JPG")
            let mimeType = isVideo ? "video/quicktime" : (camera.make == "Apple" ? "image/heic" : "image/jpeg")
            let exif = ExifInfo(
                make: camera.make, model: camera.model, lensModel: camera.lens,
                fNumber: [1.8, 2.0, 2.8, 4.0, 5.6][rng.int(5)],
                focalLength: [6.8, 4.2, 24, 35, 50, 70][rng.int(6)],
                iso: [50, 100, 200, 400, 800, 1600][rng.int(6)],
                exposureTime: ["1/60", "1/125", "1/250", "1/500", "1/1000"][rng.int(5)],
                dateTimeOriginal: takenAt,
                timeZone: place.utcOffset == 0 ? "UTC" : String(format: "UTC%+d", place.utcOffset),
                latitude: place.latitude + (rng.double() - 0.5) * 0.05,
                longitude: place.longitude + (rng.double() - 0.5) * 0.05,
                city: place.city, state: place.state, country: place.country,
                description: "",
                fileSizeInBytes: isVideo ? 20_000_000 + rng.int(80_000_000) : 1_500_000 + rng.int(4_000_000),
                imageWidth: size.width, imageHeight: size.height,
                orientation: "1",
                rating: nil
            )
            let asset = Asset(
                id: id,
                kind: isVideo ? .video : .image,
                takenAt: takenAt,
                localDateTime: local,
                size: size,
                isFavorite: rng.chance(0.08),
                isArchived: rng.chance(0.02),
                isTrashed: rng.chance(0.01),
                duration: isVideo ? Double(3 + rng.int(90)) : nil,
                livePhotoVideoId: livePhotoVideoId,
                originalFileName: String(format: "IMG_%04d.%@", 1000 + index, fileExtension),
                mimeType: mimeType,
                thumbhash: nil,
                exif: exif
            )
            // People: 0–3 faces, weighted so the first people appear most.
            var people: Set<String> = []
            let faces = rng.weightedIndex([5, 4, 2, 1])
            for _ in 0..<faces {
                let personIndex = rng.weightedIndex([8, 6, 5, 3, 2, 1, 1])
                people.insert(Self.uuid(kind: 0xB, index: personIndex))
            }
            result.append(GeneratedAsset(asset: asset, people: people.sorted()))
        }
        return result
    }
}

/// Small, fast, seedable PRNG (SplitMix64). Deterministic across platforms, unlike `SystemRandomNumberGenerator`.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `0..<upperBound`.
    mutating func int(_ upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(next() % UInt64(upperBound))
    }

    /// Uniform in `0..<1`.
    mutating func double() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func chance(_ probability: Double) -> Bool {
        double() < probability
    }

    mutating func weightedIndex(_ weights: [Int]) -> Int {
        var pick = int(weights.reduce(0, +))
        for (index, weight) in weights.enumerated() {
            if pick < weight { return index }
            pick -= weight
        }
        return weights.count - 1
    }
}
