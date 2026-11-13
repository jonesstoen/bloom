import Foundation

/// A pull can close information only when its scroll gesture started at the top.
struct ViewerInfoPull {
    private var offset: CGFloat = 0
    private var beganAtTop = false
    private var isActive = false
    private var didClose = false

    mutating func begin() {
        beganAtTop = offset <= 1
        isActive = true
        didClose = false
    }

    mutating func updateOffset(_ offset: CGFloat) -> Bool {
        self.offset = offset
        guard isActive, beganAtTop, !didClose, offset < -100 else { return false }
        didClose = true
        return true
    }

    mutating func end() {
        isActive = false
    }
}
