import Foundation

// Sayım Excel'i (web `src/lib/countImport.ts`): şablon ("Sayım Formu") ve yükleme. Kurallar docs/SYNC.md → Sayım Excel'i;
// ortak test vektörleri Fixtures/countimport-vectors.json (web test/fixtures/, birebir aynı dosya).

public enum CountImport {
    // MARK: - Hücre, sütun, alan

    /// Tablo hücresi: metin ya da sayı (boş hücre nil)
    public enum Cell: Equatable, Sendable {
        case text(String)
        case number(Double)

        /// Kod ve ad karşılaştırması için metin: tam sayı "303", diğer sayılar "16.8"
        var string: String {
            switch self {
            case .text(let s): return s
            case .number(let v):
                if v.isFinite, v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
                return String(v)
            }
        }
    }

    /// Başlık satırındaki sütun türleri (ham değerler vektörlerdeki adlar)
    public enum Column: String, CaseIterable, Sendable {
        case item, code, unit, opening, incoming, transferIn, transferOut, waste, closing, note

        /// Miktar sütunu: başlık satırı en az birini taşır (Devreden yüklenmez, yalnızca başlığı tanır)
        var isQuantity: Bool {
            switch self {
            case .opening, .incoming, .transferIn, .transferOut, .waste, .closing: return true
            case .item, .code, .unit, .note: return false
            }
        }

        /// Ekrandaki adı (hatalı hücre satırında)
        public var title: String {
            switch self {
            case .item: return "Kalem"
            case .code: return "Kod"
            case .unit: return "Birim"
            case .opening: return CountText.opening
            case .incoming: return CountText.incoming
            case .transferIn: return CountText.transferIn
            case .transferOut: return CountText.transferOut
            case .waste: return CountText.waste
            case .closing: return CountText.closing
            case .note: return "Not"
            }
        }
    }

    /// Yüklenen alanlar (önizlemedeki sıra: Giren, Şubeden gelen, Çıkan, Zayi, Kalan)
    public enum Field: String, CaseIterable, Sendable {
        case incoming, transferIn, transferOut, waste, closing

        public var title: String { column.title }

        public var column: Column {
            switch self {
            case .incoming: return .incoming
            case .transferIn: return .transferIn
            case .transferOut: return .transferOut
            case .waste: return .waste
            case .closing: return .closing
            }
        }
    }

    /// Başlık adları (katlanmış: Türkçe harfler ASCII, küçük harf, tek boşluk). Sıra önemli: ilk eşleşen kazanır.
    public static let aliases: [(column: Column, names: [String])] = [
        (.transferIn, ["gelen transfer", "transfer gelen", "gelen tr"]),
        (.transferOut, ["giden transfer", "transfer giden", "giden tr"]),
        (.item, ["kalem", "urun", "malzeme", "stok kalemi", "ad"]),
        (.code, ["kod", "stok kodu"]),
        (.unit, ["birim"]),
        (.opening, ["devreden", "acilis", "onceki"]),
        (.incoming, ["giren", "gelen", "giris", "alim", "alis", "teslim"]),
        (.transferOut, ["cikan", "cikis", "giden"]),
        (.waste, ["zayi", "zaiyat", "fire"]),
        (.closing, ["kalan", "kapanis", "sayim", "sayilan", "mevcut"]),
        (.note, ["not", "aciklama"]),
    ]

    /// Satırdaki alanların okunma sırası (hatalı hücreler bu sırayla bildirilir)
    static let readOrder: [Field] = [.incoming, .transferIn, .transferOut, .closing, .waste]

    /// Başlık satırı ilk kaç satırda aranır
    public static let headerSearchRows = 15

    // MARK: - Sonuç

    /// Bir kalemin yüklenecek değerleri (yalnızca dolu ve geçerli hücreler)
    public struct Update: Equatable, Sendable {
        /// Excel satırı (1'den)
        public var row: Int
        public var itemID: String
        public var values: [Field: Double]
        public init(row: Int, itemID: String, values: [Field: Double]) {
            self.row = row; self.itemID = itemID; self.values = values
        }
    }

    /// Stok kalemlerinde bulunamayan satır
    public struct Unknown: Equatable, Sendable {
        public var row: Int
        public var name: String
    }

    /// Okunamayan hücre (değer dosyadaki haliyle)
    public struct CellError: Equatable, Sendable {
        public var row: Int
        public var column: Column
        public var value: Cell
    }

    /// Aynı kalemin ikinci (ve sonraki) satırı: yok sayılır, ilk satır kullanılır
    public struct Duplicate: Equatable, Sendable {
        public var row: Int
        public var itemID: String
    }

    public struct Result: Equatable, Sendable {
        /// Başlık satırı (1'den); bulunamadıysa nil ve `message` dolu
        public var headerRow: Int?
        /// Sütun türü → sütun sırası (0'dan)
        public var columns: [Column: Int] = [:]
        public var updates: [Update] = []
        public var unknown: [Unknown] = []
        public var errors: [CellError] = []
        public var duplicates: [Duplicate] = []
        public var message: String?
        public init() {}
    }

    // MARK: - Ayrıştırma

    /// Başlık karşılaştırması ve kalem adı eşleştirmesi için katlanmış metin
    static func fold(_ s: String) -> String {
        TextFold.ascii(s).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Başlık hücresinin türü. " · " içeren ya da gg.aa.yyyy tarihi taşıyan hücre (şablonun başlığı) kalem sütunudur.
    static func classify(_ cell: Cell?) -> Column? {
        guard case .text(let raw)? = cell else { return nil }
        if raw.contains("·") || raw.range(of: #"\d{2}\.\d{2}\.\d{4}"#, options: .regularExpression) != nil { return .item }
        let f = fold(raw)
        guard !f.isEmpty else { return nil }
        for (column, names) in aliases {
            for a in names where f == a || f.hasPrefix(a + " ") || f.hasPrefix(a + "(") { return column }
        }
        return nil
    }

    /// İlk 15 satırda kalem ya da kod sütunu VE en az bir miktar sütunu olan ilk satır (aynı türden ikinci sütun yok sayılır)
    static func findHeader(_ grid: [[Cell?]]) -> (row: Int, columns: [Column: Int])? {
        for (r, row) in grid.prefix(headerSearchRows).enumerated() {
            var cols: [Column: Int] = [:]
            for (c, cell) in row.enumerated() {
                if let k = classify(cell), cols[k] == nil { cols[k] = c }
            }
            if (cols[.item] != nil || cols[.code] != nil) && cols.keys.contains(where: { $0.isQuantity }) { return (r, cols) }
        }
        return nil
    }

    /// Dosya bir sayım tablosu mu (başlık satırı bulunuyor)
    public static func isCountSheet(_ grid: [[Cell?]]) -> Bool { findHeader(grid) != nil }

    /// Boş, "-", "—", "–" hücre değişiklik değildir
    static func isBlank(_ cell: Cell?) -> Bool {
        guard let cell else { return true }
        guard case .text(let s) = cell else { return false }
        return ["", "-", "—", "–"].contains(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Sayı hücresi olduğu gibi (eksi geçersiz); metin hücre kalemin birimine göre toplayarak giriş kuralıyla
    static func number(_ cell: Cell, isKg: Bool) -> Double? {
        switch cell {
        case .number(let v): return v.isFinite && v >= 0 && v < 1e12 ? v : nil
        case .text(let s): return Fmt.parseCountExpression(s, isKg: isKg)
        }
    }

    /// Tabloyu okur: kalem önce kodla (büyük/küçük harf duyarsız), sonra katlanmış adla bulunur. `items`: aktif kalemler.
    public static func parse(grid: [[Cell?]], items: [Item]) -> Result {
        var result = Result()
        guard let header = findHeader(grid) else {
            result.message = CountImportText.noHeader
            return result
        }
        result.headerRow = header.row + 1
        result.columns = header.columns
        let byID = Dictionary(items.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { _, last in last })
        let byName = Dictionary(items.map { (fold($0.name), $0) }, uniquingKeysWith: { _, last in last })
        var seen = Set<String>()
        for r in grid.indices where r > header.row {
            let row = grid[r]
            func cell(_ column: Column) -> Cell? {
                guard let i = header.columns[column], i < row.count else { return nil }
                return row[i]
            }
            let name = cell(.item), code = cell(.code)
            if isBlank(name) && isBlank(code) { continue }
            var found: Item?
            if !isBlank(code), let code { found = byID[code.string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] }
            if found == nil, !isBlank(name), let name { found = byName[fold(name.string)] }
            guard let item = found else {
                let label = (isBlank(name) ? code : name)?.string ?? ""
                result.unknown.append(Unknown(row: r + 1, name: label.trimmingCharacters(in: .whitespacesAndNewlines)))
                continue
            }
            guard seen.insert(item.id).inserted else {
                result.duplicates.append(Duplicate(row: r + 1, itemID: item.id))
                continue
            }
            var values: [Field: Double] = [:]
            for field in readOrder {
                guard let value = cell(field.column), !isBlank(value) else { continue }
                if let n = number(value, isKg: item.isKg) {
                    values[field] = n
                } else {
                    result.errors.append(CellError(row: r + 1, column: field.column, value: value))
                }
            }
            if !values.isEmpty { result.updates.append(Update(row: r + 1, itemID: item.id, values: values)) }
        }
        return result
    }

    // MARK: - Önizleme ve uygulama

    /// Bir alanın eski ve yeni değeri
    public struct FieldChange: Equatable, Sendable {
        public var field: Field
        public var old: Double?
        public var new: Double
    }

    /// Bir kalemde değişecek alanlar
    public struct ItemChange: Equatable, Sendable, Identifiable {
        public var row: Int
        public var itemID: String
        public var changes: [FieldChange]
        public var id: String { itemID }
        public func change(_ field: Field) -> FieldChange? { changes.first { $0.field == field } }
    }

    /// Kalemin o günkü Excel zayi kaydının kimliği
    public static func wasteEntryID(_ itemID: String) -> String { "excel-" + itemID }
    /// Excel zayi kaydının notu
    public static let wasteNote = "Excel'den yüklendi"

    /// Kalemin o günkü Excel zayi kaydı (yoksa nil)
    public static func excelWaste(_ day: DayRecord?, itemID: String) -> WasteEntry? {
        let id = wasteEntryID(itemID)
        return day?.wasteLog?.first { $0.id == id }
    }

    /// Alanın gündeki değeri (Zayi: kalemin Excel zayi kaydı)
    public static func current(_ field: Field, itemID: String, day: DayRecord?) -> Double? {
        let e = day?.entries[itemID]
        switch field {
        case .incoming: return e?.incoming
        case .transferIn: return e?.transferIn
        case .transferOut: return e?.transferOut
        case .closing: return e?.closing
        case .waste: return excelWaste(day, itemID: itemID)?.qty
        }
    }

    /// Değişiklik değil mi: girişlerde (Giren, Şubeden gelen, Çıkan, Kalan) boş değere yazılan her değer (0 da) değişikliktir;
    /// Zayi'de kayıt yoksa 0 sayılır (web `countImportPreview` ile aynı)
    static func isSame(_ field: Field, old: Double?, new: Double) -> Bool {
        if field == .waste { return abs(Engine.clean(old ?? 0) - Engine.clean(new)) < 1e-9 }
        guard let old else { return false }
        return abs(Engine.clean(old) - Engine.clean(new)) < 1e-9
    }

    /// Gerçekten değişecek kalemler ve alanlar (Excel satır sırasıyla)
    public static func changes(_ updates: [Update], day: DayRecord?) -> [ItemChange] {
        updates.compactMap { u -> ItemChange? in
            let list = Field.allCases.compactMap { field -> FieldChange? in
                guard let v = u.values[field] else { return nil }
                let old = current(field, itemID: u.itemID, day: day)
                return isSame(field, old: old, new: v) ? nil : FieldChange(field: field, old: old, new: Engine.clean(v))
            }
            return list.isEmpty ? nil : ItemChange(row: u.row, itemID: u.itemID, changes: list)
        }
    }

    /// Değerleri güne yazar. Zayi kalemin `excel-<kimlik>` kaydını ayarlar (neden "other", not "Excel'den yüklendi",
    /// kim `wasteBy`); 0 kaydı siler. Diğer elle zayi kayıtlarına dokunulmaz.
    public static func apply(_ updates: [Update], to day: DayRecord, wasteBy: String?, at: Date = Date()) -> DayRecord {
        var d = day
        for item in changes(updates, day: day) {
            var e = d.entries[item.itemID] ?? DayEntry()
            for c in item.changes {
                switch c.field {
                case .incoming: e.incoming = c.new
                case .transferIn: e.transferIn = c.new
                case .transferOut: e.transferOut = c.new
                case .closing: e.closing = c.new
                case .waste:
                    let id = wasteEntryID(item.itemID)
                    if let entry = WasteLog.make(id: id, itemID: item.itemID, qty: c.new, reason: .other, note: wasteNote, by: wasteBy, at: at) {
                        if let i = d.wasteLog?.firstIndex(where: { $0.id == id }) {
                            d.wasteLog?[i] = entry
                        } else {
                            d = WasteLog.adding(entry, to: d)
                        }
                    } else {
                        d = WasteLog.removing(id: id, from: d)
                    }
                }
            }
            if e.isEmpty { d.entries[item.itemID] = nil } else { d.entries[item.itemID] = e }
        }
        return d
    }

    // MARK: - Şablon

    public static let sheetName = "Sayım Formu"
    public static let templateHeader = ["Kalem", "Kod", "Birim", "Devreden", "Giren", "Çıkan", "Zayi", "Kalan (sayım)", "Not"]
    public static let templateWidths: [Double] = [28, 12, 8, 11, 11, 11, 11, 14, 28]

    /// 1. satır: "Tuzla Marina · Sayım 31.08.2026" (şube yoksa "Sayım 31.08.2026")
    public static func title(branch: String, date: String) -> String {
        (branch.isEmpty ? "" : branch + " · ") + "Sayım \(DateKey.short(date))"
    }

    /// Aktif kalemler ekrandaki sırayla: Devreden hesaplanan değer, girilmemiş değerler boş, Zayi kalemin Excel zayi kaydı
    public static func templateRows(engine: Engine, date: String) -> [[XlsxCell]] {
        let day = engine.data.days[date]
        return engine.calc(date: date).rows.compactMap { c -> [XlsxCell]? in
            guard let item = engine.itemsByID[c.itemID] else { return nil }
            let e = day?.entries[item.id]
            return [.text(item.name), .text(item.id), .text(item.unit), .number(c.opening),
                    .optNumber(e?.incoming), .optNumber(e?.transferOut), .optNumber(excelWaste(day, itemID: item.id)?.qty),
                    .optNumber(e?.closing), XlsxCell(.blank)]
        }
    }

    /// Şablon sayfası: 1. satır başlık, 2. satır sütun başlıkları, kalemler 3. satırdan
    public static func template(engine: Engine, date: String, branch: String = "") -> XlsxSheetData {
        XlsxSheetData(name: sheetName, header: templateHeader, rows: templateRows(engine: engine, date: date),
                      widths: templateWidths, title: title(branch: branch, date: date))
    }

    // MARK: - Dosya okuma

    /// Excel sayfası → tablo (sayısal hücreler sayı, diğerleri metin; satır numaraları korunur)
    public static func grid(sheet: XlsxSheet) -> [[Cell?]] {
        let maxRow = sheet.maxRow
        guard maxRow > 0 else { return [] }
        return (1...maxRow).map { r -> [Cell?] in
            guard let cols = sheet.rows[r], let maxCol = cols.keys.max(), maxCol > 0 else { return [] }
            return (1...maxCol).map { c -> Cell? in
                guard let raw = cols[c] else { return nil }
                if sheet.isNumeric(row: r, col: c), let v = Fmt.machine(raw) { return .number(v) }
                return .text(raw)
            }
        }
    }

    /// CSV / TSV metni → tablo (ayırıcı: sekme, yoksa ";", yoksa ","; tüm hücreler metin)
    public static func grid(text: String) -> [[Cell?]] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let delimiter: Character = lines.contains { $0.contains("\t") } ? "\t" : (lines.contains { $0.contains(";") } ? ";" : ",")
        return lines.map { raw -> [Cell?] in
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
            return SalesParser.splitFields(line, delimiter: delimiter).map { f -> Cell? in f.isEmpty ? nil : .text(f) }
        }
    }

    /// Dosya → tablo: .xlsx / .xlsm ilk sayfa, .csv / .tsv / .txt metin
    public static func readGrid(data: Data, fileName: String) throws -> [[Cell?]] {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        switch ext {
        case "xlsx", "xlsm":
            let sheets: [XlsxSheet]
            do { sheets = try XlsxReader.read(data: data) } catch { throw CountImportError.unreadable }
            guard let first = sheets.first else { throw CountImportError.unreadable }
            return grid(sheet: first)
        case "csv", "tsv", "txt":
            return grid(text: SalesParser.decodeText(data))
        default:
            throw CountImportError.unsupported(ext.isEmpty ? fileName : "." + ext)
        }
    }
}

public enum CountImportError: Error, LocalizedError, Equatable {
    case unsupported(String)
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .unsupported(let ext): return "\(ext) dosyası okunamaz. Sayım Excel'ini .xlsx (ya da .csv / .tsv) olarak seçin."
        case .unreadable: return "Excel dosyası açılamadı. Dosyanın bozuk olmadığından emin olun ya da Şablonu İndir ile yeni şablon alın."
        }
    }
}

/// Sayım Excel'i metinleri (web `COUNT_IMPORT_TEXT`)
public enum CountImportText {
    public static let menu = "Excel"
    public static let templateButton = "Şablonu İndir"
    public static let uploadButton = "Excel'den Yükle…"
    /// Mac menü komutları
    public static let templateCommand = "Sayım Şablonu (Excel)…"
    public static let uploadCommand = "Excel'den Sayım Yükle…"
    public static let title = "Excel'den Sayım Yükle"
    public static let apply = "Uygula"
    /// Düzen > "… Geri Al"
    public static let actionName = "Excel'den Sayım Yükleme"
    public static let noHeader = "Başlık satırı bulunamadı"
    public static let noHeaderHint = "İlk satırlarda Kalem (ya da Kod) sütunu ve en az bir miktar sütunu (Giren, Çıkan, Zayi, Kalan) olmalı. Şablonu indirip doldurun."
    public static let nothingToApply = "Dosyada bu günün değerlerinden farklı bir değer yok."
    public static let rules = "Boş hücreler değiştirilmez. Devreden, Birim ve Not yüklenmez. Zayi kalemin Excel zayi kaydını ayarlar (0 siler); elle girilen diğer zayi kayıtlarına dokunulmaz."
    public static let unknownTitle = "Bilinmeyen kalemler"
    public static let errorsTitle = "Okunamayan hücreler"
    public static let duplicatesTitle = "Yinelenen satırlar (ilk satır kullanıldı)"

    /// "4 kalem değişecek · 3 kalem aynı · 1 bilinmeyen kalem · 2 okunamayan hücre · 1 yinelenen satır" (web önizlemesiyle aynı sıra)
    public static func summary(changed: Int, unchanged: Int, unknown: Int, errors: Int, duplicates: Int) -> String {
        var parts = ["\(changed) kalem değişecek"]
        if unchanged > 0 { parts.append("\(unchanged) kalem aynı") }
        if unknown > 0 { parts.append("\(unknown) bilinmeyen kalem") }
        if errors > 0 { parts.append("\(errors) okunamayan hücre") }
        if duplicates > 0 { parts.append("\(duplicates) yinelenen satır") }
        return parts.joined(separator: " · ")
    }

    /// "— → 640", "420 → 400"
    public static func change(_ c: CountImport.FieldChange, item: Item) -> String {
        let f: (Double) -> String = { Fmt.number($0, maxFraction: item.maxFraction) }
        return "\(c.old.map(f) ?? "—") → \(f(c.new))"
    }

    /// "Satır 4 · Bilinmeyen Kalem"
    public static func unknownLine(_ u: CountImport.Unknown) -> String { "Satır \(u.row) · \(u.name)" }

    /// "Satır 2 · Giren: -5"
    public static func errorLine(_ e: CountImport.CellError) -> String {
        let value: String
        switch e.value {
        case .text(let s): value = s
        case .number(let v): value = Fmt.number(v, maxFraction: 6)
        }
        return "Satır \(e.row) · \(e.column.title): \(value)"
    }

    /// "Satır 3 · Patates"
    public static func duplicateLine(_ d: CountImport.Duplicate, name: String) -> String { "Satır \(d.row) · \(name)" }

    /// Uygulandıktan sonra Günlük Sayım'daki bildirim
    public static func applied(_ count: Int) -> String { "Excel'den yüklendi: \(count) kalem güncellendi" }
}
