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

/// Değişim rozeti (Tremor "BadgeDelta" deseni): ▲ %4,2 / ▼ %1,3.
/// `higherIsBetter` false ise (maliyetler) artış kırmızı, azalış yeşil gösterilir.
struct DeltaBadge: View {
    var ratio: Double
    var higherIsBetter = true
    var body: some View {
        let up = ratio >= 0
        let neutral = abs(ratio) < 0.0005
        let good = neutral ? true : (up == higherIsBetter)
        let color: Color = neutral ? .secondary : (good ? Brand.ok : Brand.negative)
        HStack(spacing: 2) {
            Image(systemName: neutral ? "arrow.right" : (up ? "arrow.up.right" : "arrow.down.right"))
            Text("%" + Fmt.number(abs(ratio) * 100, maxFraction: 1))
        }
        .font(.caption2.weight(.bold)).monospacedDigit()
        .padding(.horizontal, 6).padding(.vertical, 2)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.12)))
        .help("Önceki eşit uzunluktaki döneme göre değişim")
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

/// Hedefe göre durum çubuğu (Tremor "MarkerBar" deseni): dolu kısım gerçekleşen, dikey çizgi hedef.
struct TargetBar: View {
    /// Gerçekleşen ve hedef oranları (0–1)
    var value: Double
    var target: Double
    /// Maliyet oranlarında düşük olan iyidir
    var lowerIsBetter = true

    var body: some View {
        let scale = max(max(value, target) * 1.25, 0.0001)
        let ok = lowerIsBetter ? value <= target : value >= target
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill((ok ? Brand.ok : Brand.negative).opacity(0.85))
                    .frame(width: max(4, g.size.width * min(value / scale, 1)))
                Rectangle().fill(Color.primary.opacity(0.75))
                    .frame(width: 2, height: g.size.height + 4)
                    .offset(x: g.size.width * min(target / scale, 1) - 1)
            }
        }
        .frame(height: 6)
        .help("Gerçekleşen %\(Fmt.number(value * 100, maxFraction: 1)) · hedef %\(Fmt.number(target * 100, maxFraction: 1))")
    }
}

/// Pano kartı (Tremor KPI kartı deseni): başlık + ⓘ, büyük değer, değişim rozeti, mini grafik / hedef çubuğu, alt açıklama
struct StatCard: View {
    var title: String
    var value: String
    var detail: String = ""
    var icon: String
    var color: Color = Brand.accent
    var progress: Double? = nil
    var info: Term? = nil
    /// Önceki döneme göre değişim (oran) ve yönün anlamı
    var delta: Double? = nil
    var higherIsBetter = true
    var spark: [Double]? = nil
    /// Hedefli oranlar için: gerçekleşen ve hedef (0–1)
    var targetValue: Double? = nil
    var target: Double? = nil

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
                    if let delta { DeltaBadge(ratio: delta, higherIsBetter: higherIsBetter) }
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
                if let targetValue, let target { TargetBar(value: targetValue, target: target) }
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

/// Gün durum şeridi (Tremor "Tracker" deseni): her kutu bir gün; renk günün durumunu, ipucu ayrıntıyı gösterir.
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

    private func color(_ d: DayOverview) -> Color {
        if !d.hasAnyCount && !d.hasSales { return Color.primary.opacity(0.08) }
        if !d.hasAnyCount { return Color.secondary.opacity(0.35) }
        if d.hasSignificantLoss { return Brand.negative.opacity(0.85) }
        if d.hasNotableLoss || !d.isFullyCounted { return Brand.warn.opacity(0.85) }
        return Brand.ok.opacity(0.85)
    }

    private func tooltip(_ d: DayOverview) -> String {
        var parts = [DateKey.long(d.date)]
        parts.append(d.hasAnyCount ? "Sayım \(d.countedItems)/\(d.itemCount)" : "Sayım yok")
        parts.append(d.hasSales ? "Satış raporu var" : "Satış raporu yok")
        if d.problemItems > 0 { parts.append("\(d.problemItems) sorunlu kalem") }
        if d.lossValue > 0 {
            let share = d.revenue.flatMap { $0 > 0 ? " (satışın %\(Fmt.number(d.lossValue / $0 * 100, maxFraction: 1)))" : nil } ?? ""
            parts.append("Kayıp \(Fmt.money(d.lossValue))" + share)
        }
        if d.isLocked { parts.append("Kapatıldı") }
        return parts.joined(separator: " · ")
    }
}

/// Tracker renk açıklaması
struct TrackerLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            item(Brand.ok.opacity(0.85), "Sayım tam, kayıp düşük")
            item(Brand.warn.opacity(0.85), "Eksik sayım / kayıp ≥ %0,5")
            item(Brand.negative.opacity(0.85), "Kayıp ≥ satışın %1'i")
            item(Color.secondary.opacity(0.35), "Yalnızca satış")
            item(Color.primary.opacity(0.08), "Veri yok")
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
                VStack(alignment: .leading, spacing: 0) {
                    Text(DateKey.long(store.selectedDate))
                        .font(compact ? .title3.weight(.semibold) : .title2.weight(.semibold))
                    if store.isLocked(store.selectedDate) {
                        Label("Gün kapatıldı", systemImage: "lock.fill").font(.caption).foregroundStyle(Brand.warn)
                    }
                }
                .frame(minWidth: compact ? 210 : 250, alignment: .leading)
                Button { store.shiftDay(1) } label: { Image(systemName: "chevron.right").frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .help("Sonraki gün (⌘])")
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
struct NumberCell: View {
    let id: CellID
    /// Görünen satırların kalem sırası (↑/↓/Enter ile geçiş için)
    let order: [String]
    @Binding var value: Double?
    var placeholder: String = ""
    var maxFraction: Int = 3
    var tint: Color? = nil
    @FocusState.Binding var focus: CellID?
    @State private var text = ""
    @State private var dirty = false
    @Environment(\.isEnabled) private var isEnabled

    private var isFocused: Bool { focus == id }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
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
        guard let parsed = Fmt.parse(trimmed), parsed >= 0 else {
            NSSound.beep()
            text = display(value)
            return
        }
        let v = (parsed * 1_000_000).rounded() / 1_000_000
        if value != v { value = v }
        text = display(v)
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

/// İsteğe bağlı sayı alanı (boş bırakılabilir): maliyet, kritik seviye, tolerans gibi.
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
        text = t
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
