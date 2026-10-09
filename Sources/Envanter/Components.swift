import SwiftUI
import AppKit
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

struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 10).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.line.opacity(0.7), lineWidth: 1))
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

/// Pano kartı: başlık, büyük değer, alt açıklama
struct StatCard: View {
    var title: String
    var value: String
    var detail: String = ""
    var icon: String
    var color: Color = Brand.accent
    var progress: Double? = nil

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.callout.weight(.semibold)).foregroundStyle(color)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.14)))
                    Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let progress {
                    ProgressView(value: min(max(progress, 0), 1)).tint(color)
                }
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 8).fill(Brand.accent.opacity(configuration.isPressed ? 0.8 : 1)))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct SoftButtonStyle: ButtonStyle {
    var tint: Color = .primary
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(tint)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07)))
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
            Button { store.shiftDay(-1) } label: { Image(systemName: "chevron.left") }
                .help("Önceki gün (⌘[)")
            VStack(alignment: .leading, spacing: 0) {
                Text(DateKey.long(store.selectedDate))
                    .font(compact ? .title3.weight(.semibold) : .title2.weight(.semibold))
                if store.isLocked(store.selectedDate) {
                    Label("Gün kapatıldı", systemImage: "lock.fill").font(.caption).foregroundStyle(Brand.warn)
                }
            }
            .frame(minWidth: compact ? 210 : 250, alignment: .leading)
            Button { store.shiftDay(1) } label: { Image(systemName: "chevron.right") }
                .help("Sonraki gün (⌘])")
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
    @State private var text = ""
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
            .onChange(of: focused) { _, now in if !now { commit() } }
            .onSubmit { commit() }
    }

    private func commit() {
        if let v = Fmt.parse(text), v >= 0 {
            let r = (v * 1_000_000).rounded() / 1_000_000
            if r != value { value = r }
        } else { NSSound.beep() }
        text = Fmt.number(value, maxFraction: maxFraction)
    }
}

/// İsteğe bağlı sayı alanı (boş bırakılabilir): maliyet, kritik seviye, tolerans gibi.
struct OptionalDecimalField: View {
    @Binding var value: Double?
    var placeholder: String = "—"
    var maxFraction: Int = 3
    var width: CGFloat = 80
    @State private var text = ""
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
            .onChange(of: focused) { _, now in if !now { commit() } }
            .onSubmit { commit() }
    }

    private func display(_ v: Double?) -> String { v.map { Fmt.number($0, maxFraction: maxFraction) } ?? "" }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            if value != nil { value = nil }
        } else if let v = Fmt.parse(t), v >= 0 {
            let r = (v * 1_000_000).rounded() / 1_000_000
            if r != value { value = r }
        } else { NSSound.beep() }
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
        HStack(spacing: 6) {
            switch store.saveState {
            case .saved:
                Image(systemName: "checkmark.icloud").foregroundStyle(Brand.ok)
                Text(store.lastSavedAt.map { "Kaydedildi · \(Self.time.string(from: $0))" } ?? "Kaydedildi")
            case .saving:
                ProgressView().controlSize(.mini)
                Text("Kaydediliyor…")
            case .failed(let message):
                Image(systemName: "exclamationmark.icloud.fill").foregroundStyle(Brand.negative)
                Text("Kaydedilemedi").help(message)
            }
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
