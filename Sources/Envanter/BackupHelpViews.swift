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
                                Text("Sayım yapanlar (hızlı seçim)").foregroundStyle(.secondary)
                                CommitTextField(title: "Virgülle ayırın: Ahmet, Ayşe", value: Binding(
                                    get: { store.settings.staff.joined(separator: ", ") },
                                    set: { v in
                                        let names = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                                        store.updateSettings("Sayım Yapanlar") { $0.staff = names }
                                    }))
                                    .frame(width: 320)
                            }
                        }
                        .disabled(!store.canEditCatalog)
                        Text("Şube adı yan menüde, dışa aktarılan dosya adlarında ve sipariş listesinde görünür. Her şubede ayrı bir Mac kullanılıyorsa farklı ad verin.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if !store.canEditCatalog { ReadOnlyNote() }
                    }
                }

                CloudSyncCard(cloud: store.cloud)

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Hedefler ve uyarılar", systemImage: "target").font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                            targetRow("Hammadde maliyet oranı", .foodCostPct, \.targetFoodCostPct, hint: "ör. %30")
                            targetRow("Personel oranı", .laborPct, \.targetLaborPct, hint: "ör. %25")
                            targetRow("Prime cost oranı", .primeCost, \.targetPrimeCostPct, hint: "ör. %60")
                            GridRow {
                                HStack(spacing: 4) { Text("Fiyat artışı uyarısı").foregroundStyle(.secondary); InfoTip(term: .priceAlert) }
                                HStack {
                                    Text("%")
                                    DecimalField(value: Binding(get: { store.settings.priceAlertPct * 100 },
                                                                set: { v in store.updateSettings("Fiyat Uyarısı") { $0.priceAlertPct = max(v, 0) / 100 } }),
                                                 maxFraction: 1, width: 70)
                                    Text("ve üzeri artışlar son 30 gün içinde uyarılır").font(.callout).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(!store.canEditCatalog)
                        Text("Hedefler Genel Bakış, Personel ve İstatistikler ekranlarında çubukla gösterilir; aşıldığında kırmızıya döner. Boş bırakılan hedef gösterilmez.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if !store.canEditCatalog { ReadOnlyNote() }
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
                                // Personel hesabıyla tanımlar ve kapatılmış günler değiştirilemez
                                .disabled(!store.canEditCatalog)
                                .help(store.canEditCatalog ? "Bir yedek dosyasındaki veriyi geri yükler" : CloudPermission.catalogReadOnlyNote)
                        }
                        if let last = backups.first {
                            Text("Son otomatik yedek: \(last.lastPathComponent)").font(.caption).foregroundStyle(.secondary)
                        }
                        if !store.canEditCatalog {
                            ReadOnlyNote(text: "Yedekten geri yükleme stok kalemlerini, reçeteleri ve ayarları da değiştirdiği için patron veya müdür yetkisi gerekir. Yedek oluşturmak serbesttir.")
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
                                .disabled(!store.canEditCatalog)
                            if let m = restoreMessage { Text(m).foregroundStyle(.secondary) }
                        }
                        if !store.canEditCatalog { ReadOnlyNote() }
                    }
                }
            }
            .padding(24).frame(maxWidth: 860, alignment: .leading)
        }
        .navigationTitle("Ayarlar ve Veri")
    }
}

extension BackupView {
    /// Yüzde hedef satırı (veride 0–1 oranı, ekranda yüzde)
    func targetRow(_ title: String, _ term: Term, _ kp: WritableKeyPath<AppSettings, Double?>, hint: String) -> GridRow<some View> {
        GridRow {
            HStack(spacing: 4) { Text(title).foregroundStyle(.secondary); InfoTip(term: term) }
            HStack {
                Text("%")
                OptionalDecimalField(value: Binding(get: { store.settings[keyPath: kp].map { $0 * 100 } },
                                                    set: { v in store.updateSettings("Hedef") { $0[keyPath: kp] = v.map { $0 / 100 } } }),
                                     placeholder: hint, maxFraction: 1, width: 90)
            }
        }
    }
}

struct HelpView: View {
    @State private var termFilter = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("\(Brand.appName) — Nasıl Kullanılır?").font(.title2.weight(.semibold))
                Text("Uygulama, Excel'deki envanter dosyanızın (Envanter, KOD, Alımlar, Özet sayfaları ve makroları) yaptığı işi otomatik yapar; üstüne maliyet, kayıp, personel, sipariş ve menü analizleri ekler. Terimlerin yanındaki ⓘ işaretinin üzerine gelince ya da tıklayınca açıklaması görünür; tüm terimler en altta sözlükte.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                section("Başlarken")
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Self.gettingStarted, id: \.text) { t in tip(t.icon, t.text) }
                    }
                }

                section("Günlük akış")
                step(1, "Sayımı girin", "Günlük Sayım ekranında her kalem için Gelen, Gelen/Giden Transfer ve gün sonu Kapanış sayımını yazın. Açılış önceki günün kapanışından kendiliğinden gelir. Enter veya ↓ alt satıra, ↑ üst satıra, Tab yana geçer; virgül de nokta da kabul edilir. Depoda kâğıtla saymak için Genel Bakış'tan sayım formu alabilirsiniz.")
                step(2, "ModPos satış raporunu aktarın", "Raporu (.xlsx) uygulama penceresine sürükleyip bırakın (hangi ekranda olursanız olun) ya da \"Dosyadan Aktar\"a (⌘O) tıklayın. Kodu / Ürün Tipi / Adedi (varsa Tutar) sütunlarını kopyalayıp \"Panodan Yapıştır\" (⌘⇧V) da diyebilirsiniz. Tutar sütunu varsa maliyet oranları ve menü analizi hesaplanır.")
                step(3, "Farkları kontrol edin", "Kırmızı: satışlara göre fazla stok çıkmış (kayıp). Mavi: az çıkmış (sayım/reçete hatası olabilir). Yeşil: fark yok ya da tolerans içinde. \"Sorunlu\" filtresi yalnızca dikkat gerektiren kalemleri gösterir; satırdaki ⓘ hesabın dökümünü açar.")
                step(4, "Vardiyaları girin", "Personel ekranında saatlik çalışanların saatini, yevmiyelilerin \"çalıştı\" işaretini (saat girilirse de çalıştı sayılır), varsa fazla mesai/prim tutarını girin. \"Vardiyaları Doldur\" boş vardiyalara varsayılanları yazar. Aylık maaşlar ayrıca girilmeden günlere dağıtılır. Zam yapınca ücrete tıklayıp \"bir tarihten itibaren\" seçin: önceki günler eski ücretle kalır.")
                step(5, "Günü kapatın", "Sayım bitince \"Günü Kapat\" (⌘L) ile kilitleyin; hiç sayım girilmemiş gün kapatılamaz (düğmenin yanında yazar). Kilitli günün sayımı, satışı ve vardiyası değiştirilemez; gerekirse kilit açılır. Web paneline personel hesabıyla bağlı Mac'te kapatılmış günün kilidini yalnızca patron veya müdür açabilir (web paneli de kabul etmez); bu yüzden kapatmadan önce günün sayım durumu (ör. \"14 / 21 kalem sayıldı, 7 kalem sayılmadı\") ve satış raporunun aktarılıp aktarılmadığı gösterilip onay istenir. Güne not ve sayımı yapan kişiyi \"Not / Sayan\" düğmesinden ekleyebilirsiniz.")

                section("Haftalık / aylık")
                step(6, "Sipariş verin ve teslim alın", "Sipariş Önerisi son günlerin ortalama tüketimine ve kritik seviyeye göre miktar önerir; teslim alınmamış siparişlerdeki miktarlar öneriden düşülür (\"Siparişte\" sütunu), böylece aynı mal iki kez sipariş edilmez. \"Sipariş Oluştur\" ile kaydedin, \"Listeyi Kopyala\" ile tedarikçiye gönderin. Mal gelince, teslimatın geldiği güne geçip siparişte \"Teslim al\" deyin: gelen miktarlar o günün Gelen sütununa işlenir, fatura birim fiyatı (1 adet/kg fiyatı) girerseniz birim maliyet güncellenir. Sipariş oluşturma ve teslim alma patron / müdür işidir: web paneline personel hesabıyla bağlı Mac'te bu düğmeler kapalıdır, teslimatı patron ya da müdür işler.")
                step(7, "Raporları okuyun", "Genel Bakış ayın hammadde, personel ve prime cost oranlarını hedeflerle; Özet dönem toplamlarını; İstatistikler maliyet eğilimini, en çok kayıp veren kalemleri, zayi dağılımını, kalem grafiklerini, ABC analizini ve menü mühendisliğini gösterir. Her şey Excel'e aktarılabilir.")
                step(8, "Tanımları güncel tutun", "Stok Kalemleri'nde birim maliyet, kritik seviye ve toleransı; Reçeteler'de ürünlerin hammadde miktarlarını güncel tutun. Maliyet değişiklikleri tarihli olarak fiyat geçmişine yazılır: geçmiş günler o günkü fiyatla değerlenir, kapanmış ayların oranları sonradan değişmez. Artışlar Genel Bakış'ta uyarılır.")

                section("Notlar ve ipuçları")
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        tip("clock", "Sayımı her gün aynı saatte (kapanıştan sonra) yapın. Açılış devri ve fark hesabı, günler arasındaki sayımların tutarlı olmasına dayanır.")
                        tip("slider.horizontal.3", "Toleransı kalemin kendi biriminde (adet/kg) girin, yüzde değil: başlangıç için günlük tüketimin %1–2'si kadar bir miktar verin (ör. günde 30 kg patates → 0,3–0,6 kg; günde 200 adet 90 gr → 2–4 adet). Birkaç hafta sonra İstatistikler > Kalem Analizi'ndeki \"Tutarlılık\"a bakarak ayarlayın. Çok dar tolerans gereksiz alarm, çok geniş tolerans gözden kaçan kayıp demektir.")
                        tip("arrow.triangle.2.circlepath", "Sayım ertesi sabah yapılıyorsa satış raporunu yine satışın olduğu güne aktarın; içe aktarma ekranı rapor tarihini gösterir.")
                        tip("exclamationmark.triangle", "Aynı kalemde her gün aynı yönde fark çıkıyorsa sorun genelde reçetededir (porsiyon, katsayı); farklar rastgele dağılıyorsa sayım hatası olasıdır.")
                        tip("equal.circle", "\"Hareketsizleri Doldur\"u yalnızca o gün gerçekten hiç kullanılmayan kalemlerde kullanın; kapanışa açılışı yazar.")
                        tip("turkishlirasign.circle", "Birim maliyetleri faturadan güncel tutun; teslim almada fatura fiyatını girmek en kolay yoldur. Maliyeti olmayan kalemler ₺ hesaplarına katılmaz.")
                        tip("person.2", "Personel oranı satış tutarı bilinen günlerden hesaplanır; kaydı hiç olmayan kapalı günlerin maaşı da eklenir. Aylık maaşlar ayın her gününe eşit dağıtıldığından ay ortasında oran, ay sonundakine göre dalgalanabilir. Personel eklerken işe giriş tarihini doğru verin: önceki günlere maaş yazılmaz.")
                        tip("percent", "ModPos tutarları genelde KDV dahildir; sektördeki %25–35 hammadde hedefleri ise KDV hariç satışa göredir. Hedefinizi buna göre belirleyin.")
                        tip("target", "Hedefleri (hammadde %, personel %, prime cost %) Ayarlar'dan girin; kartlardaki çubukta dikey çizgi hedefi gösterir, aşılınca kırmızıya döner.")
                        tip("arrow.uturn.backward", "Yanlış bir işlemi Düzen > Geri Al (⌘Z) ile geri alın. Veriler otomatik kaydedilir, her gün yedek alınır (Ayarlar ve Veri).")
                        tip("arrow.triangle.2.circlepath.icloud", Self.webPanelTip)
                        tip("doc.on.doc", "Excel'e aktarım eski \"Alımlar\" düzenindedir; mevcut pivot tablolarınız çalışmaya devam eder. Ek sayfalar: Özet, Günlük Maliyet, Personel, Notlar.")
                    }
                }

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
                            Text("⌘1…⌘9  Ekranlar arasında geçiş     ⌘,  Ayarlar     ⌘Z / ⇧⌘Z  Geri al / Yinele")
                        }.font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                }

                section("Terimler sözlüğü")
                TextField("Terim ara", text: $termFilter).textFieldStyle(.roundedBorder).frame(width: 260)
                let q = termFilter.trimmingCharacters(in: .whitespaces).lowercased(with: Locale(identifier: "tr_TR"))
                Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Term.allCases.filter { q.isEmpty || $0.title.lowercased(with: Locale(identifier: "tr_TR")).contains(q)
                                                    || $0.text.lowercased(with: Locale(identifier: "tr_TR")).contains(q) }) { t in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(t.title).font(.callout.weight(.semibold))
                                Text(t.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }
            .padding(24).frame(maxWidth: 880, alignment: .leading)
        }
        .navigationTitle("Nasıl Kullanılır?")
    }

    /// "Başlarken": dört başlangıç yolu (Genel Bakış'taki başlangıç kartıyla aynı sıra)
    static let gettingStarted: [(icon: String, text: String)] = [
        ("arrow.triangle.2.circlepath.icloud",
         "Web paneline bağlanın: şubenin verisi web panelindeyse en kolay yol budur. Ayarlar ve Veri → Web paneli ile eşitleme kartında web paneli e-postanız ve şifrenizle \"Bağlan\"a basın; veriler kendiliğinden gelir. " + CloudSyncGuide.accountHelp),
        ("arrow.counterclockwise",
         "Yedekten geri yükleyin: başka bir Mac'te Ayarlar ve Veri → Yedek Oluştur… ile alınan .json dosyasını Ayarlar ve Veri → Yedekten Geri Yükle… ile yükleyin. Eski Excel envanter dosyanızdaki (.xlsm) geçmiş günleri \"Excel Envanter Dosyası Seç ve Aktar…\" ile aktarabilirsiniz."),
        ("shippingbox",
         "Tanımları hazırlayın: hazır reçeteler ve stok kalemleri uygulamayla gelir. Stok Kalemleri'nde birim maliyet, kritik seviye ve toleransı girin; Reçeteler'de ürünlerin hammadde miktarlarını kontrol edin."),
        ("doc.badge.plus",
         "İlk günü girin: ModPos satış raporunu aktarın, Günlük Sayım'da kapanış sayımını yazın. Genel Bakış'taki başlangıç kartı ilk günlük kayıt girilince kendiliğinden kaybolur."),
    ]

    /// Web paneli ipucu (hesap ve şifre yolları web panelindeki adlarla aynı)
    static let webPanelTip: String = [
        "Web paneli: Ayarlar ve Veri → Web paneli ile eşitleme kartından web paneli hesabınızla bağlanın.",
        CloudSyncGuide.accountHelp,
        CloudSyncGuide.forgotPassword,
        "Bağlıyken kart hesabı, rolü, şubeyi, son eşitleme saatini ve bekleyen değişiklikleri gösterir; sorun olursa ne olduğunu ve ne yapılacağını yazar. \"Bağlantı yok\": değişiklikler bu Mac'te saklanır, bağlantı gelince kendiliğinden gönderilir. \"Kurulum eksik\": web panelinin veritabanı henüz kurulmamış; patron kurulum talimatındaki veritabanı dosyasını Supabase SQL Editor'de bir kez çalıştırmalıdır. \"Giriş gerekli\": şifre değişti ya da oturumun süresi doldu; yeniden giriş yapın, bekleyen değişiklikler korunur.",
        "Sayım, satış ve vardiyalar birkaç saniye içinde patron ve müdürlerin web paneline gider; web panelinde yapılan düzeltmeler (sayım, maliyet, sipariş, hedef) en geç bir dakika içinde buraya gelir. Aynı güne iki yerden farklı kalemler girilirse ikisi de korunur; aynı alan iki yerde değiştirilirse son kaydedilen geçerli olur.",
        "Personel hesabıyla yalnızca günlük kayıtlar değiştirilebilir: stok kalemleri, reçeteler, personel, siparişler ve ayarlar salt okunurdur, kapatılmış günün kilidini yalnızca patron veya müdür açar. Çıkış yapınca şube eşleşmesi korunur; yeniden giriş yaptığınızda kaldığınız yerden devam edilir. Boş bir şubeye geçerken bu şubenin günleri kendiliğinden yüklenmez, ne kopyalanacağı sorulur. Tutar alanlarında (birim maliyet, fatura fiyatı, ücret) \"35.000\" otuz beş bin okunur.",
    ].joined(separator: " ")

    private func section(_ title: String) -> some View {
        // Türkçe büyük harf: "NOTLAR VE İPUÇLARI", "TERİMLER SÖZLÜĞÜ"
        Text(Fmt.upper(title))
            .font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
            .padding(.top, 6)
    }

    private func step(_ n: Int, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)").font(.headline).foregroundStyle(Brand.accent)
                .frame(width: 28, height: 28).background(Circle().fill(Brand.accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Brand.accent).frame(width: 20)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
