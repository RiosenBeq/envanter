import SwiftUI
import AppKit
import Charts
import EnvanterCore

enum Brand {
    static let appName = "NextGen Envanter"
    static let shortName = "NextGen"
    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "geliştirme"
    }

    static let accent = Color(red: 0.90, green: 0.36, blue: 0.09)
    static let accentDeep = Color(red: 0.72, green: 0.22, blue: 0.05)
    static let negative = Color(red: 0.84, green: 0.16, blue: 0.16)
    static let positive = Color(red: 0.12, green: 0.45, blue: 0.85)
    static let ok = Color(red: 0.16, green: 0.62, blue: 0.33)
    static let warn = Color(red: 0.88, green: 0.55, blue: 0.05)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let line = Color(nsColor: .separatorColor)
    static let field = Color(nsColor: .textBackgroundColor)
    static let gradient = LinearGradient(colors: [accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Fark değerlendirmesinin rengi
    static func color(for s: DiffSeverity) -> Color {
        switch s {
        case .zero, .withinTolerance: return ok
        case .shortage: return negative
        case .surplus: return positive
        }
    }

    /// Takip şeridi kutusunun rengi (web paneliyle aynı sınıflar: `DayOverview.trackerState`)
    static func color(for s: TrackerState) -> Color {
        switch s {
        case .ok: return ok.opacity(0.85)
        case .warn: return warn.opacity(0.85)
        case .bad: return negative.opacity(0.85)
        case .salesOnly: return Color.secondary.opacity(0.35)
        case .empty: return Color.primary.opacity(0.08)
        }
    }
}

/// Günlük tablodaki hücre: satır kalem kimliğiyle tutulur (filtreyle satırlar kaysa da odak doğru kaleme gider)
struct CellID: Hashable {
    var item: String
    var col: Int
}

/// İçerik kartı: Liquid Glass yüzey (macOS 26) ya da buzlu cam (önceki sürümler)
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentGlass()
    }
}

struct Pill: View {
    var text: String
    var color: Color
    var filled = false
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(filled ? Color.white : color)
            .background(Capsule().fill(filled ? color : color.opacity(0.14)))
    }
}

/// Eksensiz küçük eğilim grafiği (sparkline)
struct Sparkline: View {
    var values: [Double]
    var color: Color = Brand.accent
    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                AreaMark(x: .value("i", i), y: .value("v", v))
                    .foregroundStyle(color.opacity(0.12).gradient)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("i", i), y: .value("v", v))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
    }
}

/// Pano kartı (Tremor KPI kartı deseni): başlık + ⓘ, büyük değer, mini grafik, ilerleme çubuğu, alt açıklama
struct StatCard: View {
    var title: String
    var value: String
    var detail: String = ""
    var icon: String
    var color: Color = Brand.accent
    var progress: Double? = nil
    var info: Term? = nil
    /// Mini eğilim grafiği (ör. son 14 günün sorunlu kalem sayısı)
    var spark: [Double]? = nil

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.callout.weight(.semibold)).foregroundStyle(color)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.13)))
                    Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                    if let info { InfoTip(term: info) }
                    Spacer(minLength: 0)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                    if let spark, spark.count > 1 {
                        Spacer(minLength: 4)
                        Sparkline(values: spark, color: color).frame(width: 84, height: 28)
                    }
                }
                if let progress {
                    ProgressView(value: min(max(progress, 0), 1)).tint(color)
                }
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Eşit yükseklikte kart satırı (StatCard'lar için)
struct StatRow<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .top, spacing: spacing) { content }
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Gün durum şeridi (Tremor "Tracker" deseni): her kutu bir gün; renk günün sayım durumunu (sayılanların kaçında
/// tolerans dışı fark var), ipucu ayrıntıyı gösterir. Renk kuralı web paneliyle aynıdır (`DayOverview.trackerState`).
struct TrackerStrip: View {
    let days: [DayOverview]
    var selected: String? = nil
    var onSelect: ((String) -> Void)? = nil

    var body: some View {
        HStack(spacing: 3) {
            ForEach(days) { d in
                RoundedRectangle(cornerRadius: 3)
                    .fill(color(d))
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(d.date == selected ? Color.primary.opacity(0.8) : Color.clear, lineWidth: 1.5))
                    .help(tooltip(d))
                    .onTapGesture { onSelect?(d.date) }
            }
        }
    }

    /// Sayım yok ve satış yok → boş; sayım yok → gri; sayılanların %20'sinde fark → kırmızı; %10'unda fark ya da eksik
    /// sayım → turuncu; değilse yeşil
    private func color(_ d: DayOverview) -> Color { Brand.color(for: d.trackerState) }

    private func tooltip(_ d: DayOverview) -> String {
        var parts = [DateKey.long(d.date)]
        parts.append(d.hasAnyCount ? "Sayım \(d.countedItems)/\(d.itemCount)" : "Sayım yok")
        parts.append(d.hasSales ? "Satış raporu var" : "Satış raporu yok")
        if d.problemItems > 0 { parts.append("\(d.problemItems) kalemde tolerans dışı fark") }
        if d.shortageItems > 0 { parts.append("\(d.shortageItems) kalemde fazla çıkış") }
        if d.belowMinimumItems > 0 { parts.append("\(d.belowMinimumItems) kalem kritik seviyenin altında") }
        if d.isLocked { parts.append("Kapatıldı") }
        return parts.joined(separator: " · ")
    }
}

/// Tracker renk açıklaması (metinler web paneliyle aynı: `TrackerState.label`)
struct TrackerLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach(TrackerState.legendOrder, id: \.self) { s in
                item(Brand.color(for: s), s.label)
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
    }
    private func item(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10); Text(t) }
    }
}

/// Birincil düğme: marka turuncusuyla renklendirilmiş cam kapsül
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.horizontal, 15).padding(.vertical, 7)
            .foregroundStyle(.white)
            .glassSurface(in: Capsule(), tint: Brand.accent, interactive: true)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// İkincil düğme: renksiz cam kapsül
struct SoftButtonStyle: ButtonStyle {
    var tint: Color = .primary
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .padding(.horizontal, 13).padding(.vertical, 6)
            .foregroundStyle(tint)
            .glassSurface(in: Capsule(), interactive: true)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Gün seçici: ◀ 1 Ağustos 2026, Cumartesi ▶ [takvim] [Bugün]
/// Kısayollar (⌘[ / ⌘] / ⌘T) "Gün" menüsünde tanımlıdır; burada tekrar tanımlanmaz.
struct DateNavigator: View {
    @EnvironmentObject var store: AppStore
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            // Gün adımı: cam kapsül içinde ◀ tarih ▶
            HStack(spacing: 8) {
                Button { store.shiftDay(-1) } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .help("Önceki gün (⌘[)")
                    .accessibilityLabel("Önceki gün")
                VStack(alignment: .leading, spacing: 0) {
                    Text(DateKey.long(store.selectedDate))
                        .font(compact ? .title3.weight(.semibold) : .title2.weight(.semibold))
                    if store.isLocked(store.selectedDate) {
                        // Kim, nereden açar: personel açamaz (patron / müdür), diğerleri Günlük Sayım'dan (⌘L)
                        Label("Gün kapatıldı", systemImage: "lock.fill").font(.caption).foregroundStyle(Brand.warn)
                            .help(store.canChangeLockedDays
                                  ? "Sayım ve satış kilitli. Değiştirmek için Günlük Sayım'da \"Kilidi Aç\"a basın (⌘L)."
                                  : CloudPermission.lockedDayStaffNote)
                    }
                }
                .frame(minWidth: compact ? 210 : 250, alignment: .leading)
                Button { store.shiftDay(1) } label: { Image(systemName: "chevron.right").frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .help("Sonraki gün (⌘])")
                    .accessibilityLabel("Sonraki gün")
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glassSurface(in: Capsule())
            DatePicker("", selection: store.dateBinding, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
            if store.selectedDate != DateKey.today() {
                Button("Bugün") { store.goToday() }.buttonStyle(SoftButtonStyle()).help("Bugüne git (⌘T)")
            }
            let recorded = store.recordedDates
            if !recorded.isEmpty {
                Menu {
                    ForEach(recorded.prefix(60), id: \.self) { d in
                        Button(DateKey.long(d)) { store.selectedDate = d }
                    }
                } label: { Label("Kayıtlı günler", systemImage: "calendar.badge.clock") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Verisi olan günlere git")
            }
        }
    }
}

/// Sayı hücresi: Türkçe (virgül) ve nokta kabul eder; Enter/↓ alt satıra, ↑ üst satıra geçer.
/// Odak kaybında ve hücre ekrandan kalkarken (ör. gün değiştirilince) yazılan değer kaydedilir.
/// `isKg` verilirse (sayım hücreleri) toplayarak giriş kabul edilir: "12+8+5", "3x24+7" (`Fmt.parseCountExpression`);
/// kaydedilen işlem ("12+8+5 = 25") hücrenin ipucu olur ve VoiceOver'a duyurulur.
struct NumberCell: View {
    let id: CellID
    /// Görünen satırların kalem sırası (↑/↓/Enter ile geçiş için)
    let order: [String]
    @Binding var value: Double?
    var placeholder: String = ""
    var maxFraction: Int = 3
    var tint: Color? = nil
    /// Ekran okuyucu için hücrenin adı ("90 Gr kapanış"); tabloda hücrenin görünen etiketi yok
    var label: String = ""
    /// Sayım hücresi: kalemin kg olup olmadığı (toplayarak giriş; adet kalemde "1.200" = 1200). nil: düz sayı
    var isKg: Bool? = nil
    /// Hücrenin ipucu (ör. açılışın dayanağı); toplayarak giriş yapılınca işlem gösterilir
    var cellHelp: String = ""
    @FocusState.Binding var focus: CellID?
    @State private var text = ""
    @State private var dirty = false
    /// Bu hücreye toplayarak girilen son işlem ("12+8+5 = 25"); hücre ekranda kaldıkça ipucudur
    @State private var expression: String?
    @Environment(\.isEnabled) private var isEnabled

    private var isFocused: Bool { focus == id }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .accessibilityLabel(label)
            .focused($focus, equals: id)
            .overlay(alignment: .trailing) {
                if text.isEmpty && !placeholder.isEmpty && !isFocused {
                    Text(placeholder).monospacedDigit().foregroundStyle(.tertiary).padding(.trailing, 8).allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(background))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isFocused ? Brand.accent : Brand.line.opacity(0.6), lineWidth: isFocused ? 1.5 : 0.5))
            .padding(.horizontal, 4)
            .onAppear { text = display(value) }
            .onChange(of: value) { _, new in if !isFocused { text = display(new); dirty = false } }
            .onChange(of: text) { _, _ in if isFocused { dirty = true } }
            .onChange(of: focus) { old, new in
                if old == id && new != id { commit() }
                if new == id { DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) } }
            }
            .onDisappear { if dirty { commit() } }
            .onSubmit { commit(); move(1) }
            .onKeyPress(.downArrow) { commit(); move(1); return .handled }
            .onKeyPress(.upArrow) { commit(); move(-1); return .handled }
            .help(expression ?? cellHelp)
    }

    private var background: Color {
        if !isEnabled { return Color.primary.opacity(0.04) }
        if isFocused { return Brand.field }
        return (tint ?? Brand.field).opacity(tint == nil ? 0.55 : 0.18)
    }

    private func display(_ v: Double?) -> String {
        guard let v else { return "" }
        return Fmt.number(v, maxFraction: maxFraction)
    }

    private func move(_ delta: Int) {
        guard let i = order.firstIndex(of: id.item) else { focus = nil; return }
        let next = i + delta
        focus = (next >= 0 && next < order.count) ? CellID(item: order[next], col: id.col) : (delta > 0 ? nil : focus)
    }

    private func commit() {
        dirty = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if value != nil { value = nil }
            text = ""
            return
        }
        let parsed: Double?
        if let isKg { parsed = Fmt.parseCountExpression(trimmed, isKg: isKg) } else { parsed = Fmt.parse(trimmed) }
        guard let parsed, parsed >= 0 else {
            NSSound.beep()
            text = display(value)
            return
        }
        let v = (parsed * 1_000_000).rounded() / 1_000_000
        if value != v { value = v }
        text = display(v)
        if isKg != nil, let said = Fmt.countExpressionText(trimmed, value: v, maxFraction: maxFraction) {
            expression = said
            announce(label.isEmpty ? said : "\(label): \(said)")
        }
    }

    /// VoiceOver duyurusu ("90 Gr kapanış: 12+8+5 = 25")
    private func announce(_ message: String) {
        guard let window = NSApp.keyWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

/// Zorunlu (boş olamayan) sayı alanı: reçete miktarı, katsayı gibi yerlerde.
struct DecimalField: View {
    @Binding var value: Double
    var maxFraction: Int = 4
    var width: CGFloat = 80
    /// Formlarda: geçerli her yazımda değeri hemen günceller (düğmeye basıldığında son yazılan kaybolmasın)
    var live = false
    @State private var text = ""
    /// Kullanıcı yazdı mı (yalnızca yazılan metin kaydedilir; gösterim yuvarlaması değeri bozmasın)
    @State private var edited = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("0", text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: width)
            .focused($focused)
            .onAppear { text = Fmt.number(value, maxFraction: maxFraction) }
            .onChange(of: value) { _, new in if !focused { text = Fmt.number(new, maxFraction: maxFraction) } }
            .onChange(of: focused) { _, now in if !now && edited { commit() } }
            .onChange(of: text) { _, t in
                guard focused else { return }
                edited = true
                if live, let v = parsed(t), v != value { value = v }
            }
            .onSubmit { if edited { commit() } }
            // Alan odaktayken ekran/gün değişirse yazılan kaybolmasın
            .onDisappear { if edited, let v = parsed(text), v != value { value = v } }
    }

    private func parsed(_ t: String) -> Double? {
        guard let v = Fmt.parse(t), v >= 0 else { return nil }
        return (v * 1_000_000).rounded() / 1_000_000
    }

    private func commit() {
        if let r = parsed(text) {
            if r != value { value = r }
        } else { NSSound.beep() }
        edited = false
        text = Fmt.number(value, maxFraction: maxFraction)
    }
}

/// İsteğe bağlı sayı alanı (boş bırakılabilir): kritik seviye, tolerans, teslim alınan miktar gibi.
struct OptionalDecimalField: View {
    @Binding var value: Double?
    var placeholder: String = "—"
    var maxFraction: Int = 3
    var width: CGFloat = 80
    /// Formlarda: geçerli her yazımda değeri hemen günceller (düğmeye basıldığında son yazılan kaybolmasın)
    var live = false
    @State private var text = ""
    /// Kullanıcı yazdı mı (yalnızca yazılan metin kaydedilir; gösterim yuvarlaması değeri bozmasın)
    @State private var edited = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: width)
            .focused($focused)
            .onAppear { text = display(value) }
            .onChange(of: value) { _, new in if !focused { text = display(new) } }
            .onChange(of: focused) { _, now in if !now && edited { commit() } }
            .onChange(of: text) { _, t in
                guard focused else { return }
                edited = true
                if live, let v = parsed(t), v != value { value = v }
            }
            .onSubmit { if edited { commit() } }
            // Alan odaktayken ekran/gün değişirse yazılan kaybolmasın
            .onDisappear { if edited, let v = parsed(text), v != value { value = v } }
    }

    private func display(_ v: Double?) -> String { v.map { Fmt.number($0, maxFraction: maxFraction) } ?? "" }

    /// Boş metin → nil değer; geçersiz metin → nil (değişiklik yok)
    private func parsed(_ t: String) -> Double?? {
        let t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .some(nil) }
        guard let v = Fmt.parse(t), v >= 0 else { return nil }
        return .some((v * 1_000_000).rounded() / 1_000_000)
    }

    private func commit() {
        if let r = parsed(text) {
            if r != value { value = r }
        } else { NSSound.beep() }
        edited = false
        text = display(value)
    }
}

/// Personel hesabıyla salt okunur bölümlerde gösterilen açıklama (web panelindeki salt okunur notla aynı kural:
/// tanımları yalnızca patron ve müdür değiştirir; sunucu da reddeder)
struct ReadOnlyNote: View {
    var text: String = CloudPermission.catalogReadOnlyNote

    var body: some View {
        Label(text, systemImage: "lock.fill")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Yazarken değil, Enter'a basınca veya alandan çıkınca kaydeden metin alanı
/// (her tuşta veriyi değiştirip geri alma geçmişini ve hesapları şişirmemek için).
struct CommitTextField: View {
    var title: String
    @Binding var value: String
    var font: Font = .body
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(font)
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { _, new in if !focused { text = new } }
            .onChange(of: focused) { _, now in if !now { commit() } }
            .onSubmit { commit() }
            .onDisappear { if text != value { commit() } }
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t != value { value = t }
        // Kaydedilen değer gösterilir: değer reddedildiyse (ör. boş ad) ya da düzeltildiyse alan onunla eşleşir
        text = value
    }
}

struct EmptyStateView: View {
    var icon: String
    var title: String
    var message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Kenar çubuğunun altındaki kayıt durumu
struct SaveStatusView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                switch store.saveState {
                case .saved:
                    // Yerel kayıt (bulut simgesi kullanılmaz); web eşitlemesi alttaki ayrı satırda
                    Image(systemName: "checkmark.circle").foregroundStyle(Brand.ok)
                    Text(store.lastSavedAt.map { "Bu Mac'e kaydedildi · \(Self.time.string(from: $0))" } ?? "Bu Mac'e kaydedildi")
                case .saving:
                    ProgressView().controlSize(.mini)
                    Text("Kaydediliyor…")
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.negative)
                    Text("Kaydedilemedi").help(message)
                }
            }
            // Web paneline bağlıyken: "Web ile eşitlendi · 14:05" / "Eşitleniyor…" / "Eşitleme hatası"
            CloudStatusLine(cloud: store.cloud)
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "tr_TR"); f.dateFormat = "HH:mm"; return f
    }()
}

extension Double {
    /// Farkı gösterim basamağına yuvarlayınca sıfır mı?
    func isZero(maxFraction: Int) -> Bool {
        let step = pow(10.0, Double(maxFraction))
        return (self * step).rounded() == 0
    }
}
