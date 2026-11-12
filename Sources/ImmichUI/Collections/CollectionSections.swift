import SwiftUI

/// "Title ›" header (opening `destination` when given) above a horizontally scrolling row.
struct CollectionRow<Content: View>: View {
    let title: String
    var destination: AnyView?
    var fold: SectionFold?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let destination {
                    NavigationLink { destination } label: { header(chevron: true) }
                        .buttonStyle(.plain)
                } else {
                    header(chevron: false)
                }
                Spacer()
                if let fold { SectionFoldButton(title: title, fold: fold) }
            }
            .padding(.horizontal, 20)
            if fold?.isCollapsed != true {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) { content }
                        .padding(.horizontal, 20)
                }
                .scrollIndicators(.hidden)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func header(chevron: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.title2.weight(.bold))
            if chevron {
                Image(systemName: "chevron.right").font(.title3.weight(.bold)).foregroundStyle(.secondary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// "Title ›" header above two columns of rounded rows, like Media Types in Photos.
struct CollectionListSection<Content: View>: View {
    let title: String
    var fold: SectionFold?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let fold { SectionFoldButton(title: title, fold: fold) }
            }
            if fold?.isCollapsed != true {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    content
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 20)
    }
}

/// Whether a section is folded, and how to fold or open it.
struct SectionFold {
    let isCollapsed: Bool
    let toggle: () -> Void
}

/// Photos' round chevron next to a section title: points down while open, right when folded.
struct SectionFoldButton: View {
    let title: String
    let fold: SectionFold

    var body: some View {
        Button(action: fold.toggle) {
            Image(systemName: "chevron.down")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.tint)
                .rotationEffect(.degrees(fold.isCollapsed ? -90 : 0))
                .frame(width: 30, height: 30)
                .photosGlass(in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(CollectionSection.toggleLabel(title: title, isCollapsed: fold.isCollapsed))
    }
}

struct CollectionListRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(title).font(.body).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
