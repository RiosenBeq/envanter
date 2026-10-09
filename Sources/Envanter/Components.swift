import SwiftUI
import AppKit
import EnvanterCore

enum Brand {
    static let accent = Color(red: 0.90, green: 0.36, blue: 0.09)
    static let negative = Color(red: 0.84, green: 0.16, blue: 0.16)
    static let positive = Color(red: 0.12, green: 0.45, blue: 0.85)
    static let ok = Color(red: 0.16, green: 0.62, blue: 0.33)
    static let warn = Color(red: 0.88, green: 0.55, blue: 0.05)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let line = Color(nsColor: .separatorColor)
    static let field = Color(nsColor: .textBackgroundColor)
}

struct CellID: Hashable {
    var row: Int
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

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 8).fill(Brand.accent.opacity(configuration.isPressed ? 0.8 : 1)))
    }
}

struct SoftButtonStyle: ButtonStyle {
    var tint: Color = .primary
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(tint)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07)))
    }
}

/// Gün seçici: ◀ 1 Ağustos 2026, Cumartesi ▶ [takvim] [Bugün]
struct DateNavigator: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        HStack(spacing: 10) {
            Button { store.shiftDay(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut("[", modifiers: .command)
                .help("Önceki gün (⌘[)")
            Text(DateKey.long(store.selectedDate))
                .font(.title2.weight(.semibold))
                .frame(minWidth: 250, alignment: .leading)
            Button { store.shiftDay(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut("]", modifiers: .command)
                .help("Sonraki gün (⌘])")
            DatePicker("", selection: store.dateBinding, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
            if store.selectedDate != DateKey.today() {
                Button("Bugün") { store.goToday() }.buttonStyle(SoftButtonStyle())
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
struct NumberCell: View {
    let id: CellID
    let rowCount: Int
    @Binding var value: Double?
    var placeholder: String = ""
    var maxFraction: Int = 3
    var tint: Color? = nil
    @FocusState.Binding var focus: CellID?
    @State private var text = ""

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
            .background(RoundedRectangle(cornerRadius: 6).fill(isFocused ? Brand.field : (tint ?? Brand.field).opacity(tint == nil ? 0.55 : 0.18)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isFocused ? Brand.accent : Brand.line.opacity(0.6), lineWidth: isFocused ? 1.5 : 0.5))
            .padding(.horizontal, 4)
            .onAppear { text = display(value) }
            .onChange(of: value) { _, new in if !isFocused { text = display(new) } }
            .onChange(of: focus) { old, new in
                if old == id && new != id { commit() }
                if new == id { DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) } }
            }
            .onSubmit { commit(); move(1) }
            .onKeyPress(.downArrow) { commit(); move(1); return .handled }
            .onKeyPress(.upArrow) { commit(); move(-1); return .handled }
    }

    private func display(_ v: Double?) -> String {
        guard let v else { return "" }
        return Fmt.number(v, maxFraction: maxFraction)
    }

    private func move(_ delta: Int) {
        let next = id.row + delta
        focus = (next >= 0 && next < rowCount) ? CellID(row: next, col: id.col) : (delta > 0 ? nil : focus)
    }

    private func commit() {
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

extension Double {
    /// Farkı gösterim basamağına yuvarlayınca sıfır mı?
    func isZero(maxFraction: Int) -> Bool {
        let step = pow(10.0, Double(maxFraction))
        return (self * step).rounded() == 0
    }
}
