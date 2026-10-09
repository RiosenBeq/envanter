import SwiftUI
import AppKit

// Apple "Liquid Glass" görünümü (macOS 26 Tahoe ile gelen yerel SwiftUI API'si: glassEffect).
// Eski sistemlerde (macOS 14–15) ya da eski Xcode ile derlendiğinde aynı yüzeyler buzlu cam
// malzemesiyle (Material) çizilir; görünüm benzer kalır, uygulama her sürümde çalışır.

extension View {
    /// Cam yüzey: içerik kartları, paneller, düğmeler.
    /// - tint: camın rengi (ör. birincil düğmede marka turuncusu)
    /// - interactive: basınca/üzerine gelince camın tepki vermesi (düğmeler için)
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self.frostedSurface(in: shape, tint: tint)
        }
        #else
        self.frostedSurface(in: shape, tint: tint)
        #endif
    }

    /// macOS 14–15 için buzlu cam karşılığı
    func frostedSurface<S: Shape>(in shape: S, tint: Color?) -> some View {
        self
            .background {
                ZStack {
                    shape.fill(.regularMaterial)
                    if let tint { shape.fill(tint.opacity(0.85)) }
                }
            }
            .overlay(shape.stroke(Color.white.opacity(0.28), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.07), radius: 10, x: 0, y: 4)
    }

    /// İçerik kartı yüzeyi: tablo ve grafiklerin okunaklı kalması için cam, pencere rengiyle hafifçe buzlanır.
    func contentGlass(cornerRadius: CGFloat = 18) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .clipShape(shape)
            .glassSurface(in: shape, tint: Brand.glassTint)
    }
}

extension Brand {
    /// İçerik kartlarındaki camın buzlanma rengi (açık/koyu modda pencere zemini)
    static let glassTint = Color(nsColor: .windowBackgroundColor).opacity(0.55)
}

/// Pencerenin zemini: cam yüzeylerin arkasında hafif renkli bir ortam ışığı.
/// Liquid Glass arkasındaki rengi kırarak gösterdiği için düz gri zemin yerine kullanılır.
struct AmbientBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Brand.accent.opacity(dark ? 0.22 : 0.20), .clear],
                           center: UnitPoint(x: 0.12, y: -0.05), startRadius: 0, endRadius: 760)
            RadialGradient(colors: [Brand.positive.opacity(dark ? 0.20 : 0.13), .clear],
                           center: UnitPoint(x: 1.0, y: 0.32), startRadius: 0, endRadius: 720)
            RadialGradient(colors: [Brand.ok.opacity(dark ? 0.14 : 0.09), .clear],
                           center: UnitPoint(x: 0.42, y: 1.08), startRadius: 0, endRadius: 680)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
