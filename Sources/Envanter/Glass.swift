import SwiftUI
import AppKit

// Sade ve keskin görünüm (web paneliyle aynı ölçüler): düz pencere zemini, düz kart yüzeyi ve 1 px çizgi.
// Cam, bulanıklık, yarı saydam yüzey, renkli degrade zemin ve kart gölgesi yoktur; yalnızca yüzen katmanlarda
// (gün dönümü şeridi, pencere önizlemesi) çok hafif bir gölge kalır. Köşe ve renk değerleri tek yerde tutulur.

/// Köşe yarıçapları (web paneliyle aynı ölçek: 2 / 4 / 6 / 8 px). Tam yuvarlak şekil yalnızca durum noktası,
/// ilerleme çubuğu ve anahtar düğmede kalır.
enum Radius {
    /// Küçük rozet, renk açıklaması karesi, grafik çubuğu
    static let tiny: CGFloat = 3
    /// Düğme, giriş alanı, seçici, etiket (Pill), menü öğesi, bildirim şeridi
    static let control: CGFloat = 6
    /// Kart, panel, tablo, bilgi kutusu, yan menü satırı
    static let container: CGFloat = 8
    /// Sayfa penceresi / iletişim kutusu dış köşesi (en büyük değer)
    static let sheet: CGFloat = 12
}

/// Ölçekteki köşe şekilleri (hepsi aynı köşe stiliyle çizilir)
enum Shapes {
    static func rounded(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
    static var tiny: RoundedRectangle { rounded(Radius.tiny) }
    static var control: RoundedRectangle { rounded(Radius.control) }
    static var container: RoundedRectangle { rounded(Radius.container) }
    static var sheet: RoundedRectangle { rounded(Radius.sheet) }
}

extension Brand {
    /// Pencere zemini (düz): açık #f6f6f4, koyu #111113
    static let page = Color(nsColor: .adaptive(light: .hex(0xF6F6F4), dark: .hex(0x111113)))
    /// Kart, panel ve yan menü yüzeyi: açık beyaz, koyu #1a1a1d
    static let card = Color(nsColor: .adaptive(light: .hex(0xFFFFFF), dark: .hex(0x1A1A1D)))
    /// Giriş alanı zemini: kartla aynı (açık beyaz, koyu kart rengi)
    static let field = card
    /// 1 px çizgi (kart kenarı, giriş alanı, tablo satır ayırıcı): açıkta siyah %9, koyuda beyaz %9.
    /// "Karşıtlığı artır" açıkken belirgin çizilir.
    static let line = Color(nsColor: .adaptive(light: .hex(0x000000, alpha: 0.09), dark: .hex(0xFFFFFF, alpha: 0.09),
                                               lightContrast: .hex(0x000000, alpha: 0.45),
                                               darkContrast: .hex(0xFFFFFF, alpha: 0.5)))
    /// Satır / düğme üzerine gelme tonu: açıkta siyah %2,5, koyuda beyaz %4
    static let hover = Color(nsColor: .adaptive(light: .hex(0x000000, alpha: 0.025), dark: .hex(0xFFFFFF, alpha: 0.04)))
    /// Basılı ikincil düğme tonu
    static let pressed = Color(nsColor: .adaptive(light: .hex(0x000000, alpha: 0.06), dark: .hex(0xFFFFFF, alpha: 0.08)))
    /// Tablo başlığı zemini (opak zeminin üstünde düz görünür; zebra satır yoktur)
    static let header = Color.primary.opacity(0.04)
    /// Seçili satır / yan menü öğesi zemini (marka renginin %10'u)
    static let selection = accent.opacity(0.10)
    /// Birincil düğmenin üzerine gelince ve basılıyken rengi (#c2470e)
    static let accentHover = Color(nsColor: .hex(0xC2470E))
    /// Ana düğme dolgusu: marka turuncusunun koyu tonu (beyaz yazı 5,0:1, WCAG AA); üzerine gelince daha koyu
    static let primary = Color(nsColor: .hex(0xC2470E))
    static let primaryHover = Color(nsColor: .hex(0xA33A0A))

    /// Durum renginin yazı tonu (web panelindeki `--color-*-ink` değerleri; açık ve koyu zeminde WCAG AA):
    /// etiketlerde (Pill), fark kapsülünde ve renkli ikincil düğmelerde yazı bu tonla çizilir. Tanınmayan renk aynen döner.
    static func ink(for color: Color) -> Color {
        switch color {
        case Brand.accent: return accentInk
        case Brand.positive: return positiveInk
        case Brand.ok: return okInk
        case Brand.warn: return warnInk
        case Brand.negative: return negativeInk
        default: return color
        }
    }

    private static let accentInk = Color(nsColor: .adaptive(light: .hex(0xC2470E), dark: .hex(0xFF9A5C)))
    private static let positiveInk = Color(nsColor: .adaptive(light: .hex(0x1A62BA), dark: .hex(0x7FB3F5)))
    private static let okInk = Color(nsColor: .adaptive(light: .hex(0x1F7A42), dark: .hex(0x5FD08E)))
    private static let warnInk = Color(nsColor: .adaptive(light: .hex(0x9A5B06), dark: .hex(0xF1C27A)))
    private static let negativeInk = Color(nsColor: .adaptive(light: .hex(0xB42323), dark: .hex(0xFF8A83)))
}

private extension NSColor {
    /// sRGB onaltılık renk (0xRRGGBB)
    static func hex(_ rgb: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: alpha)
    }

    /// Açık / koyu görünüme (ve "Karşıtlığı artır" ayarına) göre değişen renk
    static func adaptive(light: NSColor, dark: NSColor, lightContrast: NSColor? = nil, darkContrast: NSColor? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua,
                                                    .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            if match == NSAppearance.Name.darkAqua { return dark }
            if match == NSAppearance.Name.accessibilityHighContrastDarkAqua { return darkContrast ?? dark }
            if match == NSAppearance.Name.accessibilityHighContrastAqua { return lightContrast ?? light }
            return light
        }
    }
}

extension View {
    /// Kart yüzeyi: düz kart rengi, 1 px çizgi, köşe 8 (gölge yok). İçerik köşeden taşmaz.
    func cardSurface(radius: CGFloat = Radius.container) -> some View {
        let shape = Shapes.rounded(radius)
        return self
            .clipShape(shape)
            .background(shape.fill(Brand.card))
            .overlay(shape.strokeBorder(Brand.line, lineWidth: 1))
    }

    /// Düğme ve küçük kontrol grubu yüzeyi (gün seçici, canlı bağlantı satırı): kart rengi, 1 px çizgi, köşe 6
    func controlSurface(fill: Color = Brand.card, radius: CGFloat = Radius.control) -> some View {
        let shape = Shapes.rounded(radius)
        return self
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(Brand.line, lineWidth: 1))
    }

    /// Giriş alanı: düz zemin, 1 px çizgi, köşe 6; odaktayken 1 px dışında 2 px marka rengi çerçeve (iç gölge yok)
    func inputSurface(focused: Bool, fill: Color = Brand.field, radius: CGFloat = Radius.control) -> some View {
        let shape = Shapes.rounded(radius)
        return self
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(Brand.line, lineWidth: 1))
            .overlay {
                if focused {
                    Shapes.rounded(radius + 3)
                        .strokeBorder(Brand.accent, lineWidth: 2)
                        .padding(-3)
                        .allowsHitTesting(false)
                }
            }
    }

    /// Bilgi / uyarı kutusu ve renkli etiket zemini: durum renginin hafif tonu, kenarlıksız (varsayılan köşe 8)
    func tintedSurface(_ color: Color, opacity: Double = 0.10, radius: CGFloat = Radius.container) -> some View {
        background(Shapes.rounded(radius).fill(color.opacity(opacity)))
    }

    /// Yüzen katman (bildirim şeridi, pencere önizlemesi): düz zemin, 1 px çizgi ve çok hafif gölge (0 1 2 %6)
    func floatingSurface(fill: Color = Brand.card, radius: CGFloat = Radius.container) -> some View {
        let shape = Shapes.rounded(radius)
        return self
            .background(shape.fill(fill).shadow(color: .black.opacity(0.06), radius: 1, x: 0, y: 1))
            .overlay(shape.strokeBorder(Brand.line, lineWidth: 1))
    }

    /// Sayfa penceresinin (sheet) zemini: ana pencereyle aynı düz zemin (kartlar her yerde aynı görünür)
    func sheetSurface() -> some View {
        background(Brand.page, ignoresSafeAreaEdges: .all)
    }

    /// Tablo satırı ayırıcısı: satırın altında 1 px çizgi (zebra satır yerine; yerleşimi değiştirmez)
    func rowSeparator(leading: CGFloat = 0) -> some View {
        overlay(alignment: .bottom) {
            Brand.line
                .frame(height: 1)
                .padding(.leading, leading)
                .allowsHitTesting(false)
        }
    }
}
