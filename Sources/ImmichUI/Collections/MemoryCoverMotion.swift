import ImmichKit
import SwiftUI

/// Keeps the slow image-only animation separate from the card's title and the collections row.
struct MemoryCoverMotion: View {
    let image: CGImage
    let isActive: Bool
    var zoomsIn = true
    @State private var progress = false

    private var scale: CGFloat {
        guard isActive else { return 1 }
        return progress == zoomsIn ? 1.06 : 1
    }

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFill()
            .scaleEffect(scale)
            .task(id: isActive) {
                if isActive {
                    withAnimation(.linear(duration: 5)) { progress = true }
                } else {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { progress = false }
                }
            }
    }
}

#Preview("Memory cover motion") {
    let mock = MockImmichService.preview
    MemoryCard(year: MemoryStoryModel.groupedYears(from: MockLibrary.standard.memories)[0],
               loader: ImageLoader(service: mock, disk: nil), animatesPreview: true)
}
