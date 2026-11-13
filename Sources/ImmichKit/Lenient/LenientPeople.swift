import Foundation

/// Decodes `GET /people` and `GET /people/{id}` without the fields the v3.4.0 spec requires
/// but older servers do not send (`otherPeople`, `sharedBy`, `sharedWith`, `thumbnailPath`).
/// Used by `LiveImmichService` when the strict generated decoder fails.
enum LenientPeople {
    struct PersonDTO: Decodable {
        var id: String
        var name: String?
        var birthDate: String?
        var isHidden: Bool?
        var isFavorite: Bool?
        var updatedAt: String?

        var person: Person {
            Person(
                id: id,
                name: name ?? "",
                birthDate: birthDate.flatMap(Person.parseBirthDate),
                isHidden: isHidden ?? false,
                isFavorite: isFavorite ?? false,
                updatedAt: updatedAt.flatMap(ImmichDate.parse)
            )
        }
    }

    struct PageDTO: Decodable {
        var people: [PersonDTO]
        var hasNextPage: Bool?
    }

    static func page(from data: Data) throws -> (people: [Person], hasNextPage: Bool) {
        do {
            let page = try JSONDecoder().decode(PageDTO.self, from: data)
            return (page.people.map(\.person), page.hasNextPage ?? false)
        } catch {
            throw ImmichServiceError.invalidResponse
        }
    }

    static func person(from data: Data) throws -> Person {
        do {
            return try JSONDecoder().decode(PersonDTO.self, from: data).person
        } catch {
            throw ImmichServiceError.invalidResponse
        }
    }
}
