import SwiftUI

/// The same premium energy-monitor artwork used by the installed app icon.
/// Keeping the welcome mark tied to the asset prevents the old CCMB gauge
/// logo from drifting away from the product's public identity.
struct AppIconArtView: View {
    var body: some View {
        Image("CCMBBrandIcon")
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .aspectRatio(1, contentMode: .fit)
    }
}
