# NextGen Envanter

Restoranlar için **envanter yönetimi** uygulaması (macOS; Windows sürümü [`windows/`](windows/README.md)): stok kalemleri, reçeteler, satış raporu aktarımı, günlük sayım ve fark, sipariş ve ekip. Excel'deki envanter dosyasının (Envanter, KOD, Alımlar, Özet sayfaları ve makroları) yaptığı işi otomatik yapar: ModPos satış raporunu reçetelerle hammaddeye çevirir, günlük sayımla karşılaştırır ve farkı **miktar olarak** (adet / kg) gösterir. Şirket içi kullanım içindir (App Store'da yayınlanmaz).

Uygulama şubedeki bilgisayara kurulur; patron ve müdürler aynı veriyi **web panelinden** ([envantersite](https://github.com/RiosenBeq/envantersite)) her yerden, **anlık** izler. Para hesabı (birim maliyet, food cost, personel maliyeti, prime cost, hedefler) yoktur.

> Ekran görüntülerindeki rakamlar `EnvanterTool demo` ile üretilmiş **örnek verilerdir** ("Burger Yiyelim · Tuzla Marina" demo şubesi).

![Genel Bakış](docs/screenshots/01-overview.png)

## Özellikler

| Ekran | Ne işe yarar |
| --- | --- |
| **Genel Bakış** | İlk açılışta (henüz günlük kayıt yokken) **başlangıç kartı** üç yolla: **bağlantı koduyla web paneline bağlanma**, yedekten (ya da eski Excel dosyasından) geri yükleme, sıfırdan başlama (stok kalemleri, reçeteler, ilk satış raporu). **Bugün** kartı günün üç adımını sırayla gösterir (① satış raporunu aktar ② sayımı tamamla, ör. `14/21` ③ günü kapat), her adımın durumu ve tek düğmesiyle; diğer işlemler (panodan satış, sipariş önerisi, dönem raporu, ekip, sayım formu, günü Excel'e aktarma) tek bir **Diğer işlemler** menüsünde. Seçili günün sayım ilerlemesi, satış raporu durumu, tolerans dışı ve **fazla çıkış** olan kalemler, kritik seviyenin altındakiler (sayım girilmemiş günde **tahmini stoğa** göre: son sayım + sonraki hareketler) ve açık siparişler. Patron / müdür için tamamlanana kadar **kurulum listesi** (tolerans x/N · kritik seviye x/N · tanımsız reçete · web paneli bağlantısı). Son 30 günün **takip şeridi** (yeşil: sayım tam, fark az · sarı: eksik sayım ya da sayılanların %10'unda fark · kırmızı: sayılanların %20'sinde fark) ve son 14 günün sorunlu kalem grafiği; **kapatılmamış günler** listesi (son 60 günde sayılmış ama kapatılmamış günler, her biri kontrol listesiyle; patron / müdür seçtiklerini topluca kapatır, uyarısız günler önceden seçili). *Dikkat* listeleri: tolerans dışı farklar, kritik seviyenin altındaki stoklar (sayılmayanlar "tahmini" etiketiyle), açık siparişler ve reçetesi tanımsız satışlar. |
| **Günlük Sayım** | Sade tablo: **Ürün · Devreden · Giren · Çıkan · Satılan · Zayi · Kalan · Fark** (alt başlık: "Gün sonunda kalanı sayın; giren, çıkan ve zayiyi girin. Fark satış raporuna göre hesaplanır."). **Devreden** son sayımdan gelir (arada sayılmayan günler varsa onların hareketleri eklenir, `≈ 25` diye tahmini yazılır; elle girildiyse "elle" işareti). **Giren** teslim alınan mal, **Çıkan** başka şubeye ya da depoya giden (satış ve zayi hariç), **Satılan** satış raporundan reçeteyle, **Zayi** ModPos zayisi + elle girilen zayi. **Kalan** gün sonunda sayılan miktardır (asıl giriş; soluk değer *olması gereken*: Devreden + Giren + Şubeden gelen − Çıkan − Satılan − Zayi). **Fark** sözle yazar: tolerans içinde **Tamam** ✓, değilse "0,126 kg eksik" / "3 adet fazla", sayılmadıysa —, ilk sayımda *İlk sayım* (fark hesaplanmaz). Zayi düğmesi o kalem seçili **Zayi Ekle**'yi açar (kalem, miktar, neden, not, kim; o kalemin elle girilen kayıtları listelenir, gün açıkken silinir, ⌘Z ile geri alınır). Satırın **dökümü** (ⓘ) hesabı düz yazıyla gösterir ("Devreden 16,8 + Giren 0 − Çıkan 0 − Satılan 2,394 − Zayi 0 = Olması gereken 14,406 · Sayılan 14,28 → 0,126 kg eksik"); *Devreden'i düzelt* ve *Şubeden gelen* (başka şubeden gelen mal; eski kayıtlar da hesaba katılır, Giren'in altında "+N şubeden" yazar) buradan girilir. Beklenenden farklı girilen elle Devreden *Sorunlu* sayılır. Tolerans ve kritik seviyeye göre renkler, *Sayılmayan / Sorunlu* filtresi ve **kalem arama** (⌘F; Enter ilk kalemin Kalan'ına gider). Sayı hücrelerine **toplayarak giriş**: `12+8+5`, `3x24+7` ya da `3*24+7` yazılabilir, kaydedince ipucu "12+8+5 = 25" der. **Sayım Excel'i** (araç çubuğundaki *Excel* menüsü, Gün menüsü, Genel Bakış → Diğer işlemler): *Şablonu İndir* seçili günün kalemlerini indirir, doldurulan dosya *Excel'den Yükle…* ile (ya da pencereye sürüklenerek) önizlemeyle yüklenir (aşağıya bakın). Gün notu, sayımı yapan kişi (*Sayan*: ekipten seçilir), **günü kapatma kilidi** (sayım girilmemiş gün kapatılamaz; kapatmadan önce **kontrol listesi**: sayım tamam mı, satış raporu aktarıldı mı, tanımsız reçete var mı, bilgi olarak tolerans dışı fark; eksik varsa "Yine de Kapat" ve "Sayılmayanları Göster"), hareketsiz kalemleri tek tıkla doldurma (satış raporu aktarıldıktan sonra; tahmini Devreden'e yazmaz). |
| **Satış Dökümü** | ModPos satırlarını *reçeteli / stok etkisi yok / reçete tanımsız* olarak ayırır. Her satırın stoktan düşürdüğü miktarlar görünür; reçete tek tıkla tanımlanır. |
| **Sipariş** | Öneri = son 7/14/30 günün ortalama tüketimi × istenen gün + kritik seviye − mevcut stok − **siparişte bekleyen**. Mevcut stok, son sayıma sonraki günlerin gelen/transfer ve satışları eklenerek tahmin edilir (son sayım 31 günden eskiyse bilinmiyor sayılır). **Sipariş Oluştur** önerilen miktarlarla başlayan bir form açar (öneri yoksa boş): miktarlar değiştirilir, **Kalem ekle** (arama) ile kalem eklenir, çöp kutusuyla çıkarılır, tedarikçiye **not** yazılır (kopyalanan metnin sonuna eklenir). Açık sipariş **Düzenle…** ile aynı formda değiştirilir, iptal edilen **Yeniden Aç** ile açılır; iptal ve silme onay ister. Teslim alınınca miktarlar seçilen **teslim gününün** *Gelen* sütununa işlenir; o günde kalemin Gelen'i zaten varsa uyarı çıkar. Teslimat Günlük Sayım'da elle girildiyse **Gelen'e eklemeden teslim alındı say** (Gelen iki kez sayılmaz); siparişten sonra elle Gelen girilmişse sipariş satırında "Bu teslimat bu siparişten mi? **Teslim alındı say**" önerisi görünür. Açık siparişlerde bekleme süresi ("5 gündür bekliyor"); 3 günden eski açık siparişler için Sipariş ekranında ve Genel Bakış'ta uyarı (açık sipariş öneriden düşülmeye devam eder). Liste WhatsApp için kopyalanabilir veya Excel'e aktarılabilir. |
| **Raporlar** | *Dönem Özeti:* dönem toplamları (ilk Devreden, Giren, Çıkan, son Kalan, satılan, zayi, gerçek kullanım, fark, **fazla çıkış**) ve kalem bazında günlük fark grafiği (tolerans bandıyla). *Kalem Analizi:* satış + zayi ile gerçek kullanım, günlük fark ve stok seviyesi. |
| **Stok Kalemleri** | Birim, reçete birimi ve katsayı, **kritik seviye**, **tolerans (± adet/kg)**, bugünkü **tahmini stok**; arama, sıralama ve gizleme. Aynı adla ikinci kalem açılmaz. Sayım geçmişi, siparişi ya da reçetesi olan kalemi silerken önerilen işlem **Pasif Yap**tır; **Kalıcı Olarak Sil** kapatılmış günlere dokunmaz ve silinen kalemin kimliği yeniden kullanılmaz (aynı adla eklenen yeni kalem eski kayıtları devralmaz). Sayım geçmişi olan kalemin birimi değişirken sorulur: **Yeni Kalem Olarak Aç** (önerilen; eski kalem "Patates (adet)" adıyla pasif kalır, reçeteler yeni kaleme geçer, pencere katsayının yeni birime göre girilmesini hatırlatır; açık siparişteki kalemde sunulmaz) ya da **Yine de Değiştir**; katsayı değişikliği geçmiş günlerin Satılan ve Fark'ını değiştireceği için onay ister. **Eşik önerileri (N):** son 28 günün sayım farklarına (%80'lik dilim) ve tüketimine (× 1,5) göre tolerans ve kritik seviye önerir; boş alanlar seçili gelir, *Önerilenleri uygula* ile tek adımda (⌘Z ile geri alınır) yazılır. |
| **Reçeteler** | Hazır reçeteler; hammadde ekleme/çıkarma, başka üründen kopyalama. |
| **Ekip** | **Eleman ekleme**, düzenleme, pasif yapma ve silme (ad, görev, telefon, işe giriş/çıkış, not). Sayımı yapan kişi ekipten seçilir. Patron web paneline bağlıyken **Kullanıcılar** bölümünden **hesap oluşturur** (e-posta ya da yalnızca kullanıcı adıyla, geçici şifreyle), yetki değiştirir, şifre belirler ve şubeden çıkarır; hesap bir ekip üyesine bağlanabilir. |
| **Ayarlar** | Şube adı, sipariş varsayılanları, **web paneli ile eşitleme** (bkz. aşağıda), otomatik kayıt ve yedekler, yedek dosyası, Excel'e aktarım, **sayım şablonu** ve Excel'den sayım yükleme ve eski Excel dosyasından içe aktarım. |
| **Yardım** | Başlarken, adım adım günlük iş akışı, notlar ve ipuçları, kısayollar ve aranabilir **terimler sözlüğü**. |

Yan menü sade tutulur: üstte günlük işler (Genel Bakış, Günlük Sayım, Satış Dökümü, Sipariş, Raporlar), **Tanımlar** başlığı altında Stok Kalemleri, Reçeteler ve Ekip; altta ayrı olarak Ayarlar ve Yardım. Web paneline bağlı değilken menünün altında **Web'e Bağlan** düğmesi, bağlıyken eşitleme durumu görünür (oturumun süresi dolduysa ikisi birlikte). Sıra web paneliyle aynıdır.

Diğer:
- **Terim açıklamaları:** Devreden, Kalan, olması gereken, tolerans, fazla çıkış gibi terimlerin yanındaki ⓘ işaretinin üzerine gelince kısa açıklama çıkar, tıklayınca ayrıntılı açıklama açılır.
- **Liquid Glass tasarım:** macOS 26'da Apple'ın yerel Liquid Glass yüzeyleri; macOS 14–15'te aynı yüzeyler buzlu cam malzemesiyle çizilir.
- **Geri al / Yinele** (⌘Z / ⇧⌘Z) tüm veri değişikliklerinde çalışır.
- **Gün dönümü:** Uygulama gece açık kalırsa ve "bugün" seçiliyse gece yarısından sonra (uygulama öne gelince, Mac uyanınca ya da dakikada bir) yeni güne geçilir; üstte "Yeni gün başladı: … · **Dünkü güne dön**" şeridi çıkar (kapatılana kadar kalır). Başka bir gün açıksa seçili gün değişmez; açık bir pencere varken ya da sayım sürerken (hücre odakta, son 15 dakikada klavye / fare kullanılmış) geçiş beklenir, hücrede yazılmış değer önceki güne kaydedilir.
- **Sürüm uyumu:** Uygulama canlı bağlantıda veri biçimi düzeyini (`fmt`, bu sürümde 2) bildirir; web paneli düzeyi düşük (eski sürüm) bir Mac'i "Mac eski sürüm" diye uyarır. Şubede bu Mac'ten yeni bir sürüm çalışıyorsa kenar çubuğunda **Yeni sürüm var: güncelleyin** görünür (docs/SYNC.md §2 "Sürüm uyumu").
- **Kayıt ve yedek:** Otomatik kayıt yapılır, kayıt durumu yan menüde görünür. Günlük yedekler son 30 günü kapsar ve riskli işlemlerden önce anlık kopya alınır. Dosya bozulursa en son yedekten otomatik dönülür; o da okunamazsa bozuk dosya kenara alınır, üzerine yazılmaz.
- **Satış raporu:** `.xlsx`, `.csv` ve `.txt` (UTF-8, UTF-16, Windows-1254) dosyaları ya da pano kabul edilir; dosya hangi ekranda olursa olsun pencereye sürüklenip bırakılabilir. Raporda *Tutar* sütunu varsa yok sayılır. Başlık satırı varsa (*Kodu*, *Adedi*) sütunlar ondan okunur: *Sıra*, *Birim Fiyat*, *KDV* gibi sütunlar adet ya da kod sanılmaz; "12 adet", "12,00 Ad." gibi birimli adetler ve 01-08-2026, 2026-08-01, 01.08.26 tarih yazımları tanınır. Adedi okunamayan satırlar önizlemede satır numarasıyla listelenir.
- **Aktarım uyarıları:** Önizleme aynı raporun yakın bir güne (±10 gün) zaten aktarıldığını, aynı dönemin raporunun başka güne aktarıldığını, toplam adedin son 14 günün ortancasının 3 katından fazla / %30'undan az olduğunu ve rapor tarihi ile seçili gün arasındaki farkı (1 gün: bilgi, daha fazla: uyarı) gösterir. Aynı rapor ya da okunamayan satırlar %20'yi aşarsa **Yine de bu güne aktar** onayı istenir; **O güne git** raporun aktarıldığı günü açar.
- **Excel'e aktarım:** Dönem kitabı eski *Alımlar* sayfasıyla aynı sütun düzenini ve başlıkları kullanır (pivot tablolar çalışmaya devam eder); ek olarak Özet ve Günlük Durum sayfaları, varsa Notlar, Zayi Kayıtları ve Ekip sayfaları yazılır. Günün Excel'i (*Envanter* + *Satışlar*) aynı sütun sırasıyla sayım ekranının adlarını kullanır: Tarih, Ürün, Devreden, Giren, Şubeden Gelen, Çıkan, Kalan, Satılan, Zayi, **Olması Gereken**, Fark (Fark = Kalan − Olması gereken).
- **Sayım Excel'i (şablon ve yükleme):** *Şablonu İndir* / *Sayım Şablonu (Excel)…* "Sayım Formu" sayfasını yazar: 1. satır "<şube> · Sayım gg.aa.yyyy", 2. satır **Kalem, Kod, Birim, Devreden, Giren, Çıkan, Zayi, Kalan (sayım), Not**, sonra aktif kalemler ekrandaki sırayla, o günün değerleriyle (Devreden hesaplanan değer; girilmemiş değerler boş; Zayi kalemin Excel zayi kaydı). Doldurulan dosya *Excel'den Yükle…* ile seçilir ya da Günlük Sayım'a sürüklenip bırakılır (`.xlsx`, ayrıca `.csv` / `.tsv`; ilk sayfa okunur). Başlık satırı ilk 15 satırda aranır (eski sayım formu ve "Ürün / Gelen / Kapanış / Fire / Sayım" gibi başlıklar da tanınır); kalem önce **Kod**'la, sonra adla (Türkçe harf ve büyük/küçük harf farkı gözetilmeden) bulunur. Boş, "-" ya da "—" hücre değiştirilmez; metin hücrelere toplayarak giriş kuralı uygulanır (`12+8`, adet kalemde `1.200` = 1200); Devreden, Birim ve Not yüklenmez. Önizleme kalem kalem eski → yeni değerleri (Giren, Çıkan, Zayi, Kalan), bilinmeyen kalemleri, okunamayan hücreleri ve yinelenen satırları sayılarıyla gösterir; **Uygula** hepsini seçili güne **tek geri alma adımında** yazar (kapatılmış günde reddedilir; personel de uygulayabilir). Zayi sütunu kalemin o günkü `excel-<kalem kimliği>` zayi kaydını ayarlar (neden *Diğer*, not "Excel'den yüklendi", kim: Zayi Ekle'deki varsayılan); 0 bu kaydı siler, elle girilen diğer kayıtlara dokunulmaz. Kurallar web paneliyle aynıdır (`Tests/EnvanterCoreTests/Fixtures/countimport-vectors.json`).

### Kısayollar

| Kısayol | İşlem |
| --- | --- |
| ⌘O / ⌘⇧V | Satış raporu aktar / panodan yapıştır |
| ⌘E | Günü Excel'e aktar |
| ⌘[ / ⌘] / ⌘T | Önceki gün / sonraki gün / bugün |
| ⌘L | Günü kapat / kilidi aç |
| ⌘F | Kalem ara (Günlük Sayım; Stok Kalemleri açıksa oradaki arama) |
| ⌘1 … ⌘8 | Genel Bakış, Günlük Sayım, Satış Dökümü, Sipariş, Raporlar, Stok Kalemleri, Reçeteler, Ekip |
| ⌘, | Ayarlar |
| ⌘Z / ⇧⌘Z | Geri al / yinele |

## Ekran görüntüleri

Görüntüler CI'da, uygulama `EnvanterTool demo` ile üretilen örnek veriyle çalıştırılarak otomatik alınır; *İlk açılış* görüntüsü boş bir veri klasörüyle alınır; *Web Paneline Bağlan* görüntüsü bağlanma penceresini örnek bir kodla gösterir.

| | |
| --- | --- |
| ![Günlük Sayım](docs/screenshots/02-daily.png) **Günlük Sayım** | ![Satış Dökümü](docs/screenshots/03-sales.png) **Satış Dökümü** |
| ![Sipariş](docs/screenshots/04-orders.png) **Sipariş** | ![Raporlar](docs/screenshots/05-reports-summary.png) **Raporlar · Dönem Özeti** |
| ![Kalem Analizi](docs/screenshots/06-reports-item-patates.png) **Raporlar · Kalem Analizi** | ![Stok Kalemleri](docs/screenshots/07-items.png) **Stok Kalemleri** |
| ![Reçeteler](docs/screenshots/08-recipes-11101.png) **Reçeteler** | ![Ekip](docs/screenshots/09-team.png) **Ekip** |
| ![Ayarlar](docs/screenshots/10-backup.png) **Ayarlar** | ![Yardım](docs/screenshots/11-help.png) **Yardım** |
| ![Web Paneline Bağlan](docs/screenshots/12-connect.png) **Web Paneline Bağlan (bağlantı kodu)** | ![İlk açılış](docs/screenshots/13-welcome.png) **İlk açılış (boş veri): başlangıç kartı** |

## Kurulum (şirket içi)

1. Bir Mac'te (macOS 14+, Xcode 15+ veya Swift 5.9+ araç zinciri) derleyin:
   ```bash
   ./Scripts/build_app.sh          # build/NextGen Envanter.app + build/NextGen-Envanter-2.1.zip
   ./Scripts/build_app.sh --dmg    # ayrıca .dmg
   ```
   Hazır paket, GitHub Actions'taki her başarılı çalışmanın **NextGen-Envanter** artifact'ında da bulunur.
2. `.zip`'i diğer Mac'lere kopyalayın, `NextGen Envanter.app`'i *Uygulamalar* klasörüne taşıyın.
3. Uygulama ad-hoc imzalıdır. İlk açılışta macOS uyarı verirse Finder'da uygulamaya sağ tıklayıp **Aç** deyin ya da:
   ```bash
   xattr -dr com.apple.quarantine "/Applications/NextGen Envanter.app"
   ```

Veriler `~/Library/Application Support/Envanter/` altında tutulur (`envanter-verisi.json` ve `Yedekler/`). Uygulamayı silmek veya güncellemek verilere dokunmaz. Başka bir klasör kullanmak için `ENVANTER_DATA_DIR` ortam değişkeni verilebilir.

**Eski sürümden geçiş:** Eski sürümlerin veri dosyası olduğu gibi açılır. Maliyet, fiyat geçmişi, ücret ve vardiya alanları artık kullanılmaz: bu Mac'teki dosyadan ilk kayıtta düşer (önceki hali `Yedekler/` altındaki günlük yedeklerde kalır), bulutta ise silinmez. Eski "sayım yapanlar" listesi kendiliğinden **Ekip**'e taşınır. Yeni sürümün aldığı yedek eski sürümde açılmayabilir.

### Windows

Mağaza bilgisayarı Windows ise [`windows/`](windows/README.md) klasöründeki **NextGen Envanter (Windows)** kurulur: web panelini kendi penceresinde açan, `envanter://` bağlantılarını tanıyan ve bağlantı koduyla tek adımda bağlanan masaüstü uygulaması (Electron). Kurulum dosyası (`NextGen-Envanter-Kurulum-<sürüm>.exe`) GitHub Actions'taki **Windows** iş akışının **NextGen-Envanter-Windows** artifact'ındadır. İmzasız olduğu için Windows "bilgisayarınız korundu" uyarısı verirse **Ek bilgi → Yine de çalıştır** deyin. Ayrıntılar: [windows/README.md](windows/README.md).

## Web paneli ve anlık eşitleme

Mac uygulaması, patron ve müdürlerin kullandığı **web paneliyle** ([envantersite](https://github.com/RiosenBeq/envantersite)) Supabase üzerinden **anlık** eşitlenir.

- **Kim ne kullanır:** Personel günlük işleri (sayım, satış raporu aktarımı, gün notu) bu uygulamada yapar. Patron ve müdürler web panelinden her yerden izler (pano, raporlar, uyarılar, şube karşılaştırması, kimin neyi değiştirdiği, **Mac'in şu an açık olup olmadığı**) ve gerektiğinde müdahale eder (sayım düzeltme, sipariş onayı ve teslim alma, stok kalemleri ve reçeteler, ekip, kullanıcılar ve yetkiler).
- **Web panelinde de aynı işler:** Windows mağaza bilgisayarı ve tarayıcı aynı sayım formunu (Excel ve yazdırılabilir A4), günün ve sipariş önerisinin Excel'ini alır (aynı sayfalar ve dosya adları); bildirimdeki **Geri al** ve Ctrl+Z Mac'teki birleştirme kuralıyla geri alır (sonradan bu Mac'ten gelen değişiklik korunur); yeni şube başka şubenin tanımlarıyla ya da hazır reçetelerle açılabilir, **Eksik varsayılanları geri ekle** web'de de vardır (docs/SYNC.md).
- **Anlık:** Mac'te yapılan değişiklik 2 sn içinde gönderilir; web panelinde yapılan değişiklik Mac'e Supabase Realtime ile hemen gelir (bağlantı kurulamazsa 60 sn'de bir eşitlenir). Web panelinde "Mac çevrimiçi" göstergesi Mac açıkken yanar.
- **Bağlanma (bağlantı kodu):** Patron web panelinde *Yönetim → Kullanıcılar → **Bilgisayar Bağla*** ile bir kod üretir (ör. `7KQ2-M9XP-4TRA-HW3D`) ve WhatsApp ile gönderir ya da kopyalar. Mac'te yan menüdeki (ya da başlangıç kartındaki, uygulama menüsündeki) **Web'e Bağlan** → kodu yazın ya da mesajı **Yapıştır** ile yapıştırın → **Bağlan**; *Ayarlar > Web paneli ile eşitleme* kartında kod alanı doğrudan görünür. Kullanıcı adı, şifre, şube ya da sunucu ayarı sorulmaz: kod, bu bilgisayara ayrılmış bir cihaz hesabının (`pc-xxxxxx`) giriş bilgisidir ve rolünü (müdür ya da personel) patron kodu üretirken seçer.
  - Web panelindeki **Bu bilgisayardaki uygulamada aç** bağlantısı (`envanter://baglan?kod=…&sunucu=…&anahtar=…`) uygulamayı öne getirir ve bağlanma penceresini kod (ve sunucu ayarı) dolu açar; bu Mac henüz bir şubeyle eşleşmemişse ve bağlantının sunucusu varsayılan (ya da bu Mac'te kayıtlı) sunucuysa hemen bağlanır. Başka bir sunucuyu gösteren bağlantıda uyarı çıkar ve **Bağlan**'a basılması beklenir; eşleşmiş Mac'te de **Bağlan** beklenir (şube değişimi kuralları geçerlidir, başka sunucuya geçilirken eşleşmenin bırakılacağı söylenir). Bu Mac zaten aynı kodla bağlıysa eşitleme kartı açılır.
  - **Kod tek kullanımlıktır:** Mac kodla girdikten hemen sonra cihaz hesabına kendi ürettiği rastgele bir şifre verir; kod bir daha geçmez. Bu şifre gösterilmez, günlüğe yazılmaz ve oturum anahtarlarıyla aynı dosyada (`esitleme.json`, 0600) durur. Oturumun süresi dolarsa Mac bu şifreyle sessizce yeniden girer. *Çıkış Yap*'tan (ya da ilk bağlantı kararından / şube seçiminden vazgeçtikten) sonra **Yeniden Bağlan** yeni kod istemez; kullanılmış kod yeniden yazılırsa da bu Mac kayıtlı şifresiyle girer. *Çıkış Yap ve Bu Mac'i Şubeden Ayır* ya da patronun web panelinde **Bağlantıyı kaldır** demesi sonrasında yeni kod gerekir. Şifre değiştirme isteği başarısız olursa (ya da durum diske yazılamazsa) kod geçerli kalır ve Mac bağlıyken birkaç dakikada bir yeniden dener. Oturum geçici bir sunucu ya da bağlantı hatasıyla açılamazsa asıl hata gösterilir ve beklemeyle yeniden denenir. Yanlış ya da kullanılmış kodda: "Kod geçersiz ya da daha önce kullanılmış. Patronunuzdan yeni bir kod isteyin."
  - Web panelinin *Yönetim → Kullanıcılar* ekranı, Mac açıkken bu bilgisayarı *Çevrimiçi* gösterir (çevrimiçi bilgisinde yalnızca cihaz adı `pc-xxxxxx` gider). Mac'teki *Ekip → Kullanıcılar* bölümünde cihaz hesabı "Bağlantı koduyla bağlanan bilgisayar" olarak görünür; ekip üyesine bağlanmaz, şifresi belirlenmez.
- **Bağlanma (kullanıcı adı ve şifre):** Aynı pencerede **Kullanıcı adı ve şifreyle bağlan** ile web paneli hesabının **e-postası ya da kullanıcı adı** ve şifresiyle de bağlanılır. Hesabı patron *Ekip > Kullanıcılar* bölümünde (Mac) ya da web panelinde *Yönetim → Kullanıcılar* ekranında **Hesap oluştur** ile açar: e-posta gerekmez, kullanıcı adı yeter (ör. "Ayşe Yılmaz" → giriş adı `ayse.yilmaz`). Şifre unutulursa aynı yerde **Şifre belirle** ile yeni geçici şifre verilir. Sunucu adresi ve publishable key uygulamada hazırdır (publishable key herkese açık bir anahtardır; yetkiyi veritabanındaki RLS kuralları uygular). Farklı bir Supabase projesi için bu formdaki *Gelişmiş* bölümünden değiştirilebilir.
  - Hesap birden çok şubeye üyeyse şube seçilir. Hiç şube yoksa (ilk kurulum) işletme adıyla yeni bir şube açılır ve hesap patron olur. Şubeye eklenmemiş bir hesapla bağlanılırsa patronun eklemesi gerektiği söylenir.
  - **İlk bağlantı:** Bulut boşsa bu Mac'teki her şey yüklenir. Bu Mac yalnızca varsayılan reçetelerle duruyorsa buluttaki veri indirilir. İki tarafta da veri varsa sorulur: *Buluttakini İndir* (bu Mac'teki veri önce `Yedekler/bulut-indirme-oncesi-….json` olarak saklanır) ya da *Bu Mac'tekini Yükle* (buluttaki önceki hal `Yedekler/bulut-yukleme-oncesi-….json` olarak saklanır).
  - **Şube değiştirme:** *Şube Değiştir…* ile başka şube seçilir. Şube boşsa sorulur: *Yalnızca Tanımları Kopyala* ya da *Her Şeyi Kopyala*.
- **Roller:** *Patron* her şeyi yönetir (kullanıcılar, yetkiler, şube adı dahil), *Müdür* tüm verileri değiştirir, *Personel* yalnızca günlük kayıtları (sayım, satış, not) değiştirir ve günü kapatabilir. Personel hesabıyla bağlı Mac'te stok kalemleri, reçeteler, ekip, siparişler ve ayarlar salt okunurdur; personel 7 günden eski bir güne yazınca uygulama açık kaldıkça bir kez uyarılır (yanlış güne giriş olmasın). Rol web panelinde değiştirilirse Mac çıkış yapmadan güncellenir.
- **Kapatılmış gün:** Kapatılmış (kilitli) günü yalnızca patron ve müdür değiştirebilir, kilidini açabilir ya da silebilir; sunucu da personelin bu yazmalarını reddeder.
- **Çakışmalar:** Veri belgelere bölünür (stok kalemleri, reçeteler, ayarlar, ekip, siparişler ve her gün ayrı bir belge). Aynı belge iki yerde değiştirilirse alan bazında birleştirilir: aynı güne farklı kalemlerin sayımı girilirse ikisi de korunur; aynı alan iki yerde değiştirilirse son gönderilen geçerli olur. Mac'in bilmediği alanlar (eski sürümlerin maliyet ve vardiya alanları dahil) kaybolmaz.
- **Değişiklik geçmişi:** Her gönderim web panelindeki geçmişe kısa bir özetle yazılır, ör. "09.10.2026 sayımı: 90 Gr kapanış 120 → 110", "09.10.2026 satış raporu aktarıldı (121 satır)", "Ekip: Ayşe eklendi".
- **Paylaşılan bilgisayarda kim çalışıyor:** Bağlantı koduyla bağlanan Mac (cihaz hesabı) açılınca bir kez "Şu an kim çalışıyor?" diye sorar (aktif ekip üyeleri; *Atla* ile geçilebilir, yan menüdeki addan değiştirilir; değiştirirken *Vazgeç* seçili adı korur). Seçilen ad yalnızca bu Mac'te, uygulama açık kaldıkça ve o cihaz hesabıyla bağlıyken kullanılır (çıkış yapılıp kişisel hesapla girilince kullanılmaz): değişiklik geçmişi özetine eklenir ("… → 110 · Murat A."), günün *Sayan*'ı boşsa ilk kapanışta yazılır ve *Zayi Ekle*'de "Kim" varsayılanı olur.
- **Geri al:** ⌘Z yalnızca kendi yaptığınız değişikliğin alanlarını geri alır; arada web panelinden gelen değişiklikler korunur.
- **Oturum ve gizlilik:** Kişi hesaplarının şifresi saklanmaz (bağlantı koduyla bağlanan Mac'in cihaz hesabı şifresi, Mac'in kendi ürettiği rastgele şifredir; yukarıya bakın). Oturum anahtarları ve eşitleme durumu veri klasöründeki `esitleme.json` dosyasında yalnızca kullanıcının okuyabileceği izinle (0600) tutulur; yedeklere girmez. *Çıkış Yap* eşitlemeyi durdurur, bu Mac'teki veriyi silmez ve şube eşleşmesini korur. *Çıkış Yap ve Bu Mac'i Şubeden Ayır* eşleşmeyi de siler.
- Otomatik test (`ENVANTER_SELFTEST`) ve ekran görüntüsü (`ENVANTER_SNAPSHOT_DIR`) modlarında eşitleme kapalıdır.

İki istemcinin uyduğu sözleşme (tablolar, roller, RPC'ler, eşitleme algoritması, merge3, anlık bağlantı, kullanıcı adı) [docs/SYNC.md](docs/SYNC.md) dosyasındadır. Eşitleme kodu `Sources/EnvanterCore` altında platformdan bağımsızdır (`CloudSync.swift`, `CloudSyncEngine.swift`, `SupabaseAPI.swift`, `CloudMembersAPI.swift`, `Realtime.swift`, `Accounts.swift`, `PairCode.swift`, `DeviceLogin.swift`, `Team.swift`, `JSONValue.swift`, `ChangeSummary.swift`); uygulama tarafı `CloudSyncController.swift`, `CloudSyncView.swift`, `ConnectView.swift` ve `TeamView.swift`'tir. Bağlantı kodunun ortak test vektörleri `Tests/EnvanterCoreTests/Fixtures/pair-vectors.json` dosyasındadır (web deposundakiyle birebir aynı). Açılış devri, ilk sayım, tahmini stok ve "Hareketsizleri Doldur" kuralları `carry-vectors.json`, eşik önerileri ve kurulum listesi `threshold-vectors.json`, elle zayi (okuma, hesap, metinler, değişiklik özetleri) `waste-vectors.json`, gün kapatma kontrol listesi, kapatılmamış günler ve eski gün uyarısı `dayclose-vectors.json`, toplayarak giriş ve kalem arama `count-vectors.json`, sayım Excel'inin yükleme kuralları `countimport-vectors.json`, dışa aktarılan Excel sayfalarının adları, başlıkları ve sütun genişlikleri `export-vectors.json`, paylaşılan bilgisayarda çalışan `worker-vectors.json` ile iki istemcide aynı tutulur.

```bash
swift test --filter CloudSyncTests    # merge3 vektörleri, belge dönüşümü, bellek içi sunucuyla iki istemci, istekler ve oturum yenileme
swift test --filter RealtimeTests     # anlık bağlantı protokolü (sahte soketle)
swift test --filter PairCodeTests     # bağlantı kodu ve envanter:// bağlantısı (web ile ortak vektörler)
swift test --filter CarryVectorTests  # sayılmayan gün devri, ilk sayım, tahmini stok, Hareketsizleri Doldur (web ile ortak vektörler)
swift test --filter WasteVectorTests  # elle zayi: okuma, hesap, metinler, değişiklik özetleri (web ile ortak vektörler)
swift test --filter ThresholdVectorTests # eşik önerileri ve kurulum listesi (web ile ortak vektörler)
swift test --filter DayCloseTests     # gün kapatma kontrol listesi, kapatılmamış günler, eski gün uyarısı (web ile ortak vektörler)
swift test --filter CountEntryTests   # toplayarak giriş (12+8+5, 3x24+7) ve kalem arama (web ile ortak vektörler)
swift test --filter CountImportVectorTests # sayım Excel'i: yükleme kuralları (web ile ortak vektörler), şablon gidiş-dönüşü, sayım ekranı metinleri
swift test --filter WorkerTests       # paylaşılan bilgisayarda çalışan: özet, Sayan, Zayi "Kim" (web ile ortak vektörler)
swift test --filter DeviceLoginTests  # tek kullanımlık kod (şifre değiştirme), sessiz yeniden giriş, durum dosyası
# Gerçek Supabase bileşenleriyle (envantersite/scripts/local-supabase ortamı çalışırken):
ENVANTER_SUPABASE_TEST_URL=http://127.0.0.1:54321 swift test --filter IntegrationTests
```

## Komut satırı aracı

Paketin içinde `Contents/MacOS/EnvanterTool` olarak gelir (uygulama kapalıyken kullanın):

```bash
EnvanterTool status                                      # veri özeti
EnvanterTool import-excel 01.08.xlsm [--overwrite] [--dry-run]
EnvanterTool export-excel rapor.xlsx [--from 01.08.2026] [--to 31.08.2026]
EnvanterTool orders [--date 09.10.2026] [--days 14] [--cover 3]   # sipariş listesi (metin)
EnvanterTool report [--from 01.08.2026] [--to 31.08.2026]         # envanter raporu: sorunlu kalemler, fazla çıkış, kritik seviye, açık sipariş
EnvanterTool demo --data-dir ~/Desktop/demo [--days 35]           # eğitim için örnek veri
```

Demo veriyle uygulamayı açmak (gerçek veriye dokunmaz):

```bash
ENVANTER_DATA_DIR=~/Desktop/demo "/Applications/NextGen Envanter.app/Contents/MacOS/Envanter"
```

## Hesaplama

- **Olması gereken** = Devreden + Giren + Şubeden gelen − Çıkan − Satılan − Zayi
- **Fark** = Kalan − Olması gereken (= Satılan + Zayi − Gerçek kullanım). Eksi fark (*eksik*) satışlara göre fazla stok çıktığını, artı fark (*fazla*) az çıktığını gösterir; tolerans içindeki fark *Tamam* yazılır.
- **Gerçek kullanım** = Devreden + Giren + Şubeden gelen − Çıkan − Kalan; raporlarda *Satış + zayi* (satılan + zayi) ile karşılaştırılır.
- **Zayi** = ModPos'taki ZAYİ ürünlerinin reçeteye göre düşen miktarı (ya da Excel'den gelen Zaiyat) + Zayi Ekle ile elle girilen kayıtlar. Dışa aktarılan Excel "üzerine yaz" ile geri alınırsa Zaiyat toplam sayılır: elle girilen zayi ondan düşülür, iki kez eklenmez.
- **Fazla çıkış** = tolerans dışı eksi farkı (*eksik*) olan günlerin miktarı (az çıkışlarla mahsup edilmez); tüm ekranlarda aynı tanım.
- **Takip şeridi:** sayılanların en az %20'sinde tolerans dışı fark → kırmızı; en az %10'unda ya da sayım eksikse → sarı; diğer → yeşil.
- **Devreden (elle girilmediyse)** = son sayımın Kalan'ı + aradaki sayılmayan günlerin (Giren + Şubeden gelen − Çıkan − Satılan − Zayi); son sayım yoksa ya da 31 günden eskiyse o günün sayımı başlangıçtır (fark yok). Dönem özetinde devredilen günlerin hareketi de toplanır.
- **Sipariş önerisi** = ortalama günlük tüketim × gün + kritik seviye − mevcut stok (son sayım + sonraki hareketler) − siparişte bekleyen (adet yukarı tam sayıya, kg 0,1'e yuvarlanır)
- **Eşik önerisi:** tolerans = son 28 günün sayılmış günlerindeki |fark|'ın %80'lik dilimi (en az 7 gün), kritik seviye = günlük tüketim × 1,5

## Geliştirme

```
Sources/EnvanterCore   Platformdan bağımsız iş mantığı (motor, ekip, satın alma, eşitleme, anlık bağlantı, Excel/ZIP okuma-yazma, kayıt)
Sources/Envanter       SwiftUI uygulaması (yalnızca macOS; Glass.swift: Liquid Glass yüzeyleri)
Sources/EnvanterTool   Komut satırı aracı
Tests/EnvanterCoreTests
Scripts/               build_app.sh (paket), make_icon.swift (ikon), e2e_cli.sh (komut satırı uçtan uca testi)
```

```bash
swift test                                  # macOS veya Linux (çekirdek testleri)
swift build                                 # macOS'ta uygulama dahil
./Scripts/e2e_cli.sh .build/debug/EnvanterTool
ENVANTER_SELFTEST=1 ".build/debug/Envanter" # uygulama içi sistem testi (geçici klasörde, çıkış kodu 0 = başarılı)
```

CI (`.github/workflows/ci.yml`) şu adımları çalıştırır:
- **Linux:** çekirdek testleri ve komut satırı uçtan uca testi.
- **macOS:** uygulamanın derlenmesi, testler, dağıtım paketi, komut satırı testi ve **uygulama içi sistem testi** (sayım, satış aktarımı ve aktarım uyarıları, geri al/yinele, tolerans, sayılmayan gün devri ve tahmini stok, hareketsizleri doldurma kuralları, eşik önerileri, gün kilidi ve kapatma kontrol listesi, kapatılmamış günleri toplu kapatma, kalem arama, toplayarak giriş, paylaşılan bilgisayarda çalışan, ekip, sipariş formu, düzenleme, teslim alma ve "Teslim alındı say", stok kalemi silme / aynı ad / birim değişikliği, sürüm düzeyi ve gün dönümü, Excel ve diske kayıt gerçek uygulama durumu üzerinden doğrulanır).
- **Ekran görüntüleri:** demo veriyle macOS'ta otomatik alınır.

## Yol haritası / öneriler

- **Şubeler arası transfer:** Transferin iki şubeye birden işlenmesi.
- **ModPos entegrasyonu:** Raporu elle almak yerine ModPos'un dışa aktarım klasörünü izleyip her sabah otomatik içe aktarma.
- **Fatura okuma:** Tedarikçi faturasının fotoğrafından/PDF'inden kalem ve miktarları okuyup siparişi otomatik teslim alma.
- **iPad / iPhone ile sayım:** Depoda telefonla (barkod/QR ile) sayım yapıp anlık olarak Mac'e ve web paneline aktarma.
- **Hesap güvenliği:** Patron hesapları için iki adımlı doğrulama (Supabase MFA).
- **Bildirimler:** Kritik seviyenin altına düşen kalemler ve fazla çıkış olan günler için günlük e-posta/WhatsApp özeti. `EnvanterTool report` ve `orders` bugün de bir cron/launchd göreviyle kullanılabilir.
- **Yarı mamul reçeteleri:** Soslar ve hazırlıklar için alt reçeteler (reçete içinde reçete).
- **Kod imzalama:** Şirket bir Apple Developer hesabı alırsa uygulama Developer ID ile imzalanıp noter onayından geçirilebilir.
