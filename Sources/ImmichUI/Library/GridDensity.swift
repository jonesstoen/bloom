import Foundation

public enum GridDensity: Int, CaseIterable, Sendable {
    case three = 3, five = 5, seven = 7

    /// One step per completed pinch, with a dead zone to avoid accidental changes.
    public func pinched(by magnification: Double) -> GridDensity {
        guard magnification.isFinite, magnification > 0 else { return self }
        if magnification < 0.85 {
            switch self { case .three: return .five; case .five, .seven: return .seven }
        }
        if magnification > 1.15 {
            switch self { case .seven: return .five; case .five, .three: return .three }
        }
        return self
    }
}
