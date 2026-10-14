import SwiftUI
import EnvanterCore

// Kapatılmamış günler penceresi ve paylaşılan bilgisayarda "Şu an kim çalışıyor?" penceresi (web panelinde
// UnclosedDaysDialog ve WorkerPrompt; ortak kurallar EnvanterCore `DayClose.swift` ve `Worker.swift`).

/// Kontrol listesinin bir satırı: tamam (✓), eksik (⚠), bilgi (i)
struct DayCloseLineView: View {
    let line: DayCloseCheck.Line

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            Text(line.text).foregroundStyle(line.tone == .warn ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch line.tone {
        case .ok: return "checkmark"
        case .warn: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    private var color: Color {
        switch line.tone {
        case .ok: return Brand.ok
        case .warn: return Brand.warn
        case .info: return Brand.positive
        }
    }
}

/// Kapatılmamış günler: seçili gün dahil son 60 günde sayılmış ama kapatılmamış günler, her biri kontrol listesiyle.
/// Patron / müdür seçtiklerini topluca kapatır (uyarısı olmayan günler önceden seçili; tek geri alma adımı).
struct UnclosedDaysSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    /// nil: önceden seçili günler (`UnclosedDays.preselected`)
    @State private var picked: Set<String>?

    var body: some View {
        let days = store.unclosedDays()
        let selected = picked ?? Set(UnclosedDays.preselected(days))
        let chosen = days.filter { selected.contains($0.date) }.map { $0.date }
        let manager = store.canChangeLockedDays
        VStack(alignment: .leading, spacing: 12) {
            Text(UnclosedDays.title(days.count)).font(.title3.weight(.semibold))
            Text(UnclosedDays.subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if days.isEmpty {
                Text(UnclosedDays.emptyText).font(.callout)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(days) { d in
                            row(d, on: selected.contains(d.date), selected: selected, manager: manager)
                        }
                    }
                }
                .frame(maxHeight: 440)
            }
            HStack {
                Spacer()
                Button(UnclosedDays.dismissLabel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SoftButtonStyle())
                if manager && !days.isEmpty {
                    Button {
                        if store.closeDays(chosen) > 0 { dismiss() }
                    } label: {
                        Label(UnclosedDays.closeSelectedLabel + (chosen.isEmpty ? "" : " (\(chosen.count))"), systemImage: "lock")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(chosen.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 580)
    }

    private func row(_ d: UnclosedDay, on: Bool, selected: Set<String>, manager: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if manager {
                    Toggle("", isOn: Binding(get: { on }, set: { v in
                        var s = selected
                        if v { s.insert(d.date) } else { s.remove(d.date) }
                        picked = s
                    }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .accessibilityLabel("\(DateKey.long(d.date)) kapatılsın")
                }
                Text(DateKey.long(d.date)).font(.headline)
                Spacer()
                Button {
                    store.selectedDate = d.date
                    store.section = .daily
                    dismiss()
                } label: { Label("Günü Aç", systemImage: "chevron.right") }
                    .buttonStyle(.link)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(d.check.lines) { DayCloseLineView(line: $0) }
            }
            .padding(.leading, manager ? 24 : 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(on && manager ? Brand.accent.opacity(0.08) : Color.primary.opacity(0.04)))
    }
}

/// Paylaşılan mağaza bilgisayarında (bağlantı koduyla bağlı, cihaz hesabı) "Şu an kim çalışıyor?": uygulama oturumunda
/// bir kez ve yan menüdeki adla ("Değiştir") açılır. Seçim yalnızca bu uygulama açık kaldıkça tutulur. İlk soruda Esc
/// "Atla" demektir; "Değiştir"de Esc / "Vazgeç" seçili çalışanı korur, "Atla" kimseyi seçmez (web WorkerPrompt ile aynı).
struct WorkerSheet: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let names = store.workerOptions
        let current = store.activeWorker
        VStack(alignment: .leading, spacing: 12) {
            Text(SessionWorker.promptTitle).font(.title3.weight(.semibold))
            Text(SessionWorker.promptMessage).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if names.isEmpty {
                Text(SessionWorker.noEmployeesText).font(.callout)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(names, id: \.self) { n in
                        let selected = n == current
                        Button { store.setWorker(n) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "person.crop.circle").foregroundStyle(selected ? Brand.accent : Color.secondary)
                                Text(n).lineLimit(1)
                                Spacer(minLength: 4)
                                if selected { Image(systemName: "checkmark").foregroundStyle(Brand.accent) }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selected ? Brand.accent.opacity(0.15) : Color.primary.opacity(0.05)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Spacer()
                if store.workerPromptIsChange {
                    Button(SessionWorker.skipLabel) { store.setWorker(nil) }
                        .buttonStyle(SoftButtonStyle())
                    Button("Vazgeç") { store.closeWorkerPrompt() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(SoftButtonStyle())
                } else {
                    Button(SessionWorker.skipLabel) { store.closeWorkerPrompt() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(SoftButtonStyle())
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { store.markWorkerAsked() }
    }
}

/// Yan menüde paylaşılan bilgisayarın çalışanı: ada tıklayınca "Şu an kim çalışıyor?" açılır (yalnızca cihaz hesabıyla)
struct WorkerRow: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var cloud: CloudSyncController

    var body: some View {
        if cloud.isConnected && store.asksWorker {
            Button { store.requestWorkerChange() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle").foregroundStyle(Brand.accent)
                    Text(store.activeWorker ?? "Çalışan seçilmedi").lineLimit(1)
                    Spacer(minLength: 4)
                    Text(SessionWorker.changeLabel).foregroundStyle(.secondary)
                }
                .font(.caption)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(SessionWorker.promptTitle)
        }
    }
}

/// Cihaz hesabıyla bağlanınca (ve araya giren pencere kapanınca) çalışanı sorar
struct WorkerPromptTrigger: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var cloud: CloudSyncController

    var body: some View {
        Color.clear
            .onAppear { store.askWorkerIfNeeded() }
            .onChange(of: cloud.isConnected) { _, _ in store.askWorkerIfNeeded() }
            .onChange(of: store.connectRequest?.id) { _, _ in store.askWorkerIfNeeded() }
            .onChange(of: store.importPreview?.id) { _, _ in store.askWorkerIfNeeded() }
    }
}
