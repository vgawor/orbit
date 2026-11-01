import SwiftUI

/// AI add-ons. Return each one here; they show up in Settings → Add-ons.
/// All of them use Claude through `ClaudeAPI` and only send when you press a button.
@MainActor
enum AIAddOns {
    static func make(_ ctx: AddOnContext) -> [any NotchModule] {
        [
            PromptLibraryAddOn(ctx),
            SummarizeAddOn(ctx),
            TranslateAddOn(ctx),
            RewriteAddOn(ctx),
            ActionItemsAddOn(ctx),
        ]
    }
}
