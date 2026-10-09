import SwiftUI
import EnvanterCore

struct BackupView: View {
    @EnvironmentObject var store: AppStore
    @State private var restoreMessage: String?

    var body: some View {
        let days = store.engine.datesWithData.count
        let backups = store.persistence.backups()
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Ayarlar ve Veri").font(.title2.weight(.semibold))

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("İşletme", systemImage: "building.2").font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                            GridRow {
                                Text("Şube / işletme adı").foregroundStyle(.secondary)
                                CommitTextField(title: "ör. Kadıköy Şubesi", value: store.settingsBinding(\.branchName))
                                    .frame(width: 320)
                            }
                            GridRow {
                                Text("Sayım yapan personel").foregroundStyle(.secondary)
                                CommitTextField(title: "Virgülle ayırın: Ahmet, Ayşe", value: Binding(
                                    get: { store.settings.staff.joined(separator: ", ") },
                                    set: { v in
                                        let names = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                                        store.updateSettings("Personel Listesi") { $0.staff = names }
                                    }))
                                    .frame(width: 320)
                            }
                        }
                        Text("Şube adı yan menüde, dışa aktarılan dosya adlarında ve sipariş listesinde görünür. Her şubede ayrı bir Mac kullanılıyorsa farklı ad verin.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Verileriniz otomatik kaydedilir", systemImage: "checkmark.shield.fill")
                            .font(.headline).foregroundStyle(Brand.ok)
                        Text("Her değişiklik birkaç saniye içinde diske yazılır, gün içinde düzenli aralıklarla otomatik yedek alınır (son \(Persistence.keptBackups) gün saklanır). Toplu aktarım ve geri yükleme öncesinde ayrıca anlık kopya alınır. Yanlış bir işlemi Düzen > Geri Al (⌘Z) ile geri alabilirsiniz.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(store.persistence.directory.path).font(.callout.monospaced()).textSelection(.enabled)
                        HStack {
                            Button { NSWorkspace.shared.activateFileViewerSelecting([store.persistence.directory]) } label: {
                                Label("Klasörü Finder'da göster", systemImage: "folder")
                            }.buttonStyle(SoftButtonStyle())
                            Text("\(days) günlük kayıt · \(store.data.products.count) ürün reçetesi · \(store.data.items.count) stok kalemi · \(backups.count) yedek")
                                .foregroundStyle(.secondary)
                        }
                        SaveStatusView()
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Yedek dosyası").font(.headline)
                        Text("Tüm verilerinizi tek bir dosya olarak kaydedin; başka bir Mac'e taşımak veya geri dönmek için kullanın.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button { store.exportBackup() } label: { Label("Yedek Oluştur…", systemImage: "square.and.arrow.down") }
                                .buttonStyle(PrimaryButtonStyle())
                            Button { store.restoreBackup() } label: { Label("Yedekten Geri Yükle…", systemImage: "arrow.counterclockwise") }
                                .buttonStyle(SoftButtonStyle())
                        }
                        if let last = backups.first {
                            Text("Son otomatik yedek: \(last.lastPathComponent)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Excel").font(.headline)
                        Text("Tüm günlerin envanteri eski \"Alımlar\" sayfasıyla aynı sütun düzeninde (Tarih, Ürün, Açılış, Gelen, … Fark) dışa aktarılır; ayrıca Özet, Günlük Maliyet ve Notlar sayfaları eklenir. Sayım formu, depoda elle doldurmak için yazdırılabilir bir listedir.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button {
                                let d = store.engine.datesWithData
                                store.exportHistoryExcel(from: d.first ?? DateKey.today(), to: d.last ?? DateKey.today())
                            } label: { Label("Tüm Geçmişi Excel'e Aktar…", systemImage: "tablecells") }
                                .buttonStyle(SoftButtonStyle()).disabled(days == 0)
                            Button { store.exportCountSheet() } label: { Label("Sayım Formu (\(DateKey.short(store.selectedDate)))…", systemImage: "printer") }
                                .buttonStyle(SoftButtonStyle())
                        }
                        Divider()
                        Text("Eski Excel envanter dosyanızdaki (ör. 01.08.xlsm) geçmiş günlük kayıtları (Alımlar sayfası ve pivot önbelleği), Envanter sayfasındaki güncel sayımı ve yapıştırılmış ModPos satışlarını aktarır. Veri girilmiş günlerin üzerine yazmaz (isterseniz seçebilirsiniz).")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button { store.pickAndImportWorkbook() } label: { Label("Excel Envanter Dosyası Seç ve Aktar…", systemImage: "tablecells.badge.ellipsis") }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Varsayılan reçeteler").font(.headline)
                        Text("Excel dosyanızdaki (KOD sayfası) reçeteler uygulamaya hazır olarak yüklenmiştir. Yanlışlıkla sildiğiniz ürün veya stok kalemi olursa geri ekleyebilirsiniz; yaptığınız düzenlemelere dokunulmaz.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button {
                                let r = store.restoreMissingDefaults()
                                restoreMessage = r.items + r.products == 0 ? "Eksik varsayılan kayıt yok."
                                    : "\(r.products) ürün reçetesi ve \(r.items) stok kalemi geri eklendi."
                            } label: { Label("Eksik Varsayılanları Geri Ekle", systemImage: "arrow.uturn.backward.circle") }
                                .buttonStyle(SoftButtonStyle())
                            if let m = restoreMessage { Text(m).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .padding(24).frame(maxWidth: 860, alignment: .leading)
        }
        .navigationTitle("Ayarlar ve Veri")
    }
}

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(Brand.appName) — Nasıl Kullanılır?").font(.title2.weight(.semibold))
                Text("Bu uygulama, Excel'deki envanter dosyanızın (Envanter, KOD, Alımlar, Özet sayfaları ve makroları) yaptığı işi otomatik yapar; üstüne maliyet, kayıp, sipariş ve menü analizleri ekler.")
                    .foregroundStyle(.secondary)

                step(1, "Kalemleri hazırlayın", "Stok Kalemleri ekranında her kalemin birim maliyetini (₺), kritik seviyesini ve kabul edilebilir farkını (tolerans) girin. Bunlar boş bırakılabilir; girildikçe ₺ hesapları, uyarılar ve sipariş önerisi devreye girer.")
                step(2, "Sayımı girin", "Günlük Envanter ekranında her kalem için Gelen, Gelen/Giden Transfer ve gün sonu Kapanış sayımını yazın. Açılış, bir önceki günün kapanışından kendiliğinden gelir. Enter veya ↓ ile alt satıra, Tab ile yana geçersiniz; virgül de nokta da kabul edilir. Depoda kâğıtla saymak için Ayarlar ve Veri ekranından sayım formu alabilirsiniz.")
                step(3, "ModPos satış raporunu aktarın", "Satış raporunu (.xlsx) pencereye sürükleyip bırakın ya da \"Dosyadan Aktar\"a tıklayın. Kodu / Ürün Tipi / Adedi (varsa Tutar) sütunlarını kopyalayıp \"Panodan Yapıştır\" da diyebilirsiniz (⌘⇧V). Tutar sütunu varsa maliyet yüzdeleri ve menü analizi de hesaplanır.")
                step(4, "Farkı okuyun", "Fark = (Satılan + Zaiyat) − Fiili Tüketim. Kırmızı: satışlara göre fazla stok çıkmış (kayıp). Mavi: az çıkmış (sayım/reçete hatası olabilir). Yeşil: fark yok ya da tolerans içinde. Satırdaki ⓘ düğmesi hesabın dökümünü gösterir. \"Sorunlu\" filtresi yalnızca dikkat gerektiren kalemleri listeler.")
                step(5, "Günü kapatın", "Sayım bitince \"Günü Kapat\" ile günü kilitleyin; yanlışlıkla değiştirilemez. Güne not ve sayımı yapan kişiyi ekleyebilirsiniz. Hiç hareketi olmayan kalemleri \"Hareketsizleri Doldur\" ile tek tıkla kapatabilirsiniz.")
                step(6, "Eksik reçeteleri tamamlayın", "Satış raporunda reçetesi tanımlı olmayan bir ürün çıkarsa uyarı görünür. Satış Dökümü ekranından \"Reçete tanımla\" ile hammaddesini girin. Reçeteler ekranı her ürünün reçete maliyetini ve satış fiyatına göre maliyet oranını gösterir.")
                step(7, "Raporlar ve istatistikler", "Genel Bakış günün durumunu ve son 14 günün kaybını; Özet dönem toplamlarını; İstatistikler ise maliyet yüzdesi (food cost %), en çok kayıp veren kalemler, zayi dağılımı, kalem bazında tüketim grafikleri, ABC analizi ve menü mühendisliğini gösterir.")
                step(8, "Sipariş verin", "Sipariş Önerisi ekranı son günlerin ortalama tüketimine ve kritik seviyelere göre ne kadar sipariş vermeniz gerektiğini hesaplar; \"Listeyi Kopyala\" ile tedarikçiye WhatsApp'tan gönderebilirsiniz.")

                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Excel'den farkı", systemImage: "info.circle").font(.headline)
                        Text("Excel dosyanızdaki bazı formüller Yan Ürünler ve Tavuk Yiyelim kategorilerini toplamaya katmıyordu (Smash 70 Gr, Peynir ve 60 Gr satırları eksik çıkıyordu). Uygulama tüm kategorileri hesaba katar. Ayrıca birkaç hatalı reçete formülü düzeltilmiştir; bunlar Reçeteler ekranında sarı bir notla işaretlidir.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Kısayollar", systemImage: "keyboard").font(.headline)
                        Group {
                            Text("⌘O  Satış raporu içe aktar     ⌘⇧V  Panodan satış yapıştır     ⌘E  Günü Excel'e aktar")
                            Text("⌘[  Önceki gün     ⌘]  Sonraki gün     ⌘T  Bugüne git     ⌘L  Günü kapat / aç")
                            Text("⌘1…⌘9  Ekranlar arasında geçiş     ⌘Z / ⇧⌘Z  Geri al / Yinele")
                        }.font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24).frame(maxWidth: 860, alignment: .leading)
        }
        .navigationTitle("Nasıl Kullanılır?")
    }

    private func step(_ n: Int, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)").font(.headline).foregroundStyle(.white)
                .frame(width: 28, height: 28).background(Circle().fill(Brand.accent))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
