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
                Text("Ayarlar").font(.title2.weight(.semibold))

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("İşletme", systemImage: "building.2").font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                            GridRow {
                                Text("Şube / işletme adı").foregroundStyle(.secondary)
                                CommitTextField(title: "ör. Kadıköy Şubesi", value: store.settingsBinding(\.branchName))
                                    .frame(width: 320)
                                    .disabled(!store.canEditCatalog)
                            }
                            // Eski hızlı seçim listesinin yerine: Sayan listesi Ekip'teki aktif üyelerden gelir
                            GridRow {
                                Text("Sayım yapanlar").foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    Text("Sayımı yapanlar Ekip ekranından yönetilir.")
                                    Button("Ekibe git") { store.section = .team }.buttonStyle(.link)
                                }
                            }
                        }
                        Text("Şube adı yan menüde, dışa aktarılan dosya adlarında ve sipariş listesinde görünür. Her şubede ayrı bir Mac kullanılıyorsa farklı ad verin.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if !store.canEditCatalog { ReadOnlyNote() }
                    }
                }

                CloudSyncCard(cloud: store.cloud, openUsers: { store.section = .team })

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
                        Text("Tüm günlerin envanteri eski \"Alımlar\" sayfasıyla aynı sütun düzeninde (Tarih, Ürün, Açılış, Gelen, … Fark) dışa aktarılır, eski pivot tablolar çalışmaya devam eder; ayrıca Özet, Günlük Durum ve (varsa) Notlar, Zayi Kayıtları ile Ekip sayfaları eklenir. Günün Excel'i sayım ekranının adlarını kullanır (Devreden, Giren, Şubeden Gelen, Çıkan, Kalan, Satılan, Zayi, Olması Gereken, Fark). Sayım şablonu seçili günün kalemlerini (Kalem, Kod, Birim, Devreden, Giren, Çıkan, Zayi, Kalan) listeler: depoda doldurulup Excel'den Sayım Yükle ile geri yüklenir; yüklemeden önce önizleme gösterilir.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button {
                                let d = store.engine.datesWithData
                                store.exportHistoryExcel(from: d.first ?? DateKey.today(), to: d.last ?? DateKey.today())
                            } label: { Label("Tüm Geçmişi Excel'e Aktar…", systemImage: "tablecells") }
                                .buttonStyle(SoftButtonStyle()).disabled(days == 0)
                            Button { store.exportCountSheet() } label: { Label("Sayım Şablonu (\(DateKey.short(store.selectedDate)))…", systemImage: "tablecells") }
                                .buttonStyle(SoftButtonStyle())
                            Button {
                                store.section = .daily
                                store.pickCountImport()
                            } label: { Label(CountImportText.uploadCommand, systemImage: "square.and.arrow.down") }
                                .buttonStyle(SoftButtonStyle())
                        }
                        Divider()
                        Text("Eski Excel envanter dosyanızdaki (ör. 01.08.xlsm) geçmiş günlük kayıtları (Alımlar sayfası ve pivot önbelleği), Envanter sayfasındaki güncel sayımı ve yapıştırılmış ModPos satışlarını aktarır; yalnızca miktarlar alınır. Veri girilmiş günlerin üzerine yazmaz (isterseniz seçebilirsiniz).")
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
        .navigationTitle("Ayarlar")
    }
}

struct HelpView: View {
    @State private var termFilter = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("\(Brand.appName) — Yardım").font(.title2.weight(.semibold))
                Text("Uygulama, Excel'deki envanter dosyanızın (Envanter, KOD, Alımlar, Özet sayfaları ve makroları) yaptığı işi otomatik yapar; üstüne fark takibi, sipariş, ekip ve web paneliyle canlı eşitleme ekler. Terimlerin yanındaki ⓘ işaretinin üzerine gelince ya da tıklayınca açıklaması görünür; tüm terimler en altta sözlükte.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                section("Başlarken")
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Self.gettingStarted, id: \.text) { t in tip(t.icon, t.text) }
                    }
                }

                section("Günlük akış")
                step(1, "Sayımı girin", "Günlük Sayım ekranında gün sonunda her kalemin Kalan'ını sayıp yazın; teslim alınan malı Giren'e, başka şubeye ya da depoya gideni Çıkan'a yazın. Satılan satış raporundan reçeteyle hesaplanır; Zayi düğmesi o kalem seçili Zayi Ekle'yi açar (o kalemin elle girilen kayıtları orada listelenir). Devreden son sayımdan kendiliğinden gelir; arada sayılmayan günler varsa onların hareketleri eklenir (≈ tahmini). Elle düzeltmek (Devreden'i düzelt) ve başka şubeden geleni (Şubeden gelen) girmek için satırın dökümünü (ⓘ) açın; döküm hesabı düz yazıyla da gösterir: Devreden + Giren − Çıkan − Satılan − Zayi = Olması gereken. Kalan alanındaki soluk değer olması gerekendir; Fark \"Tamam\", \"0,126 kg eksik\" ya da \"3 adet fazla\" diye yazar. Bir kalemin ilk sayımında (ya da son sayımı 31 günden eskiyse) fark hesaplanmaz: o sayım başlangıç kabul edilir (İlk sayım). Enter veya ↓ alt satıra, ↑ üst satıra, Tab yana geçer; virgül de nokta da kabul edilir. Stok birkaç yerdeyse toplayarak yazın: 12+8+5 ya da kolide 3x24+7 (adet kalemde 1.200 = 1200). Kalemi bulmak için üstteki \"Kalem ara\" kutusunu (⌘F) kullanın; Enter ilk kalemin Kalan hücresine geçer. Depoda kâğıtla ya da Excel'de saymak için Günlük Sayım'daki Excel menüsünden \"Şablonu İndir\"i (Gün menüsü: Sayım Şablonu (Excel)…) kullanın; doldurduğunuz dosyayı \"Excel'den Yükle…\" ile seçin ya da pencereye sürükleyip bırakın. Önizleme kalem kalem eski → yeni değerleri, bilinmeyen kalemleri ve okunamayan hücreleri gösterir; Uygula hepsini tek adımda yazar (⌘Z ile geri alınır).")
                step(2, "ModPos satış raporunu aktarın", "Raporu (.xlsx) uygulama penceresine sürükleyip bırakın (hangi ekranda olursanız olun) ya da \"Dosyadan Aktar\"a (⌘O) tıklayın. Kodu / Ürün Tipi / Adedi sütunlarını kopyalayıp \"Panodan Yapıştır\" (⌘⇧V) da diyebilirsiniz. Tutar sütunu varsa yok sayılır; yalnızca adetler kullanılır.")
                step(3, "Farkları kontrol edin", "Kırmızı: satışlara göre fazla stok çıkmış (fazla çıkış). Mavi: az çıkmış (sayım/reçete hatası olabilir). Yeşil: fark yok ya da tolerans içinde. \"Sorunlu\" filtresi yalnızca dikkat gerektiren kalemleri gösterir; satırdaki ⓘ hesabın dökümünü açar.")
                step(4, "Ekibi tanımlayın", "Ekip ekranında çalışanları ad, görev (ör. Usta, Kasiyer) ve telefonla ekleyin; Günlük Sayım'daki \"Sayan\" listesi buradan gelir. İşten ayrılanı silmek yerine pasif yapın: geçmiş sayımlardaki adı korunur. Patron, web paneline bağlıyken aynı ekrandaki Kullanıcılar bölümünden giriş hesabı açar (kullanıcı adıyla, e-posta gerekmez), yetkisini ve şifresini değiştirir.")
                step(5, "Günü kapatın", "Sayım bitince \"Günü Kapat\" (⌘L) ile kilitleyin; hiç sayım girilmemiş gün kapatılamaz (düğmenin yanında yazar). Kilitli günün sayımı ve satışı değiştirilemez; gerekirse kilit açılır. Kapatmadan önce kontrol listesi gösterilir: sayılmayan kalem (ör. \"14 / 21 kalem sayıldı, 7 kalem sayılmadı\"), aktarılmayan satış raporu ve reçetesi tanımsız ürün; eksik varsa düğme \"Yine de Kapat\" olur, \"Sayılmayanları Göster\" eksik kalemleri açar. Web paneline personel hesabıyla bağlı Mac'te kapatılmış günün kilidini yalnızca patron veya müdür açabilir (web paneli de kabul etmez); bu yüzden personel her zaman onaylar. Genel Bakış'taki \"N sayılmış gün kapatılmadı\" son 60 günün kapatılmamış günlerini listeler; patron / müdür seçtiklerini topluca kapatır. Güne not ve sayımı yapan kişiyi \"Not / Sayan\" düğmesinden ekleyebilirsiniz.")

                section("Haftalık / aylık")
                step(6, "Sipariş verin ve teslim alın", "Sipariş ekranı son günlerin ortalama tüketimine ve kritik seviyeye göre miktar önerir; teslim alınmamış siparişlerdeki miktarlar öneriden düşülür (\"Siparişte\" sütunu), böylece aynı mal iki kez sipariş edilmez. \"Sipariş Oluştur\" önerilen miktarlarla bir form açar: miktarları değiştirin, kalem ekleyip çıkarın, tedarikçiye not yazın; açık sipariş \"Düzenle…\" ile değiştirilir. \"Listeyi Kopyala\" ile tedarikçiye gönderin. Mal gelince siparişte \"Teslim al\" deyin ve teslim gününü seçin: gelen miktarlar o günün Gelen sütununa işlenir. Teslimat Günlük Sayım'da Gelen olarak elle girildiyse \"Teslim alındı say\" siparişi Gelen'e eklemeden kapatır (Gelen iki kez sayılmaz). 3 günden uzun süredir bekleyen açık siparişler için uyarı çıkar: mal geldiyse teslim alın, gelmeyecekse iptal edin. Sipariş oluşturma ve teslim alma patron / müdür işidir: web paneline personel hesabıyla bağlı Mac'te bu düğmeler kapalıdır, teslimatı patron ya da müdür işler.")
                step(7, "Raporları okuyun", "Genel Bakış'taki Bugün kartı günün üç adımını sırayla gösterir: satış raporunu aktar, sayımı tamamla, günü kapat; diğer işlemler kartın altındaki menüdedir. Genel Bakış ayrıca seçili günün sayım ilerlemesini, sorunlu kalemleri, fazla çıkışları, kritik seviyenin altındaki stokları ve açık siparişleri; son 30 günün durum şeridini ve 14 günlük sorunlu kalem eğilimini gösterir. Raporlar > Dönem Özeti seçilen dönemde her kalemin ilk Devreden, Giren, Çıkan, son Kalan, satılan, zayi, gerçek kullanım, fark ve fazla çıkış miktarlarını; Raporlar > Kalem Analizi tek bir kalemin satış + zayi ile gerçek kullanımını, günlük farkını ve stok seviyesini grafikle gösterir. Dönem Excel'e aktarılabilir.")
                step(8, "Tanımları güncel tutun", "Stok Kalemleri'nde kritik seviye ve toleransı; Reçeteler'de ürünlerin hammadde miktarlarını güncel tutun. \"Eşik önerileri\" son 28 günün sayım farklarına ve tüketimine göre tolerans ve kritik seviye önerir; önerisi olmayan boş kalemleri adıyla yazar (değeri tabloya elle girin). Genel Bakış'taki kurulum listesi eksikleri gösterir (\"Gizle\" ile kaldırılan liste \"Diğer işlemler\"den geri açılır), sayım girilmemiş günde kritik seviye uyarısı tahmini stoğa (≈) göre verilir. Reçete değişikliği, satış raporu olan günlerin Satılan ve Fark değerlerini yeni reçeteye göre yeniden hesaplar.")

                section("Notlar ve ipuçları")
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        tip("clock", "Sayımı her gün aynı saatte (kapanıştan sonra) yapın. Devreden ve fark hesabı, günler arasındaki sayımların tutarlı olmasına dayanır.")
                        tip("slider.horizontal.3", "Toleransı kalemin kendi biriminde (adet/kg) girin, yüzde değil: başlangıç için günlük tüketimin %1–2'si kadar bir miktar verin (ör. günde 30 kg patates → 0,3–0,6 kg; günde 200 adet 90 gr → 2–4 adet). Birkaç hafta sonra Raporlar > Kalem Analizi'ndeki \"Tutarlılık\"a bakarak ayarlayın. Çok dar tolerans gereksiz alarm, çok geniş tolerans gözden kaçan fazla çıkış demektir.")
                        tip("arrow.triangle.2.circlepath", "Sayım ertesi sabah yapılıyorsa satış raporunu yine satışın olduğu güne aktarın; içe aktarma ekranı rapor tarihini gösterir.")
                        tip("exclamationmark.triangle", "Aynı kalemde her gün aynı yönde fark çıkıyorsa sorun genelde reçetededir (porsiyon, katsayı); farklar rastgele dağılıyorsa sayım hatası olasıdır.")
                        tip("equal.circle", "\"Hareketsizleri Doldur\"u yalnızca o gün gerçekten hiç kullanılmayan kalemlerde kullanın; Kalan'a Devreden'i yazar.")
                        tip("tablecells", "Sayım Excel'i: şablonda Kalem, Kod, Birim, Devreden, Giren, Çıkan, Zayi, Kalan (sayım) ve Not sütunları vardır. Yüklerken kalem önce Kod'la, sonra adla bulunur; boş hücre değiştirilmez, Devreden, Birim ve Not yüklenmez. Hücrelere 12+8 gibi toplayarak da yazılabilir. Zayi sütunu kalemin Excel zayi kaydını ayarlar (0 siler); Zayi Ekle ile girilen diğer kayıtlara dokunulmaz.")
                        tip("trash", WasteText.helpTip)
                        tip("person.2", "\"Not / Sayan\"daki listede aktif ekip üyeleri görünür. Listede olmayan bir ad yazarsanız kaydederken ekibe de eklenir (personel hesabıyla ad yalnızca o güne yazılır); görevini ve telefonunu sonra Ekip ekranında tamamlayın.")
                        tip("person.crop.circle", "Bağlantı koduyla bağlanan ortak mağaza bilgisayarında uygulama açılınca \"Şu an kim çalışıyor?\" diye sorar. Seçilen ad web panelindeki değişiklik geçmişine eklenir, Sayan ve zayi kaydında varsayılan olur; yan menüdeki adın üzerine tıklayıp değiştirin. Personel 7 günden eski bir güne giriş yaparsa bir kez uyarılır.")
                        tip("arrow.uturn.backward", "Yanlış bir işlemi Düzen > Geri Al (⌘Z) ile geri alın. Veriler otomatik kaydedilir, her gün yedek alınır (Ayarlar).")
                        tip("arrow.triangle.2.circlepath.icloud", Self.webPanelTip)
                        tip("doc.on.doc", "Dönem Excel'i eski \"Alımlar\" düzenindedir; mevcut pivot tablolarınız çalışmaya devam eder. Ek sayfalar: Özet, Günlük Durum ve (varsa) Notlar, Zayi Kayıtları ile Ekip. Günün Excel'i (⌘E) sayım ekranının adlarını kullanır; Olması Gereken = Devreden + Giren + Şubeden Gelen − Çıkan − Satılan − Zayi, Fark = Kalan − Olması Gereken.")
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
                            Text("⌘[  Önceki gün     ⌘]  Sonraki gün     ⌘T  Bugüne git     ⌘L  Günü kapat / aç     ⌘F  Kalem ara")
                            Text("⌘1…⌘8  Ekranlar arasında geçiş     ⌘,  Ayarlar     ⌘Z / ⇧⌘Z  Geri al / Yinele")
                        }.font(.callout.monospaced()).foregroundStyle(.secondary)
                        // Ekran kısayolları yan menüdeki sırayla (AppSection'dan; yeni ekran eklenince kendiliğinden güncellenir)
                        Text(Self.screenShortcuts)
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
        .navigationTitle("Yardım")
    }

    /// "⌘1 Genel Bakış · ⌘2 Günlük Sayım · … · ⌘8 Ekip": rakamlı ekran kısayolları (Git menüsüyle aynı)
    static var screenShortcuts: String {
        AppSection.allCases.compactMap { s -> String? in
            guard let key = s.shortcut, key.character.isNumber else { return nil }
            return "⌘\(key.character) \(s.title)"
        }.joined(separator: "  ·  ")
    }

    /// "Başlarken": üç başlangıç yolu (Genel Bakış'taki başlangıç kartıyla aynı sıra)
    static let gettingStarted: [(icon: String, text: String)] = [
        ("arrow.triangle.2.circlepath.icloud",
         "Web paneline bağlanın: şubenin verisi web panelindeyse en kolay yol budur. Yan menüdeki (ya da başlangıç kartındaki) Web'e Bağlan'a tıklayın, patronunuzun verdiği bağlantı kodunu yazın ya da WhatsApp'tan gelen mesajı \"Yapıştır\" ile yapıştırın ve \"Bağlan\"a basın; kullanıcı adı, şifre ya da şube sorulmaz. Veriler kendiliğinden gelir, sonra web panelindeki değişiklikler canlı bağlantıyla anında buraya yansır. " + CloudSyncGuide.pairCodeHelp + " Web paneli hesabınızla bağlanmak için aynı pencerede \"Kullanıcı adı ve şifreyle bağlan\"ı seçin."),
        ("arrow.counterclockwise",
         "Yedekten geri yükleyin: başka bir Mac'te Ayarlar → Yedek Oluştur… ile alınan .json dosyasını Ayarlar → Yedekten Geri Yükle… ile yükleyin. Eski Excel envanter dosyanızdaki (.xlsm) geçmiş günleri \"Excel Envanter Dosyası Seç ve Aktar…\" ile aktarabilirsiniz."),
        ("shippingbox",
         "Sıfırdan başlayın: hazır reçeteler ve stok kalemleri uygulamayla gelir. Stok Kalemleri'nde kritik seviye ve toleransı girin, Reçeteler'de ürünlerin hammadde miktarlarını kontrol edin, Ekip ekranında sayımı yapanları ekleyin. Sonra ModPos satış raporunu aktarıp Günlük Sayım'da gün sonunda sayılan Kalan'ı yazın. Genel Bakış'taki başlangıç kartı ilk kayıt (sayım, satış, ekip üyesi ya da sipariş) girilince kendiliğinden kaybolur."),
    ]

    /// Web paneli ipucu (hesap ve şifre yolları web panelindeki adlarla aynı)
    static let webPanelTip: String = [
        "Web paneli: yan menüdeki Web'e Bağlan'dan patronunuzun verdiği bağlantı koduyla (ya da \"Kullanıcı adı ve şifreyle bağlan\" ile web paneli hesabınızla) bağlanın; durum ve ayrıntılar Ayarlar → Web paneli ile eşitleme kartındadır.",
        CloudSyncGuide.pairCodeHelp,
        "Kod tek kullanımlıktır: bu Mac bağlanınca geçersiz olur ve Mac kendi şifresiyle bağlı kalır. Çıkış Yap'tan sonra \"Yeniden Bağlan\" yeni kod istemez; \"Bu Mac'i Şubeden Ayır\" ya da patronun bağlantıyı kaldırması sonrasında yeni kod gerekir. Bağlantı web panelinde \"Bu bilgisayardaki uygulamada aç\" ile gelirse uygulama kendiliğinden açılır ve kod dolu gelir.",
        CloudSyncCard.accountHelp,
        "Bağlıyken kart hesabı, rolü, şubeyi, son eşitleme saatini, canlı bağlantının durumunu ve bekleyen değişiklikleri gösterir; sorun olursa ne olduğunu ve ne yapılacağını yazar. \"Bağlantı yok\": değişiklikler bu Mac'te saklanır, bağlantı gelince kendiliğinden gönderilir. \"Kurulum eksik\": web panelinin veritabanı henüz kurulmamış; patron kurulum talimatındaki veritabanı dosyasını Supabase SQL Editor'de bir kez çalıştırmalıdır. \"Giriş gerekli\": şifre değişti ya da oturumun süresi doldu; yeniden giriş yapın, bekleyen değişiklikler korunur.",
        "Sayım, satış ve notlar birkaç saniye içinde patron ve müdürlerin web paneline gider; web panelinde yapılan değişiklikler (sayım, sipariş, ekip, stok kalemi, reçete) canlı bağlantıyla anında, bağlantı koparsa en geç bir dakika içinde buraya gelir. Aynı güne iki yerden farklı kalemler girilirse ikisi de korunur; aynı alan iki yerde değiştirilirse son kaydedilen geçerli olur.",
        "Personel hesabıyla yalnızca günlük kayıtlar değiştirilebilir: stok kalemleri, reçeteler, ekip, siparişler ve ayarlar salt okunurdur, kapatılmış günün kilidini yalnızca patron veya müdür açar. Patron, Ekip ekranındaki Kullanıcılar bölümünden (ya da web panelinden) kullanıcı adıyla hesap açar, yetki ve şifre belirler. Çıkış yapınca şube eşleşmesi korunur; yeniden giriş yaptığınızda kaldığınız yerden devam edilir. Boş bir şubeye geçerken bu şubenin günleri kendiliğinden yüklenmez, ne kopyalanacağı sorulur.",
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
                .frame(width: 28, height: 28).background(Shapes.control.fill(Brand.accent.opacity(0.12)))
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
