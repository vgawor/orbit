import SwiftUI

/// Health add-ons. Return each one here; they show up in Settings → Add-ons.
/// Friendly wellbeing nudges, not medical advice.
@MainActor
enum HealthAddOns {
    static func make(_ ctx: AddOnContext) -> [any NotchModule] {
        [WaterAddOn(ctx), BreaksAddOn(ctx), BreatheAddOn(ctx), ScreenTimeAddOn(ctx), MoodAddOn(ctx)]
    }
}
