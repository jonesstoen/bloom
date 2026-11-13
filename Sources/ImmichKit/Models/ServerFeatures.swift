import Foundation

/// Which optional Immich features the server has turned on (`GET /server/features`).
///
/// Used to tell "nothing here" apart from "the server doesn't do this": for example no people
/// because facial recognition is off. A missing field counts as on, so an unknown or newer server
/// never makes Bloom claim that a feature is off.
public struct ServerFeatures: Sendable, Equatable, Decodable {
    public var facialRecognition: Bool
    public var smartSearch: Bool
    public var reverseGeocoding: Bool

    public init(facialRecognition: Bool = true, smartSearch: Bool = true, reverseGeocoding: Bool = true) {
        self.facialRecognition = facialRecognition
        self.smartSearch = smartSearch
        self.reverseGeocoding = reverseGeocoding
    }

    private enum CodingKeys: String, CodingKey { case facialRecognition, smartSearch, reverseGeocoding }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        facialRecognition = (try? container.decodeIfPresent(Bool.self, forKey: .facialRecognition)) ?? true
        smartSearch = (try? container.decodeIfPresent(Bool.self, forKey: .smartSearch)) ?? true
        reverseGeocoding = (try? container.decodeIfPresent(Bool.self, forKey: .reverseGeocoding)) ?? true
    }
}
