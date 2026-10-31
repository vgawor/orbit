import SwiftUI

/// Finance add-ons. Return each one here; they show up in Settings → Add-ons.
@MainActor
enum FinanceAddOns {
    static func make(_ ctx: AddOnContext) -> [any NotchModule] {
        [CurrencyAddOn(ctx), WatchlistAddOn(ctx), BudgetAddOn(ctx), SubscriptionsAddOn(ctx), VATAddOn(ctx)]
    }
}
