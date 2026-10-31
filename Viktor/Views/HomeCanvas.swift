import SwiftUI

/// Home as a dashboard canvas: every widget has its own place and size. In Edit Home, drag a
/// widget to move it and its corner to resize it; both snap to a fine grid. When you let go,
/// nothing overlaps: what's in the way moves down and gaps close. New widgets are measured and
/// put at the bottom.
struct HomeCanvas: View {
    let keys: [String]
    let editing: Bool
    let content: (String) -> AnyView?
    let onRemove: (String) -> Void
    private var look: Appearance { Appearance.shared }

    @State private var width: CGFloat = 600
    /// Set once the real width is known; widgets aren't placed before that.
    @State private var widthKnown = false
    /// Natural heights of widgets that don't have a place yet.
    @State private var measured: [String: CGFloat] = [:]
    static let spacing: CGFloat = 10

    var body: some View {
        let placed = keys.filter { look.homeFrames[$0] != nil }
        let unplaced = keys.filter { look.homeFrames[$0] == nil }
        let bottom = placed.compactMap { look.homeFrames[$0] }.map { $0.y + $0.h }.max() ?? 0
        ZStack(alignment: .topLeading) {
            if editing { CanvasDots().frame(height: canvasHeight(bottom) ) }
            ForEach(Appearance.ordered(placed, by: look.homeOrder), id: \.self) { key in
                if let frame = look.homeFrames[key], let view = content(key) {
                    CanvasTile(key: key, frame: frame, canvasWidth: width, editing: editing,
                               onRemove: { onRemove(key) }, onCommit: { commit(key, $0) }) { view }
                }
            }
            // New widgets: measured off-screen at their default width, then given a place.
            ForEach(unplaced, id: \.self) { key in
                if let view = content(key) {
                    view
                        .frame(width: defaultWidth(key))
                        .fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: [key: g.size.height]) })
                        .hidden()
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: canvasHeight(bottom), alignment: .top)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { width = g.size.width; widthKnown = g.size.width > 0 }
                .onChange(of: g.size.width) { width = $1; widthKnown = $1 > 0 }
        })
        .onPreferenceChange(HeightKey.self) { heights in
            measured.merge(heights) { $1 }
            place(unplaced, below: bottom)
        }
        // Tidy up when Home opens and when widgets come or go: no overlaps, no gaps.
        .onAppear { tidy() }
        .onChange(of: keys) { tidy() }
    }

    /// A widget was dropped or resized: it takes that spot, the rest make room.
    private func commit(_ key: String, _ frame: Appearance.HomeFrame) {
        var frames = look.homeFrames
        frames[key] = frame
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { apply(frames, moved: key) }
    }

    private func tidy() { apply(look.homeFrames, moved: nil) }

    /// Resolves the shown widgets; hidden widgets keep their saved places.
    private func apply(_ frames: [String: Appearance.HomeFrame], moved: String?) {
        let shown = frames.filter { keys.contains($0.key) }
        let resolved = Appearance.resolve(shown, moved: moved, gap: Double(Self.spacing))
        let merged = frames.merging(resolved) { $1 }
        if merged != look.homeFrames { look.homeFrames = merged }
    }

    private func canvasHeight(_ bottom: Double) -> CGFloat {
        // Room below the last widget while editing, to drag things further down.
        CGFloat(bottom) + (editing ? 160 : 4)
    }

    private func defaultWidth(_ key: String) -> CGFloat {
        let f = look.size(of: key).fraction
        return max(80, f >= 0.999 ? width : (width + Self.spacing) * f - Self.spacing)
    }

    /// Gives new widgets a place under everything else, packed in rows by their default width.
    private func place(_ keys: [String], below bottom: Double) {
        let ready = keys.filter { measured[$0] != nil }
        guard !ready.isEmpty, widthKnown, width > 0 else { return }
        let places = HomeGrid.arrange(ready.map { look.size(of: $0).fraction }, width: width, spacing: Self.spacing)
        var rowTop = bottom > 0 ? bottom + Double(Self.spacing) : 0
        var currentRow = 0
        var rowHeight = 0.0
        var frames = look.homeFrames
        for (i, key) in ready.enumerated() {
            let p = places[i]
            if p.row != currentRow { rowTop += rowHeight + Double(Self.spacing); rowHeight = 0; currentRow = p.row }
            let h = Double(measured[key] ?? 120)
            rowHeight = max(rowHeight, h)
            frames[key] = Appearance.HomeFrame(x: Double(p.x / width), y: rowTop, w: Double((p.width + 0.5) / width), h: h).snapped()
        }
        apply(frames, moved: nil)
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue()) { $1 } }
}

/// One widget on the canvas. While editing: drag it to move, drag the corner to resize, × to remove.
private struct CanvasTile<Content: View>: View {
    let key: String
    let frame: Appearance.HomeFrame
    let canvasWidth: CGFloat
    let editing: Bool
    let onRemove: () -> Void
    let onCommit: (Appearance.HomeFrame) -> Void
    @ViewBuilder var content: Content

    @State private var move: CGSize = .zero
    @State private var grow: CGSize = .zero
    private var look: Appearance { Appearance.shared }

    var body: some View {
        let x = CGFloat(frame.x) * canvasWidth + move.width
        let y = CGFloat(frame.y) + move.height
        // A gap to the widget on the right (none at the right edge).
        let gap: CGFloat = frame.x + frame.w < 0.999 ? HomeCanvas.spacing : 0
        let w = max(CGFloat(Appearance.HomeFrame.minWidth) * canvasWidth - gap, CGFloat(frame.w) * canvasWidth - gap + grow.width)
        let h = max(CGFloat(Appearance.HomeFrame.minHeight), CGFloat(frame.h) + grow.height)
        content
            .frame(width: w, height: h, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .allowsHitTesting(!editing)
            .overlay { if editing { editChrome } }
            .offset(x: x, y: y)
            .zIndex(move != .zero || grow != .zero ? 10 : 0)
            .shadow(color: .black.opacity(move != .zero ? 0.4 : 0), radius: 16, y: 8)
    }

    private var editChrome: some View {
        ZStack(alignment: .topTrailing) {
            // The whole widget is the handle for moving it.
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(Color.white.opacity(0.4)))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { move = $0.translation }
                    .onEnded { _ in commit() })
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.black.opacity(0.75)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Remove from Home")
            .padding(8)
            // Bottom-right corner: drag to resize.
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.9)))
                .foregroundStyle(.black)
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { grow = $0.translation }
                    .onEnded { _ in commit() })
                .help("Drag to resize")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(4)
        }
    }

    private func commit() {
        guard canvasWidth > 0 else { return }
        let moved = Appearance.HomeFrame(
            x: frame.x + Double(move.width / canvasWidth),
            y: frame.y + Double(move.height),
            w: frame.w + Double(grow.width / canvasWidth),
            h: frame.h + Double(grow.height)
        ).snapped()
        onCommit(moved)
        move = .zero
        grow = .zero
    }
}

/// Dots on a grid behind the canvas while editing, so you can see where things snap.
private struct CanvasDots: View {
    var body: some View {
        Canvas { ctx, size in
            let colStep = size.width / CGFloat(Appearance.HomeFrame.columns)
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x <= size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(.white.opacity(0.12)))
                    x += colStep * 2
                }
                y += CGFloat(Appearance.HomeFrame.rowStep) * 4
            }
        }
        .allowsHitTesting(false)
    }
}
