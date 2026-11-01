import AppKit
import SwiftUI

/// Small floating panel that holds the drawing toolbar. Sits above the overlays and never
/// takes keyboard focus, so keys keep going to the overlay you're drawing on.
final class DrawingToolbarPanel: NSPanel {
    init(controller: DrawingController) {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: DrawingOverlayWindow.overlayLevel.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // Moved by the grip handle only, so dragging on a button never moves the bar.
        isMovable = true
        isMovableByWindowBackground = false

        let host = ClickThroughHostingView(rootView: DrawingToolbarView(controller: controller))
        contentView = host
        setContentSize(host.fittingSize)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The toolbar itself: grip · tools · colors · widths · undo/clear · click-through · Done.
struct DrawingToolbarView: View {
    @ObservedObject var controller: DrawingController

    var body: some View {
        HStack(spacing: 4) {
            WindowDragHandle()
                .frame(width: 14, height: 28)
                .overlay {
                    Image(systemName: "line.3.horizontal")
                        .rotationEffect(.degrees(90))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Tokens.faint)
                        .allowsHitTesting(false)
                }
                .help("Drag to move")

            ForEach(DrawingTool.allCases) { tool in
                DrawToolButton(symbol: tool.symbol, selected: controller.tool == tool, help: tool.title) {
                    controller.tool = tool
                }
            }

            divider

            ForEach(DrawingPalette.colors.indices, id: \.self) { i in
                ColorDot(color: Color(nsColor: DrawingPalette.colors[i]),
                         selected: controller.colorIndex == i,
                         help: "\(DrawingPalette.names[i]) (\(i + 1))") {
                    controller.colorIndex = i
                    if controller.tool == .eraser { controller.tool = .pen }
                }
            }

            divider

            ForEach(DrawingWidths.all.indices, id: \.self) { i in
                WidthButton(dot: 3 + CGFloat(i) * 3, selected: controller.widthIndex == i,
                            help: "\(Int(DrawingWidths.all[i])) pt") {
                    controller.widthIndex = i
                }
            }

            divider

            DrawToolButton(symbol: "arrow.uturn.backward", selected: false, help: "Undo (⌘Z)") {
                controller.undo()
            }
            .opacity(controller.canUndo ? 1 : 0.4)
            DrawToolButton(symbol: "trash", selected: false, help: "Clear all (⌘K)") {
                controller.clear()
            }
            DrawToolButton(symbol: "cursorarrow.click.2", selected: controller.clickThrough,
                           tint: Tokens.live, help: "Click-through (T): work below your marks") {
                controller.clickThrough.toggle()
            }

            Button { controller.stop() } label: {
                Text("Done")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(.plain)
            .help("Done (Esc)")
            .padding(.leading, 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .foregroundStyle(.white)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Tokens.stroke))
        .fixedSize()
    }

    private var divider: some View {
        Rectangle().fill(Tokens.stroke).frame(width: 1, height: 18).padding(.horizontal, 3)
    }
}

/// Square icon button; filled when it's the current choice.
private struct DrawToolButton: View {
    let symbol: String
    let selected: Bool
    var tint: Color = .white
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? tint : Tokens.secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected || hovering ? Tokens.surface2 : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// A color swatch with a white ring when chosen.
private struct ColorDot: View {
    let color: Color
    let selected: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1)) // so black shows on black
                .padding(3)
                .overlay(Circle().stroke(selected ? Color.white : .clear, lineWidth: 1.5))
                .frame(width: 22, height: 28)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Line width choice, drawn as a dot of that size.
private struct WidthButton: View {
    let dot: CGFloat
    let selected: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(selected ? Color.white : Tokens.secondary)
                .frame(width: dot, height: dot)
                .frame(width: 22, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Tokens.surface2 : .clear))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A patch of AppKit that moves its window when you drag it. Used as the toolbar's grip.
private struct WindowDragHandle: NSViewRepresentable {
    final class HandleView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }

    func makeNSView(context: Context) -> NSView { HandleView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
