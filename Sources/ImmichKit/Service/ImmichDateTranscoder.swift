import Foundation
import OpenAPIRuntime

/// Date transcoder for the generated client.
///
/// Immich sends timestamps with milliseconds (`2024-07-01T10:00:00.000Z`), which the runtime's default
/// `.iso8601` transcoder rejects. Decoding accepts ISO 8601 with or without fractional seconds
/// (via `ImmichDate.parse`); encoding writes milliseconds like the server.
struct ImmichDateTranscoder: DateTranscoder {
    private let encoder = ISO8601DateTranscoder.iso8601WithFractionalSeconds

    func encode(_ date: Date) throws -> String {
        try encoder.encode(date)
    }

    func decode(_ string: String) throws -> Date {
        guard let date = ImmichDate.parse(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Expected an ISO 8601 date."))
        }
        return date
    }
}
