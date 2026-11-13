#if os(iOS)
import XCTest
import UIKit
@testable import ImmichUI

@MainActor
final class ViewerDismissNativeTests: XCTestCase {
    func testNativePanConfigurationAndDirectionDelegate() {
        var gesture = ViewerDismissGesture(isZoomed: false, blocked: false, onChanged: { _ in }, onEnded: { _ in }, onCancelled: {})
        let coordinator = ViewerDismissGesture.Coordinator(isZoomed: false, blocked: false)
        let pan = gesture.makeRecognizer(coordinator: coordinator)
        XCTAssertTrue(pan.isEnabled)
        XCTAssertEqual(pan.maximumNumberOfTouches, 1)
        XCTAssertTrue(pan.delegate === coordinator)
        let input = ScriptedDismissPan()
        input.velocityValue = CGPoint(x: 0, y: 120)
        XCTAssertTrue(coordinator.gestureRecognizerShouldBegin(input))
        input.velocityValue = CGPoint(x: 120, y: 10)
        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(input))
        input.velocityValue = CGPoint(x: 0, y: -120)
        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(input))
        gesture.isZoomed = true
        gesture.configure(pan, coordinator: coordinator)
        input.velocityValue = CGPoint(x: 0, y: 120)
        XCTAssertFalse(pan.isEnabled)
        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(input))
        gesture.isZoomed = false
        gesture.blocked = true
        gesture.configure(pan, coordinator: coordinator)
        XCTAssertFalse(pan.isEnabled)
        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(input))
        gesture.blocked = false
        gesture.configure(pan, coordinator: coordinator)
        XCTAssertTrue(pan.isEnabled)
        XCTAssertTrue(coordinator.gestureRecognizerShouldBegin(input))
    }

    func testInformationSwipeOptInAndSimultaneousPaging() {
        let gesture = ViewerDismissGesture(isZoomed: false, blocked: false, allowsUp: true,
                                          onChanged: { _ in }, onEnded: { _ in }, onCancelled: {})
        let coordinator = ViewerDismissGesture.Coordinator(isZoomed: false, blocked: false, allowsUp: true)
        let input = ScriptedDismissPan()
        input.velocityValue = CGPoint(x: 0, y: -120)
        XCTAssertTrue(coordinator.gestureRecognizerShouldBegin(input))
        XCTAssertTrue(coordinator.gestureRecognizer(input, shouldRecognizeSimultaneouslyWith: UIPanGestureRecognizer()))
        let pan = gesture.makeRecognizer(coordinator: coordinator)
        XCTAssertTrue(pan.isEnabled)
    }

    func testNativeActionRoutesChangesCompletionAndCancellation() {
        var offsets: [CGSize] = []
        var ends: [CGSize] = []
        var cancellations = 0
        let gesture = ViewerDismissGesture(isZoomed: false, blocked: false, onChanged: { offsets.append($0) }, onEnded: { ends.append($0) }, onCancelled: { cancellations += 1 })
        let pan = ScriptedDismissPan()
        pan.translationValue = CGPoint(x: 10, y: 150)
        for phase: UIGestureRecognizer.State in [.possible, .began, .changed, .ended, .cancelled, .failed] {
            pan.phase = phase
            gesture.dispatch(pan)
        }
        XCTAssertEqual(offsets, [CGSize(width: 10, height: 150), CGSize(width: 10, height: 150)])
        XCTAssertEqual(ends, [CGSize(width: 10, height: 150)])
        XCTAssertEqual(cancellations, 2)
    }
}

@MainActor
private final class ScriptedDismissPan: UIPanGestureRecognizer {
    var phase: UIGestureRecognizer.State = .possible
    var translationValue: CGPoint = .zero
    var velocityValue: CGPoint = .zero
    override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
    override func translation(in view: UIView?) -> CGPoint { translationValue }
    override func velocity(in view: UIView?) -> CGPoint { velocityValue }
}
#endif
