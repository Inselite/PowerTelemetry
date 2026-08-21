import SwiftUI

/// Semantic system colors — the app follows the system's light/dark appearance
/// and accent conventions instead of shipping its own palette.
extension Color {
    static let ptBg      = Color(nsColor: .windowBackgroundColor)
    static let ptSurface = Color(nsColor: .controlBackgroundColor)
    static let ptBorder  = Color(nsColor: .separatorColor)
    static let ptText    = Color(nsColor: .labelColor)
    static let ptDim     = Color(nsColor: .secondaryLabelColor)
    static let ptFaint   = Color(nsColor: .tertiaryLabelColor)

    /// Series colors map to system hues so they stay legible in both appearances.
    static let ptAdapter = Color(nsColor: .systemOrange) // adapter / warnings
    static let ptCharge  = Color(nsColor: .systemBlue)   // battery charge
    static let ptLoad    = Color(nsColor: .secondaryLabelColor) // system load (neutral)
    static let ptOk      = Color(nsColor: .systemGreen)  // battery level
    static let ptLow     = Color(nsColor: .systemRed)    // battery level in the warning zone
}

extension Font {
    static let ptValue = Font.system(size: 26, weight: .medium).monospacedDigit()
    static let ptLabel = Font.system(size: 10, weight: .medium)
    static let ptDetail = Font.system(size: 10, weight: .regular).monospacedDigit()
}
