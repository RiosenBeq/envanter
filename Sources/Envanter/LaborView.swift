import SwiftUI
import Charts
import EnvanterCore

/// Personel maliyeti: günlük vardiya girişi, ay toplamı, personel % ve prime cost, personel listesi.
struct LaborView: View {
    @EnvironmentObject var store: AppStore
    @State private var showAdd = false
    @State private var fillMessage: String?

    var body: some View {
        let date = store.selectedDate
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    DateNavigator()
                    Spacer()
                    if !store.employees.isEmpty && !store.isLocked(date) {
                        Button {
                            let n = store.fillDefaultShifts(date: date)
                            fillMessage = n == 0 ? "Doldurulacak boş vardiya yok" : "\(n) vardiya varsayılanla dolduruldu"
                        } label: { Label("Vardiyaları Doldur", systemImage: "wand.and.stars") }
                            .buttonStyle(SoftButtonStyle())
                            .help("Boş vardiyalara saatliklerde varsayılan saati, yevmiyelilerde \"çalıştı\" işaretini yazar")
                    }
                    Button { showAdd = true } label: { Label("Personel Ekle", systemImage: "person.badge.plus") }
                        .buttonStyle(PrimaryButtonStyle())
                }
                if let fillMessage { Text(fillMessage).font(.callout).foregroundStyle(.secondary) }
                if store.employees.isEmpty {
                    Card {
                        EmptyStateView(icon: "person.2", title: "Henüz personel eklenmedi",
                                       message: "Personel maliyetini (ve hammadde + personel = prime cost oranını) görmek için çalışanları ücret türleriyle ekleyin: aylık maaş, günlük yevmiye veya saatlik ücret.")
                            .frame(height: 260)
                    }
                } else {
                    LaborKPIs(date: date)
                    ShiftTable(date: date)
                    HStack(alignment: .top, spacing: 16) {
                        LaborMonthChart(date: date).frame(maxWidth: .infinity)
                        LaborBreakdown(date: date).frame(width: 380)
                    }
                    EmployeeList()
                }
            }
            .padding(22)
        }
        .navigationTitle("Personel")
        .sheet(isPresented: $showAdd) { AddEmployeeSheet(date: date).environmentObject(store) }
        .onChange(of: date) { _, _ in fillMessage = nil }
    }
}

private func pct(_ v: Double?) -> String { v.map { "%" + Fmt.number($0 * 100, maxFraction: 1) } ?? "—" }

// MARK: - KPI

private struct LaborKPIs: View {
    @EnvironmentObject var store: AppStore
    let date: String

    var body: some View {
        let engine = store.engine
        let day = engine.labor(date: date)
        let monthStart = DateKey.startOfMonth(date)
        let mtd = engine.laborSummary(from: monthStart, to: date)
        let stats = engine.periodStats(from: monthStart, to: date)
        let spark = (0..<14).map { engine.labor(date: DateKey.addDays($0 - 13, to: date)).total }
        let s = store.settings
        StatRow {
            StatCard(title: "Günün personel maliyeti", value: Fmt.money(day.total),
                     detail: "\(day.headcount) kişi vardiyada · \(Fmt.number(day.hours, maxFraction: 1)) saat",
                     icon: "person.2", color: Brand.accent, info: .laborCost, spark: spark)
            StatCard(title: "Bu ay", value: Fmt.money(mtd.total),
                     detail: "\(DateKey.short(monthStart)) – \(DateKey.short(date)) · \(Fmt.number(mtd.hours, maxFraction: 0)) saat",
                     icon: "calendar", color: Brand.positive, info: .laborCost)
            StatCard(title: "Personel oranı", value: pct(stats.laborPct),
                     detail: s.targetLaborPct.map { "Hedef \(pct($0)) · satış tutarı olan günler" } ?? "Hedef için Ayarlar'a bakın",
                     icon: "percent", color: color(stats.laborPct, s.targetLaborPct), info: .laborPct,
                     targetValue: stats.laborPct, target: s.targetLaborPct)
            StatCard(title: "Prime cost oranı", value: pct(stats.primeCostPct),
                     detail: "Hammadde + personel" + (s.targetPrimeCostPct.map { " · hedef \(pct($0))" } ?? ""),
                     icon: "chart.pie", color: color(stats.primeCostPct, s.targetPrimeCostPct), info: .primeCost,
                     targetValue: stats.primeCostPct, target: s.targetPrimeCostPct)
        }
    }

    private func color(_ v: Double?, _ t: Double?) -> Color {
        guard let v, let t else { return Brand.accent }
        return v <= t ? Brand.ok : Brand.negative
    }
}

// MARK: - Günün vardiyası

private struct ShiftTable: View {
    @EnvironmentObject var store: AppStore
    let date: String

    var body: some View {
        let engine = store.engine
        let day = store.data.days[date]
        let locked = store.isLocked(date)
        let list = store.employees.filter { ($0.active && $0.isEmployed(on: date)) || day?.shifts?[$0.id] != nil }
        let labor = engine.labor(date: date)
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("Günün vardiyası").font(.headline)
                    InfoTip(term: .payType)
                    Spacer()
                    if locked { Label("Gün kapatıldı", systemImage: "lock.fill").font(.callout).foregroundStyle(Brand.warn) }
                }
                .padding(14)
                Divider()
                HStack(spacing: 0) {
                    Text("Personel").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Ücret").frame(width: 150, alignment: .leading)
                    Text("Saat").frame(width: 96)
                    Text("Çalıştı").frame(width: 70)
                    Text("Ek ödeme (₺)").frame(width: 110).help("Fazla mesai, prim, yol/yemek; işveren çarpanı uygulanır")
                    Text("Maliyet").frame(width: 110, alignment: .trailing)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.primary.opacity(0.04))
                ForEach(Array(list.enumerated()), id: \.element.id) { i, e in
                    let cost = labor.lines.first { $0.employee.id == e.id }?.cost ?? 0
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.name).fontWeight(.medium)
                            Text(e.role.isEmpty ? "—" : e.role).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.payType.title).font(.callout)
                            Text("\(Fmt.money(e.rate, fraction: 0)) \(e.payType.rateLabel.replacingOccurrences(of: "₺ ", with: ""))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(width: 150, alignment: .leading)
                        OptionalDecimalField(value: store.shiftBinding(e.id, date: date, \.hours), placeholder: e.payType == .hourly ? "0" : "—",
                                             maxFraction: 2, width: 80)
                            .frame(width: 96)
                            .help(e.payType == .hourly ? "Çalışılan saat (maliyet bu saate göre hesaplanır)" : "Bilgi amaçlı çalışma saati")
                        Group {
                            if e.payType == .daily {
                                Toggle("", isOn: store.workedBinding(e.id, date: date)).labelsHidden()
                            } else {
                                Text(e.payType == .monthly ? "maaş" : "—").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 70)
                        OptionalDecimalField(value: store.shiftBinding(e.id, date: date, \.extra), placeholder: "0", maxFraction: 2, width: 90)
                            .frame(width: 110)
                        Text(cost > 0 ? Fmt.money(cost) : "—").monospacedDigit().fontWeight(.semibold)
                            .frame(width: 110, alignment: .trailing)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(i % 2 == 0 ? Color.clear : Color.primary.opacity(0.025))
                }
                Divider()
                HStack(spacing: 12) {
                    Text("Diğer personel gideri").foregroundStyle(.secondary)
                    OptionalDecimalField(value: store.otherLaborBinding(date), placeholder: "0", maxFraction: 2, width: 110)
                        .help("Listede olmayan giderler: günlük ek eleman, dışarıdan kurye vb. (₺)")
                    Spacer()
                    Text("Toplam").foregroundStyle(.secondary)
                    Text(Fmt.money(labor.total)).font(.title3.weight(.bold)).monospacedDigit()
                }
                .padding(14)
            }
            .disabled(locked)
        }
    }
}

// MARK: - Ay grafiği

private struct LaborMonthChart: View {
    @EnvironmentObject var store: AppStore
    let date: String

    var body: some View {
        let engine = store.engine
        let start = DateKey.startOfMonth(date)
        let n = (DateKey.distance(from: start, to: date) ?? 0) + 1
        let points: [(date: String, labor: Double, revenue: Double?)] = (0..<n).map { i in
            let d = DateKey.addDays(i, to: start)
            return (d, engine.labor(date: d).total, store.data.days[d]?.salesRevenue)
        }
        let avg = points.isEmpty ? 0 : points.reduce(0) { $0 + $1.labor } / Double(points.count)
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(DateKey.monthTitle(date)) · günlük personel maliyeti").font(.headline)
                    InfoTip(term: .laborCost)
                    Spacer()
                    Text("Ortalama \(Fmt.money(avg)) / gün").font(.callout).foregroundStyle(.secondary)
                }
                Chart {
                    ForEach(points, id: \.date) { p in
                        BarMark(x: .value("Gün", DateKey.date(from: p.date) ?? Date(), unit: .day), y: .value("Personel", p.labor))
                            .foregroundStyle(p.date == date ? Brand.accent : Brand.positive.opacity(0.7))
                            .cornerRadius(3)
                    }
                    RuleMark(y: .value("Ortalama", avg))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                .frame(height: 200)
            }
        }
    }
}

/// Kişi bazında ay toplamı (Tremor "BarList" deseni)
private struct LaborBreakdown: View {
    @EnvironmentObject var store: AppStore
    let date: String

    var body: some View {
        let s = store.engine.laborSummary(from: DateKey.startOfMonth(date), to: date)
        let rows = s.rows.sorted { $0.cost > $1.cost }
        let maxCost = max(rows.first?.cost ?? 1, s.other, 1)
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Bu ay kişi bazında").font(.headline)
                ForEach(rows) { r in
                    bar(r.employee.name, r.employee.role, r.cost, maxCost)
                }
                if s.other > 0 { bar("Diğer giderler", "", s.other, maxCost) }
                Divider()
                HStack {
                    Text("Toplam").fontWeight(.semibold)
                    Spacer()
                    Text(Fmt.money(s.total)).fontWeight(.bold).monospacedDigit()
                }
            }
        }
    }

    private func bar(_ name: String, _ role: String, _ value: Double, _ maxValue: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name).font(.callout).lineLimit(1)
                if !role.isEmpty { Text(role).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                Spacer()
                Text(Fmt.money(value)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { g in
                Capsule().fill(Brand.positive.opacity(0.18))
                    .frame(width: max(4, g.size.width * value / maxValue))
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Personel listesi

private struct EmployeeList: View {
    @EnvironmentObject var store: AppStore
    @State private var deleting: Employee?

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("Personel listesi").font(.headline)
                    Spacer()
                    Text("\(store.employees.filter { $0.active }.count) aktif").font(.callout).foregroundStyle(.secondary)
                }
                .padding(14)
                Divider()
                HStack(spacing: 8) {
                    Text("Ad").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Görev").frame(width: 150, alignment: .leading)
                    Text("Ücret türü").frame(width: 140, alignment: .leading)
                    Text("Ücret (₺)").frame(width: 100)
                    HStack(spacing: 2) { Text("Çarpan"); InfoTip(term: .costFactor) }.frame(width: 80)
                    Text("Vard. saati").frame(width: 80).help("Varsayılan vardiya süresi (\"Vardiyaları Doldur\" bunu kullanır)")
                    Text("Aktif").frame(width: 46)
                    Color.clear.frame(width: 28, height: 1)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.primary.opacity(0.04))
                ForEach(store.employees) { e in
                    EmployeeRow(employee: e) { deleting = e }
                    Divider().padding(.leading, 14)
                }
            }
        }
        .confirmationDialog("\"\(deleting?.name ?? "")\" silinsin mi?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Ayrıldı olarak işaretle (geçmiş korunur)") {
                if let d = deleting { store.markEmployeeLeft(d.id, on: store.selectedDate) }; deleting = nil
            }
            Button("Tamamen sil (tüm vardiya kayıtlarıyla)", role: .destructive) {
                if let d = deleting { store.deleteEmployee(d.id) }; deleting = nil
            }
            Button("Vazgeç", role: .cancel) { deleting = nil }
        } message: {
            Text("İşten ayrılan personel için \"Ayrıldı\" seçin: o günden sonra maliyet yazılmaz, geçmiş raporlar değişmez.")
        }
    }
}

private struct EmployeeRow: View {
    @EnvironmentObject var store: AppStore
    let employee: Employee
    var onDelete: () -> Void

    var body: some View {
        let e = employee
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                CommitTextField(title: "Ad", value: Binding(get: { e.name }, set: { v in
                    guard !v.isEmpty else { return }
                    store.updateEmployee(e.id) { $0.name = v }
                }))
                if let end = e.endDate {
                    Text("Ayrılış: \(DateKey.short(end))").font(.caption2).foregroundStyle(Brand.warn)
                } else if let start = e.startDate {
                    Text("Giriş: \(DateKey.short(start))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CommitTextField(title: "Görev", value: Binding(get: { e.role }, set: { v in store.updateEmployee(e.id) { $0.role = v } }))
                .frame(width: 150)
            Picker("", selection: Binding(get: { e.payType }, set: { v in store.updateEmployee(e.id) { $0.payType = v } })) {
                ForEach(PayType.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().frame(width: 140)
            DecimalField(value: Binding(get: { e.rate }, set: { v in store.updateEmployee(e.id, actionName: "Ücret") { $0.rate = v } }),
                         maxFraction: 2, width: 100)
            DecimalField(value: Binding(get: { e.costFactor }, set: { v in store.updateEmployee(e.id) { $0.costFactor = max(v, 0) } }),
                         maxFraction: 3, width: 80)
            OptionalDecimalField(value: Binding(get: { e.defaultHours }, set: { v in store.updateEmployee(e.id) { $0.defaultHours = v } }),
                                 placeholder: "—", maxFraction: 1, width: 80)
            Toggle("", isOn: Binding(get: { e.active }, set: { v in store.updateEmployee(e.id) { $0.active = v } }))
                .labelsHidden().frame(width: 46)
                .help("Kapalıysa günlük vardiya listesinde görünmez (maliyet için giriş/çıkış tarihleri esas alınır)")
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(Brand.negative.opacity(0.85)).frame(width: 28)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .opacity(e.active ? 1 : 0.6)
    }
}

// MARK: - Personel ekleme

private struct AddEmployeeSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let date: String
    @State private var name = ""
    @State private var role = ""
    @State private var payType: PayType = .monthly
    @State private var rate: Double? = nil
    @State private var factor: Double = 1
    @State private var hours: Double? = nil
    @State private var newHire = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Personel ekle").font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow { Text("Ad Soyad"); TextField("ör. Ayşe K.", text: $name).textFieldStyle(.roundedBorder) }
                GridRow { Text("Görev"); TextField("ör. Usta, Kasa, Kurye", text: $role).textFieldStyle(.roundedBorder) }
                GridRow {
                    Text("Ücret türü")
                    Picker("", selection: $payType) { ForEach(PayType.allCases) { Text($0.title).tag($0) } }
                        .labelsHidden().pickerStyle(.segmented)
                }
                GridRow {
                    Text("Ücret")
                    HStack { OptionalDecimalField(value: $rate, placeholder: "0", maxFraction: 2, width: 120); Text(payType.rateLabel).foregroundStyle(.secondary) }
                }
                GridRow {
                    HStack(spacing: 4) { Text("İşveren çarpanı"); InfoTip(term: .costFactor) }
                    HStack { DecimalField(value: $factor, maxFraction: 3, width: 80); Text("1 = ek yok").font(.caption).foregroundStyle(.secondary) }
                }
                GridRow {
                    Text("Varsayılan vardiya")
                    HStack { OptionalDecimalField(value: $hours, placeholder: "—", maxFraction: 1, width: 80); Text("saat").foregroundStyle(.secondary) }
                }
                GridRow {
                    Text("")
                    Toggle("Yeni işe başladı (giriş: \(DateKey.short(date)))", isOn: $newHire)
                }
            }
            Text(payType == .monthly ? "Aylık maaş, ayın her gününe eşit dağıtılır (çalışılan gün sayısından bağımsız)."
                 : payType == .daily ? "Yevmiye, vardiya listesinde \"çalıştı\" işaretlenen günlere yazılır."
                 : "Saatlik ücret, vardiya listesine girilen saat kadar yazılır.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Ekle") {
                    store.addEmployee(Employee(name: name.trimmingCharacters(in: .whitespaces), role: role.trimmingCharacters(in: .whitespaces),
                                               payType: payType, rate: rate ?? 0, costFactor: factor,
                                               startDate: newHire ? date : nil, defaultHours: hours))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (rate ?? 0) <= 0)
            }
        }
        .padding(22).frame(width: 520)
    }
}
