import SwiftUI

/// Stand-in for a module that is planned but not built yet. Shows which phase it lands in.
@MainActor
final class PlaceholderModule: NotchModule {
    let id: String
    let title: String
    let symbol: String
    let phase: Int
    let blurb: String

    init(id: String, title: String, symbol: String, phase: Int, blurb: String) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.phase = phase
        self.blurb = blurb
    }

    var panel: AnyView {
        AnyView(
            NotchCard {
                VStack(spacing: 8) {
                    Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(.white.opacity(0.85))
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(blurb).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    Text("Coming in phase \(phase)").font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        )
    }
}
