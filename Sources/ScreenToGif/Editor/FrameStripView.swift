import SwiftUI

/// 底部帧缩略图条（LazyHStack + 多选 ⌘/⇧ + 当前播放帧高亮）。
/// 对标原版 FrameListView。
struct FrameStripView: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 2) {
                    if let frames = viewModel.project?.frames {
                        ForEach(Array(frames.enumerated()), id: \.element.id) { index, frame in
                            FrameStripCell(
                                index: index,
                                frame: frame,
                                thumbnail: viewModel.thumbnail(for: index),
                                isCurrent: index == viewModel.currentIndex,
                                isSelected: viewModel.selection.contains(index)
                            )
                            .id(index)
                            .onTapGesture {
                                let mods = NSEvent.modifierFlags
                                viewModel.selectFrame(index, addToSelection: mods.contains(.command) || mods.contains(.shift))
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .onChange(of: viewModel.currentIndex) { _, newValue in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .background(Theme.panel2)
        .frame(height: 92)
    }
}

/// 单帧缩略图单元。
struct FrameStripCell: View {
    let index: Int
    let frame: FrameInfo
    let thumbnail: NSImage?
    let isCurrent: Bool
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 1) {
            ZStack {
                Rectangle()
                    .fill(Theme.control)
                    .frame(width: 86, height: 60)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 84, height: 58)
                }
            }
            .overlay(
                Rectangle().strokeBorder(
                    isCurrent ? Theme.selectionBorder : (isSelected ? Theme.accent : Theme.border),
                    lineWidth: isCurrent ? 2 : 1
                )
            )

            Text("#\(index + 1) · \(frame.delay)ms")
                .font(.system(size: 9, weight: .regular).monospacedDigit())
                .foregroundStyle(isSelected ? Theme.foreground : Theme.foreground2)
                .lineLimit(1)
        }
        .padding(.horizontal, 1)
    }
}
