import Foundation
import ImmichAPI
import XCTest
@testable import ImmichKit

/// Decodes JSON fixtures (shaped like real server responses per the spec) into generated DTOs,
/// then checks the mapping to domain models.
final class DomainModelTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: string))
        }
        return try decoder.decode(type, from: Data(json.utf8))
    }

    private func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)!
    }

    private static let exifJSON = """
    {
      "make": "Apple", "model": "iPhone 15 Pro", "lensModel": "iPhone 15 Pro back camera 6.765mm f/1.78",
      "fNumber": 1.78, "focalLength": 6.765, "iso": 64, "exposureTime": "1/250",
      "dateTimeOriginal": "2024-06-01T18:30:00.000Z", "timeZone": "Europe/Oslo",
      "latitude": 59.9139, "longitude": 10.7522, "city": "Oslo", "state": "Oslo", "country": "Norway",
      "description": "", "fileSizeInByte": 2456789, "exifImageWidth": 4032, "exifImageHeight": 3024,
      "orientation": "6", "rating": null, "projectionType": null
    }
    """

    private static func assetJSON(
        id: String = "a1", type: String = "IMAGE", width: String = "3024", height: String = "4032",
        duration: String = "null", livePhoto: String = "null", exif: String? = nil,
        isArchived: Bool = false, visibility: String = "timeline"
    ) -> String {
        """
        {
          "id": "\(id)", "checksum": "abc=", "type": "\(type)",
          "createdAt": "2024-06-02T08:00:00.000Z",
          "fileCreatedAt": "2024-06-01T18:30:00.000Z",
          "fileModifiedAt": "2024-06-01T18:30:00.000Z",
          "localDateTime": "2024-06-01T20:30:00.000Z",
          "updatedAt": "2024-06-02T08:00:00.000Z",
          "hasMetadata": true, "isArchived": \(isArchived), "isEdited": false, "isFavorite": true,
          "isOffline": false, "isTrashed": false, "visibility": "\(visibility)",
          "originalFileName": "IMG_0001.HEIC", "originalMimeType": "image/heic",
          "originalPath": "/upload/IMG_0001.HEIC", "ownerId": "u1",
          "width": \(width), "height": \(height), "duration": \(duration),
          "livePhotoVideoId": \(livePhoto), "thumbhash": "1QcSHQRnh493V4dIh4eXh1h4kJUI"
          \(exif.map { ", \"exifInfo\": \($0)" } ?? "")
        }
        """
    }

    // MARK: Asset

    func testImageAssetMapping() throws {
        let dto = try decode(Components.Schemas.AssetResponseDto.self, Self.assetJSON(exif: Self.exifJSON))
        let asset = Asset(dto: dto)

        XCTAssertEqual(asset.id, "a1")
        XCTAssertEqual(asset.kind, .image)
        XCTAssertEqual(asset.takenAt, date("2024-06-01T18:30:00.000Z"))
        XCTAssertEqual(asset.localDateTime, date("2024-06-01T20:30:00.000Z"))
        XCTAssertEqual(asset.size, PixelSize(width: 3024, height: 4032))
        XCTAssertTrue(asset.isFavorite)
        XCTAssertFalse(asset.isArchived)
        XCTAssertNil(asset.duration)
        XCTAssertFalse(asset.isLivePhoto)
        XCTAssertFalse(asset.isVideo)
        XCTAssertEqual(asset.originalFileName, "IMG_0001.HEIC")
        XCTAssertEqual(asset.mimeType, "image/heic")
        XCTAssertEqual(asset.thumbhash, "1QcSHQRnh493V4dIh4eXh1h4kJUI")
        XCTAssertEqual(asset.exif?.city, "Oslo")
    }

    func testLocalDayUsesUTCCalendar() throws {
        // Taken 23:30 local time on June 1st in UTC+2: UTC moment is 21:30, localDateTime is 23:30 "UTC".
        var json = Self.assetJSON()
        json = json.replacingOccurrences(of: "\"localDateTime\": \"2024-06-01T20:30:00.000Z\"",
                                         with: "\"localDateTime\": \"2024-06-01T23:30:00.000Z\"")
        let asset = Asset(dto: try decode(Components.Schemas.AssetResponseDto.self, json))
        let components = Asset.localCalendar.dateComponents([.year, .month, .day, .hour], from: asset.localDateTime)
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 6)
        XCTAssertEqual(components.day, 1)
        XCTAssertEqual(components.hour, 23)
    }

    func testVideoDurationIsConvertedFromMilliseconds() throws {
        let dto = try decode(Components.Schemas.AssetResponseDto.self,
                             Self.assetJSON(type: "VIDEO", duration: "12345"))
        let asset = Asset(dto: dto)
        XCTAssertEqual(asset.kind, .video)
        XCTAssertTrue(asset.isVideo)
        XCTAssertEqual(asset.duration!, 12.345, accuracy: 0.0001)
    }

    func testZeroDurationMeansNoDuration() throws {
        let dto = try decode(Components.Schemas.AssetResponseDto.self, Self.assetJSON(duration: "0"))
        XCTAssertNil(Asset(dto: dto).duration)
    }

    func testLivePhotoLink() throws {
        let dto = try decode(Components.Schemas.AssetResponseDto.self, Self.assetJSON(livePhoto: "\"v42\""))
        let asset = Asset(dto: dto)
        XCTAssertTrue(asset.isLivePhoto)
        XCTAssertEqual(asset.livePhotoVideoId, "v42")
    }

    func testArchivedViaVisibility() throws {
        let dto = try decode(Components.Schemas.AssetResponseDto.self, Self.assetJSON(visibility: "archive"))
        XCTAssertTrue(Asset(dto: dto).isArchived)
    }

    func testSizeFallsBackToRotatedExifDimensions() throws {
        let dto = try decode(Components.Schemas.AssetResponseDto.self,
                             Self.assetJSON(width: "null", height: "null", exif: Self.exifJSON))
        // EXIF says 4032x3024 with orientation 6 (rotated 90°), so the displayed size is portrait.
        XCTAssertEqual(Asset(dto: dto).size, PixelSize(width: 3024, height: 4032))
    }

    func testSizeIsNilWithoutDimensions() throws {
        let dto = try decode(Components.Schemas.AssetResponseDto.self, Self.assetJSON(width: "null", height: "null"))
        XCTAssertNil(Asset(dto: dto).size)
    }

    func testAllAssetTypes() {
        XCTAssertEqual(Asset.Kind(.image), .image)
        XCTAssertEqual(Asset.Kind(.video), .video)
        XCTAssertEqual(Asset.Kind(.audio), .audio)
        XCTAssertEqual(Asset.Kind(.other), .other)
    }

    func testAspectRatio() {
        XCTAssertEqual(PixelSize(width: 4000, height: 3000).aspectRatio, 4.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(PixelSize(width: 0, height: 3000).aspectRatio, 1)
    }

    // MARK: Exif

    func testExifMapping() throws {
        let exif = ExifInfo(dto: try decode(Components.Schemas.ExifResponseDto.self, Self.exifJSON))
        XCTAssertEqual(exif.make, "Apple")
        XCTAssertEqual(exif.model, "iPhone 15 Pro")
        XCTAssertEqual(exif.fNumber, 1.78)
        XCTAssertEqual(exif.focalLength, 6.765)
        XCTAssertEqual(exif.iso, 64)
        XCTAssertEqual(exif.exposureTime, "1/250")
        XCTAssertEqual(exif.dateTimeOriginal, date("2024-06-01T18:30:00.000Z"))
        XCTAssertEqual(exif.timeZone, "Europe/Oslo")
        XCTAssertEqual(exif.latitude, 59.9139)
        XCTAssertEqual(exif.longitude, 10.7522)
        XCTAssertEqual(exif.fileSizeInBytes, 2_456_789)
        XCTAssertEqual(exif.imageWidth, 4032)
        XCTAssertEqual(exif.imageHeight, 3024)
        XCTAssertNil(exif.rating)
        XCTAssertTrue(exif.swapsDimensions)
        XCTAssertEqual(exif.cameraName, "Apple iPhone 15 Pro")
        XCTAssertEqual(exif.locationName, "Oslo, Norway")
    }

    func testCameraNameDeduplicatesMake() {
        XCTAssertEqual(ExifInfo(make: "Canon", model: "Canon EOS R5").cameraName, "Canon EOS R5")
        XCTAssertEqual(ExifInfo(make: "Apple").cameraName, "Apple")
        XCTAssertNil(ExifInfo(make: " ", model: nil).cameraName)
    }

    func testLocationName() {
        XCTAssertEqual(ExifInfo(city: "Bergen", country: "Norway").locationName, "Bergen, Norway")
        XCTAssertEqual(ExifInfo(country: "Norway").locationName, "Norway")
        XCTAssertNil(ExifInfo().locationName)
    }

    // MARK: Album

    func testAlbumMapping() throws {
        let json = """
        {
          "id": "al1", "albumName": "Summer", "description": "Holiday", "albumThumbnailAssetId": "a1",
          "albumUsers": [], "assetCount": 42, "createdAt": "2024-07-01T10:00:00.000Z",
          "updatedAt": "2024-07-02T10:00:00.000Z", "startDate": "2024-06-01T00:00:00.000Z",
          "endDate": "2024-06-30T00:00:00.000Z", "hasSharedLink": false, "isActivityEnabled": true,
          "shared": true, "order": "asc"
        }
        """
        let album = Album(dto: try decode(Components.Schemas.AlbumResponseDto.self, json))
        XCTAssertEqual(album.id, "al1")
        XCTAssertEqual(album.name, "Summer")
        XCTAssertEqual(album.description, "Holiday")
        XCTAssertEqual(album.assetCount, 42)
        XCTAssertEqual(album.thumbnailAssetId, "a1")
        XCTAssertEqual(album.startDate, date("2024-06-01T00:00:00.000Z"))
        XCTAssertEqual(album.endDate, date("2024-06-30T00:00:00.000Z"))
        XCTAssertEqual(album.createdAt, date("2024-07-01T10:00:00.000Z"))
        XCTAssertEqual(album.updatedAt, date("2024-07-02T10:00:00.000Z"))
        XCTAssertTrue(album.isShared)
        XCTAssertFalse(album.isNewestFirst)
    }

    func testAlbumWithoutOrderIsNewestFirst() throws {
        let json = """
        {
          "id": "al2", "albumName": "Empty", "description": "", "albumUsers": [], "assetCount": 0,
          "createdAt": "2024-07-01T10:00:00Z", "updatedAt": "2024-07-01T10:00:00Z",
          "hasSharedLink": false, "isActivityEnabled": false, "shared": false
        }
        """
        let album = Album(dto: try decode(Components.Schemas.AlbumResponseDto.self, json))
        XCTAssertTrue(album.isNewestFirst)
        XCTAssertNil(album.thumbnailAssetId)
        XCTAssertNil(album.startDate)
    }

    // MARK: Person

    func testPersonMapping() throws {
        let json = """
        {
          "id": "p1", "name": "Kari", "birthDate": "1990-03-15", "isHidden": false, "isFavorite": true,
          "thumbnailPath": "/thumbs/p1.jpeg", "updatedAt": "2024-01-01T00:00:00.000Z",
          "otherPeople": [], "sharedBy": [], "sharedWith": []
        }
        """
        let person = Person(dto: try decode(Components.Schemas.PersonResponseDto.self, json))
        XCTAssertEqual(person.id, "p1")
        XCTAssertEqual(person.name, "Kari")
        XCTAssertTrue(person.isNamed)
        XCTAssertEqual(person.birthDate, DateComponents(year: 1990, month: 3, day: 15))
        XCTAssertFalse(person.isHidden)
        XCTAssertTrue(person.isFavorite)
        XCTAssertEqual(person.updatedAt, date("2024-01-01T00:00:00.000Z"))
    }

    func testUnnamedPersonWithoutOptionalFields() throws {
        let json = """
        {
          "id": "p2", "name": "", "isHidden": true, "thumbnailPath": "",
          "otherPeople": [], "sharedBy": [], "sharedWith": []
        }
        """
        let person = Person(dto: try decode(Components.Schemas.PersonResponseDto.self, json))
        XCTAssertFalse(person.isNamed)
        XCTAssertNil(person.birthDate)
        XCTAssertTrue(person.isHidden)
        XCTAssertFalse(person.isFavorite)
    }

    func testBirthDateParsing() {
        XCTAssertEqual(Person.parseBirthDate("2001-12-31T00:00:00.000Z"), DateComponents(year: 2001, month: 12, day: 31))
        XCTAssertNil(Person.parseBirthDate("garbage"))
        XCTAssertNil(Person.parseBirthDate("2001-13-01"))
    }

    // MARK: Memory

    func testOnThisDayMemoryMapping() throws {
        let json = """
        {
          "id": "m1", "type": "on_this_day", "data": { "year": 2021 },
          "memoryAt": "2021-11-11T00:00:00.000Z", "showAt": "2026-11-11T00:00:00.000Z",
          "hideAt": "2026-11-12T00:00:00.000Z", "createdAt": "2026-11-11T00:00:00.000Z",
          "updatedAt": "2026-11-11T00:00:00.000Z", "isSaved": false, "ownerId": "u1",
          "assets": [\(Self.assetJSON(id: "a1")), \(Self.assetJSON(id: "a2", type: "VIDEO", duration: "3000"))]
        }
        """
        let memory = Memory(dto: try decode(Components.Schemas.MemoryResponseDto.self, json))
        XCTAssertEqual(memory.id, "m1")
        XCTAssertEqual(memory.kind, .onThisDay(year: 2021))
        XCTAssertEqual(memory.year, 2021)
        XCTAssertEqual(memory.memoryAt, date("2021-11-11T00:00:00.000Z"))
        XCTAssertEqual(memory.showAt, date("2026-11-11T00:00:00.000Z"))
        XCTAssertEqual(memory.hideAt, date("2026-11-12T00:00:00.000Z"))
        XCTAssertNil(memory.seenAt)
        XCTAssertFalse(memory.isSaved)
        XCTAssertEqual(memory.assets.map(\.id), ["a1", "a2"])
        XCTAssertEqual(memory.assets[1].duration, 3)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(memory.title(now: date("2026-11-11T12:00:00Z"), calendar: calendar), "5 years ago")
        XCTAssertEqual(Memory(id: "x", kind: .onThisDay(year: 2025), memoryAt: Date(), assets: [])
            .title(now: date("2026-11-11T12:00:00Z"), calendar: calendar), "1 year ago")
    }

    func testBirthdayMemoryMapping() throws {
        let json = """
        {
          "id": "m2", "type": "birthday", "data": { "year": 2020, "personId": "p1", "personName": "Kari" },
          "memoryAt": "2020-03-15T00:00:00.000Z", "createdAt": "2026-03-15T00:00:00.000Z",
          "updatedAt": "2026-03-15T00:00:00.000Z", "isSaved": true, "ownerId": "u1", "assets": []
        }
        """
        let memory = Memory(dto: try decode(Components.Schemas.MemoryResponseDto.self, json))
        XCTAssertEqual(memory.kind, .birthday(personId: "p1", personName: "Kari", year: 2020))
        XCTAssertTrue(memory.isSaved)
        XCTAssertEqual(memory.title(), "Kari's birthday")
    }

    // MARK: Map

    func testMapMarkerMapping() throws {
        let json = """
        [
          { "id": "a1", "lat": 59.9139, "lon": 10.7522, "city": "Oslo", "state": "Oslo", "country": "Norway" },
          { "id": "a2", "lat": -33.86, "lon": 151.21, "city": null, "state": null, "country": null }
        ]
        """
        let markers = try decode([Components.Schemas.MapMarkerResponseDto].self, json).map(MapMarker.init(dto:))
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(markers[0], MapMarker(id: "a1", latitude: 59.9139, longitude: 10.7522,
                                             city: "Oslo", state: "Oslo", country: "Norway"))
        XCTAssertEqual(markers[1].assetId, "a2")
        XCTAssertEqual(markers[1].latitude, -33.86)
        XCTAssertNil(markers[1].city)
    }

    // MARK: Codable round trip (domain models are cached on disk later)

    func testDomainModelsRoundTripThroughCodable() throws {
        let asset = Asset(dto: try decode(Components.Schemas.AssetResponseDto.self, Self.assetJSON(exif: Self.exifJSON)))
        let memory = Memory(id: "m", kind: .birthday(personId: nil, personName: nil, year: 2000),
                            memoryAt: Date(timeIntervalSince1970: 0), assets: [asset])
        let data = try JSONEncoder().encode(memory)
        XCTAssertEqual(try JSONDecoder().decode(Memory.self, from: data), memory)
    }
}
