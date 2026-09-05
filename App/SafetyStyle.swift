import SwiftUI
import LoupeCore

/// Colour for the reclaim list's safety levels.
///
/// This is the one place in the app where colour is allowed to carry risk, and
/// the direction matters: it runs from calm green at "rebuilds on this Mac" to
/// a serious red at "your own files", so the more dangerous a section is, the
/// less inviting it looks.
///
/// That is the opposite of what a cleaner app usually does. The genre convention
/// is to make everything look equally safe and equally selectable, because a
/// bigger reclaimable number sells better. Loupe is not allowed to do that: the
/// user has to be able to see, before reading a word, that the bottom of this
/// list is not the top of it.
extension SafetyLevel {
    var tint: Color {
        switch self {
        case .rebuildsLocally:  .green
        case .redownloads:      .teal
        case .redownloadsLarge: .yellow
        case .losesLocalState:  .orange
        case .userData:         .red
        }
    }

    var symbol: String {
        switch self {
        case .rebuildsLocally:   "hammer"
        case .redownloads:       "arrow.down.circle"
        case .redownloadsLarge:  "arrow.down.circle.fill"
        case .losesLocalState:   "exclamationmark.triangle"
        case .userData:          "person.crop.circle"
        }
    }
}
