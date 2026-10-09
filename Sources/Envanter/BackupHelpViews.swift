import SwiftUI
import EnvanterCore

struct BackupView: View {
    @EnvironmentObject var store: AppStore
    @State private var restoreMessage: String?

    var body: some View {
        let days = store.data.days.values.filter { !$0.isEmpty }.count
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Yedek ve Veri").font(.title2.weight(.semibold))

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Verileriniz otomatik kaydedilir", systemImage: "checkmark.shield.fill")
                            .font(.headline).foregroundStyle(Brand.ok)
                        Text("Her değişiklik anında diske yazılır ve her gün otomatik yedek alınır (son 30 gün saklanır). Veri dosyası uygulamanın içinde değil, aşağıdaki klasördedir; uygulamayı silseniz veya taşısanız bile verileriniz kaybolmaz.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(store.persistence.directory.path).font(.callout.monospaced()).textSelection(.enabled)
                        HStack {
                            Button { NSWorkspace.shared.activateFileViewerSelecting([store.persistence.directory]) } label: {
                                Label("Klasörü Finder'da göster", systemImage: "folder")
                            }.buttonStyle(SoftButtonStyle())
                            Text("\(days) günlük kayıt · \(store.data.products.count) ürün reçetesi · \(store.data.items.count) stok kalemi")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Excel envanter dosyasından içe aktar").font(.headline)
                        Text("Eski Excel dosyanızdaki (ör. 01.08.xlsm) geçmiş günlük kayıtları (Alımlar sayfası ve pivot önbelleği), Envanter sayfasındaki güncel sayımı ve yapıştırılmış ModPos satışlarını aktarır. Veri girilmiş günlerin üzerine yazmaz (isterseniz seçebilirsiniz).")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button { store.pickAndImportWorkbook() } label: { Label("Excel Dosyası Seç ve Aktar…", systemImage: "tablecells.badge.ellipsis") }
                            .buttonStyle(PrimaryButtonStyle())
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
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Excel'e aktar").font(.headline)
                        Text("Tüm günlerin envanteri, eski \"Alımlar\" sayfasıyla aynı sütun düzeninde (Tarih, Ürün, Açılış, Gelen, … Fark) dışa aktarılır; mevcut Excel pivot tablolarınıza yapıştırabilirsiniz.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button {
                            let d = store.engine.datesWithData
                            store.exportHistoryExcel(from: d.first ?? DateKey.today(), to: d.last ?? DateKey.today())
                        } label: { Label("Tüm Geçmişi Excel'e Aktar…", systemImage: "tablecells") }
                            .buttonStyle(SoftButtonStyle()).disabled(days == 0)
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
            .padding(24).frame(maxWidth: 820, alignment: .leading)
        }
        .navigationTitle("Yedek ve Veri")
    }
}

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Nasıl Kullanılır?").font(.title2.weight(.semibold))
                Text("Bu uygulama, Excel'deki envanter dosyanızın (Envanter, KOD, Alımlar, Özet sayfaları ve makroları) yaptığı işi otomatik yapar.")
                    .foregroundStyle(.secondary)

                step(1, "Sayımı girin", "Günlük Envanter ekranında her kalem için Gelen, Gelen/Giden Transfer ve gün sonu Kapanış sayımını yazın. Açılış, bir önceki günün kapanışından kendiliğinden gelir (Excel'deki \"Yeni Envanter Aç\" makrosunun işi). Enter veya ↓ ile alt satıra, Tab ile yana geçersiniz; virgül de nokta da kabul edilir.")
                step(2, "ModPos satış raporunu aktarın", "ModPos'tan aldığınız satış raporunu (.xlsx) pencereye sürükleyip bırakın ya da \"Dosyadan Aktar\"a tıklayın. Excel'de olduğu gibi Kodu / Ürün Tipi / Adedi sütunlarını kopyalayıp \"Panodan Yapıştır\" da diyebilirsiniz (⌘⇧V).")
                step(3, "Satılan ve Zaiyat otomatik dolar", "Her ürün reçetesine göre hammaddeden düşülür. Örnek: 1 Kasap Burger satılınca 130 gr'a 1; 1 Dublex Burger satılınca 90 gr'a 2 yazılır. ZAYİ ürünleri Zaiyat sütununa gider.")
                step(4, "Farkı okuyun", "Fark = (Satılan + Zaiyat) − Fiili Tüketim. Fiili Tüketim = Açılış + Gelen + Gelen Transfer − (Giden Transfer + Kapanış). Kırmızı negatif sayı, satışlara göre olması gerekenden fazla stok çıktığı anlamına gelir. Satırdaki ⓘ düğmesi hesabın dökümünü ve hangi ürünlerin etkilediğini gösterir.")
                step(5, "Eksik reçeteleri tamamlayın", "Satış raporunda reçetesi tanımlı olmayan bir ürün çıkarsa Günlük Envanter'in üstünde sarı uyarı görünür. Satış Dökümü ekranından \"Reçete tanımla\" ile hammaddesini girin; başka bir ürünün reçetesini kopyalayabilirsiniz. Reçeteler ekranından istediğiniz zaman düzenleyebilirsiniz.")
                step(6, "Raporlar ve Excel", "Özet ve Raporlar ekranı seçtiğiniz dönemin toplamlarını ve günlük fark grafiğini gösterir; \"Excel'e Aktar\" ile eski Alımlar/Özet düzeninde Excel dosyası alabilirsiniz.")

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
                            Text("⌘[  Önceki gün     ⌘]  Sonraki gün     ⌘T  Bugüne git")
                        }.font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24).frame(maxWidth: 820, alignment: .leading)
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
