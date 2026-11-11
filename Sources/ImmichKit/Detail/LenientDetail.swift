import Foundation

/// Lenient decoding of `GET /assets/{id}` and `GET /memories` for servers whose responses do not
/// match the v3.4.0 spec (missing asset fields, or memory types this client does not know).
/// Reuses the lenient asset decoding from `LenientSearch`.
enum LenientDetail {
    struct MemoryDTO: Decodable {
        struct DataDTO: Decodable {
            var year: Int?
            var personId: String?
            var personName: String?
        }

        var id: String
        var type: String?
        var data: DataDTO?
        var memoryAt: String?
        var showAt: String?
        var hideAt: String?
        var seenAt: String?
        var isSaved: Bool?
        var assets: [LenientSearch.AssetDTO]?

        /// `nil` for memory types this client does not know.
        func memory() throws -> Memory? {
            guard let memoryAt = memoryAt.flatMap(ImmichDate.parse) else { throw ImmichServiceError.invalidResponse }
            let year = data?.year ?? Asset.localCalendar.component(.year, from: memoryAt)
            let kind: Memory.Kind
            switch type {
            case "on_this_day", nil:
                kind = .onThisDay(year: year)
            case "birthday":
                kind = .birthday(personId: data?.personId, personName: data?.personName, year: year)
            default:
                return nil
            }
            return Memory(
                id: id, kind: kind, memoryAt: memoryAt,
                showAt: showAt.flatMap(ImmichDate.parse), hideAt: hideAt.flatMap(ImmichDate.parse),
                seenAt: seenAt.flatMap(ImmichDate.parse), isSaved: isSaved ?? false,
                assets: try (assets ?? []).map { try $0.asset() }
            )
        }
    }

    static func asset(from data: Data) throws -> Asset {
        do {
            return try JSONDecoder().decode(LenientSearch.AssetDTO.self, from: data).asset()
        } catch {
            throw ImmichServiceError.invalidResponse
        }
    }

    static func memories(from data: Data) throws -> [Memory] {
        do {
            return try JSONDecoder().decode([MemoryDTO].self, from: data).compactMap { try $0.memory() }
        } catch {
            throw ImmichServiceError.invalidResponse
        }
    }
}
