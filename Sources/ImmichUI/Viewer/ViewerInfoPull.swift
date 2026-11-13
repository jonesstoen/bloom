import Foundation

/// Scroll geometry gates the start; the native pan supplies the actual finger translation.
struct ViewerInfoPull {
    private var offset: CGFloat = 0
    private var beganAtTop = false
    private(set) var isActive = false
    private var didClose = false
    var canStart: Bool { offset <= 1 }

    mutating func updateDrag(_ translation: CGSize) -> Bool {
        guard isActive, beganAtTop, !didClose,
              translation.height > 100,
              translation.height > abs(translation.width) * 1.5 else { return false }
        didClose = true
        return true
    }

    mutating func begin() {
        beganAtTop = canStart
        isActive = true
        didClose = false
    }

    mutating func updateOffset(_ offset: CGFloat) {
        self.offset = offset
    }

    mutating func end() {
        isActive = false
    }
}
