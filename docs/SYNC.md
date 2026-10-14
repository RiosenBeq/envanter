# Web paneli ve bulut eşitleme sözleşmesi

NextGen Envanter iki istemciden yönetilir:

- **Mac uygulaması** ([RiosenBeq/envanter](https://github.com/RiosenBeq/envanter)): şubedeki bilgisayara kurulan, personelin günlük kullandığı uygulama. Sayım, satış aktarımı, sipariş ve ekip buradan yönetilir. Veri yerelde `envanter-verisi.json` olarak tutulur ve buluta anlık eşitlenir.
- **Web paneli** ([RiosenBeq/envantersite](https://github.com/RiosenBeq/envantersite)): patron ve müdürlerin her yerden, anlık izlediği ve gerektiğinde müdahale ettiği panel. Raporlar, sayım düzeltme, sipariş, ekip, kullanıcılar ve yetkiler, şube karşılaştırması ve değişiklik geçmişi buradan yönetilir; Mac'in o an açık olup olmadığı görünür.

Uygulama yalnızca **envanter** yönetir (miktarlar): stok kalemleri, reçeteler, satış aktarımı, günlük sayım ve fark, sipariş, ekip. Para (birim maliyet, satış tutarı, food cost, personel maliyeti, prime cost, hedefler, fiyat uyarıları) Ekim 2026'da kaldırıldı.

Ortak depolama **Supabase**'dir (Postgres + Auth + Row Level Security). İki istemci de Supabase'e doğrudan, kullanıcının oturumuyla bağlanır. Yetkiyi veritabanındaki RLS kuralları ve `security definer` fonksiyonlar uygular; istemcide gizli anahtar yoktur, yalnızca herkese açık *publishable key* kullanılır.

Bu belge iki istemcinin uyması gereken sözleşmedir. Değişiklik yapılırsa iki taraf birlikte güncellenmelidir.

## 1. Veri modeli

Bir **çalışma alanı** (workspace) bir şube/işletmedir. Verisi `AppData`'nın alanlarına karşılık gelen **belgelere** bölünür:

| Anahtar (`key`) | Gövde (`body`, JSON) | Swift tipi |
| --- | --- | --- |
| `items` | stok kalemleri dizisi | `[Item]` |
| `products` | reçeteli ürünler dizisi | `[Product]` |
| `settings` | ayarlar nesnesi | `AppSettings` |
| `employees` | ekip üyeleri dizisi | `[Employee]` |
| `orders` | satın alma siparişleri dizisi | `[PurchaseOrder]` |
| `day:YYYY-MM-DD` | o günün kaydı | `DayRecord` |

- JSON biçimi Swift `JSONEncoder` çıktısıyla aynıdır (`Persistence.encoder()`): `nil` alanlar yazılmaz, tarihler (`salesImportedAt`) ISO 8601 (`2026-08-01T10:15:00Z`), sayılar ondalık.
- Boşalan gün (`DayRecord.isEmpty` ve kilitli değil) silinir: `deleted = true`, `body = {}`. **İstisna:** gövdede istemcinin bilmediği dolu bir alan varsa (ör. eski sürümlerin `shifts`/`otherLabor` alanları) gün silinmez; bilinen alanları temizlenmiş gövde yazılır. Katalog belgeleri (`items/products/settings/employees/orders`) silinmez. `DayRecord.isEmpty`: sayım, satış, elle zayi, not ve sayan yok (boş zayi listesi `[]` boş sayılır).
- Okurken bilinmeyen alanlar korunmalıdır (ileriki ya da eski sürüm alanları kaybolmasın). İstemci bir belgeyi değiştirirken yalnızca bildiği alanlara dokunur; bilmediği alanlar sunucudaki halinden aynen gider. Mac bunu her gönderimde `merge3(taban = sunucu gövdesinin Mac karşılığı, yerel, uzak = sunucunun ham gövdesi)` ile yapar; dizi elemanları burada `id`, `code` ya da `itemID` ile eşlenir (sipariş satırlarındaki bilinmeyen alanlar da kalır). Web, normalleştirirken bilmediği alanları olduğu gibi taşır.
- **Kaldırılan alanlar** yeni istemciler için "bilinmeyen" alandır; bulutta durur, okunmaz, silinmez: `Item.unitCost/costHistory`, `OrderLine.unitPrice`, `SaleLine.amount`, `Employee.payType/rate/costFactor/defaultHours/payHistory`, `DayRecord.shifts/otherLabor`, `AppSettings.targetFoodCostPct/targetLaborPct/targetPrimeCostPct/priceAlertPct`. Eski Mac sürümleri yeni belgeleri okumaya devam eder (eksik alanlar varsayılanla dolar). Yeni sürümün aldığı yerel yedek eski sürümde açılmayabilir (ekip üyelerinde ücret alanı yok); bulut yolu geriye dönük uyumludur.

### Elle zayi (`wasteLog`)

Gün kaydının isteğe bağlı `wasteLog` alanı, "Zayi Ekle" ile elle girilen zayi kayıtlarıdır (bozulan, yanan, düşen, iade edilen mal; ModPos'taki ZAYİ ürünlerinden ayrı). Swift `WasteEntry` / `WasteLog` / `WasteText` (`Waste.swift`), TS `WasteEntry` (`model.ts`) ve `src/lib/engine/waste.ts`. Ortak test vektörleri `waste-vectors.json` (Mac `Tests/EnvanterCoreTests/Fixtures/`, web `test/fixtures/`, aynı içerik).

- **Eleman:** `{ id, itemID, qty, reason, note?, by?, at? }`. `qty` kalemin envanter biriminde, > 0. `reason`: `spoiled` (Bozuldu / SKT geçti), `burnt` (Yandı / hatalı üretim), `dropped` (Düştü / döküldü), `returned` (Müşteri iadesi), `staffMeal` (Personel yemeği), `training` (Deneme / eğitim), `other` (Diğer); bilinmeyen değer korunur ve "Diğer" görünür. `note` en fazla 200 karakter, `by` kaydı giren kişi (varsayılan günün sayanı), `at` saniye hassasiyetinde UTC (`2026-10-13T19:40:00Z`).
- **Okuma:** dizi değilse alan yok sayılır. Eleman `id` ya da `itemID` metin değilse veya `qty` sonlu ve > 0 değilse atılır; `reason` yoksa `other`. Elemanların bilinmeyen alanları korunur (web normalleştirirken taşır, Mac `merge3` tabanıyla).
- **Yazma:** yeni kayıt dizinin sonuna eklenir; silme kimliğe göre yapılır. **Son kayıt silinince `[]` yazılır, anahtar silinmez** ve okurken `[]` olduğu gibi kalır: anahtar silinseydi `merge3` (taban `[e1]`, yerel yok, uzak `[e1, e2]`) yereli seçer ve başka cihazın eklediği `e2` kaybolurdu; `[]` ile kimliğe göre birleştirme `[e2]` verir (`merge3-vectors.json`). Günde başka veri yoksa boş gün olağan kuralla silinir (aynı anda başka cihazdan eklenen kayıt kaybolmaz, silinen kayıt geri gelebilir). İki istemcide de kapatılmış günde yapılmaz; personel açık güne yazabilir (gün belgesi).
- **Hesap:** `ItemCalc.manualWaste` = günün o kaleme ait kayıtlarının toplamı (bilinmeyen kaleme ait ya da miktarı > 0 olmayan kayıtlar atlanır); `waste` = ModPos ZAYİ ürünleri (ya da Excel'den gelen Zaiyat) + `manualWaste`. Fark, dönem özeti, devreden açılış (günün hareketi), sipariş önerisinin satıştan tüketimi ve "Hareketsizleri Doldur" toplam zayiyi kullanır: elle zayisi olan kalem hareketsiz sayılmaz. Dışa aktarılan Alımlar'ın Zaiyat sütunu toplam zayidir (elle girilen dahil); Mac'te Excel'den "üzerine yaz" ile aktarılan günde Zaiyat'ı ve elle kaydı olan kalemde Zaiyat ≥ elle toplamı ise kayıtlar kalır ve Zaiyat'tan düşülür, değilse o kalemin kayıtları silinir (`[]` kalır): kalemin Zayi'si dosyadaki Zaiyat olur, iki kez sayılmaz (`WorkbookImporter.reconcileManualWaste`).
- **Ekranlar:** Günlük Sayım'da "Zayi Ekle" (aranabilir kalem listesi, miktar, neden, not, kim; seçilen kalemin o günkü ModPos zayisi ve önceden elle girilenler gösterilir: aynı zayi iki kez girilmesin), Zayi hücresi dökümü açar (ModPos ZAYİ ürünleri + elle girilenler, düzenlenebilir günde silme; ipucu "Zayi 1,5 kg (ModPos 0,4 + elle 1,1)"), "Zayi kayıtları (N)". Excel'den aktarılan günde (`usesLegacySales`) ipucunda kaynak "Excel" yazılır ve dökümde "Excel'den aktarılan Zaiyat: 0,5 kg" satırı çıkar (`WasteText.cellHelp` / `legacyLine`, web `wasteCellHelp` / `wasteLegacyLine`). Dönem Excel'inde (`Exporter.history` / web `historySheets`) aralıkta kayıt varsa "Zayi Kayıtları" sayfası `[Tarih, Kalem, Miktar, Birim, Neden, Not, Kim]` (Notlar'dan sonra, Ekip'ten önce). Değişiklik geçmişi: "31.08.2026 zayi eklendi: Patates 1,5 kg (Bozuldu / SKT geçti)", "… zayi silindi: Patates 1,5 kg".
- **Eski sürümler:** bu sürümden önceki Mac'ler alanı bilinmeyen alan olarak korur (yalnızca zayi kaydı olan gün de silinmez) ama Zayi'ye eklemez; o Mac'te Açılış, Fark ve dönem toplamları farklı görünür ve "Hareketsizleri Doldur" yalnızca elle zayisi olan kaleme kapanış = açılış yazabilir (yeni istemcilerde yanlış fazla stok). Mağaza bilgisayarları birlikte güncellenmelidir.

### Ekip (`employees`) ve eski sayım listesi

`Employee = { id, name, role (görev: "Usta", "Kasiyer"…), phone?, active, startDate?, endDate?, note?, account? }`. `account`, üyenin bağlı giriş hesabının e-postasıdır (kullanıcı adıyla açılanlarda `<ad>@envanter.local`). Okurken yalnızca `id` zorunludur; `role` boşsa `""`, `active` yoksa `true`.

- **Sayan seçimi:** önce aktif ekip üyeleri (liste sırasıyla), sonra eşleşmeyen eski `settings.staff` adları (`Team.counterNames` / web `counterNames`). Yeni yazılan bir sayan adı ekibe üye olarak eklenir (`rememberingCounter`; personel rolünde eklenmez, kimlik çakışırsa `-2`, `-3`…). **Hiçbir istemci artık `settings.staff`'a yazmaz.**
- **Eski listenin taşınması:** `settings.staff` doluysa ve istemci tanım belgelerini yazabiliyorsa (patron/müdür, ya da hiçbir şubeye bağlı olmayan Mac) her ad `Employee(id: "staff-" + slug(ad), name: ad, role: "", active: true)` olarak eklenir ve `settings.staff = []` yapılır. Slug'ı boş olan, aynı slug'lı üyesi ya da aynı kimliği olan ad atlanır. Kimlikler deterministik olduğu için Mac ile web aynı anda taşısa da `merge3` (kimliğe göre) aynı sonuca varır. Bağlı istemcide taşıma yalnızca çekmeden sonra yapılır; önce `employees`, sonra `settings` gönderilir (`employees` gönderilemezse `settings` bekler, ad kaybolmaz). `settings` çakışmasında uzaktaki eski adlar birleştirilip taşıma yeniden yapılır. Sunucudaki `settings` ya da `employees` belgesi çözülemiyorsa taşıma bekler.
- Test vektörleri (kullanıcı adı, slug, kimlik): Mac `Tests/EnvanterCoreTests/Fixtures/account-vectors.json`, web `test/fixtures/account-vectors.json` (aynı içerik).

### Kullanıcı adıyla giriş

E-postası olmayan çalışan için hesap kullanıcı adıyla açılır. Giriş adı `@` içermiyorsa kullanıcı adıdır ve `<ad>@envanter.local` e-postasına çevrilir: Türkçe harfler (ç ğ ı İ ö ş ü) ASCII'ye, harfler küçüğe, aksanlar atılır; boşluklar `.` olur; `[a-z0-9._-]` dışındaki karakterler atılır; art arda noktalar teke iner, baştaki/sondaki nokta atılır ("Ayşe Yılmaz" → `ayse.yilmaz@envanter.local`). `@` içeren giriş adı küçük harfe çevrilip olduğu gibi kullanılır. Ekranlarda `@envanter.local` hesapları yalnızca kullanıcı adıyla gösterilir. Bu hesaplara e-posta gitmez: kayıt olunamaz, "Şifremi unuttum" yerine patron "Şifre belirle" kullanır; davet yalnızca gerçek e-postaya gönderilir.

### Bağlantı kodu (mağaza bilgisayarını bağlama)

Patron web panelinde (Yönetim → Kullanıcılar → **Bilgisayar Bağla**) bir bağlantı kodu üretir; mağaza bilgisayarındaki uygulamada (Mac ya da Windows) **Web'e Bağlan** penceresine bu kod yazılır, yapıştırılır ya da `envanter://` bağlantısı tıklanır. Kullanıcı adı, şifre, şube seçimi ve sunucu ayarı gerekmez. Veritabanında ek tablo yoktur: kod, şubeye üye yapılan ayrı bir **cihaz hesabının** giriş bilgisidir.

- **Kod:** `23456789ABCDEFGHJKMNPQRSTUVWXYZ` alfabesinden (0, 1, I, L, O yok) 16 rastgele karakter (kriptografik üreteç, ret örneklemesi: bayt < 248 ise `bayt % 31`). Ekranda 4'erli gruplar: `7KQ2-M9XP-4TRA-HW3D`.
- **Cihaz hesabı:** kullanıcı adı `pc-` + kodun ilk 6 karakteri küçük harfle (`pc-7kq2m9`, e-posta `pc-7kq2m9@envanter.local`), şifre kodun kendisi (16 büyük harf, tiresiz). Web, `envanter_create_account(şube, e-posta, kod, rol)` ile açar (yalnızca patron; rol önerilen `manager`, istenirse `staff`). Sonuç `created` değilse (rastgele çakışma: bu e-postayla hesap zaten var) ve hesap çağrıdan önce şubede üye değilken üye olduysa hemen `envanter_remove_member` ile çıkarılır, yeni kodla en çok 3 kez denenir.
- **Kodu okuma:** girişte `kod=` varsa ondan sonrası `&`, `#` ya da boşluğa kadar alınıp yüzde kodlaması çözülür; ASCII küçük harfler büyütülür; `(?:^|[^0-9A-Z])([0-9A-Z]{4}(?:[- ]?[0-9A-Z]{4}){3})(?=$|[^0-9A-Z])` eşleşmeleri soldan sağa denenir, tire ve boşluk atılınca 16 karakterinin hepsi alfabede olan ilk eşleşme koddur. Böylece WhatsApp mesajının tamamı ya da bağlantı yapıştırılabilir.
- **Bağlantı:** `envanter://baglan?kod=<gösterim>&sunucu=<url>&anahtar=<publishable key>` (değerlerde `A–Z a–z 0–9 - _ . ~` dışındaki her karakter yüzde kodlanır — `encodeURIComponent`'e ek olarak `! ' ( ) *` de). Mac ve Windows uygulaması bu adresi açar; bağlı değilse hemen bağlanır, başka bir şubeye bağlıysa onay bekler.
- **Web / Windows:** `/baglan` sayfası kodu `#kod=` ya da `?kod=` ile alır (sonra adres çubuğundan siler); Windows uygulaması `envanter://baglan?...` bağlantısını bu sayfaya çevirir. Tarayıcıda bağlanmak için tıklamak gerekir; Windows uygulamasında kimse girişli değilse kendiliğinden bağlanır. Cihaz şifreleri tarayıcıda `localStorage` `envanter.deviceLogin` `{email, passwords, signedOut?}` altında tutulur; açıkça çıkış yapılınca (`signedOut`) sessiz yeniden giriş durur, "Bu bilgisayarı ayır" kaydı siler.
- **Tek kullanımlık:** Uygulama kodla giriş yapınca cihaz hesabının şifresini kendi ürettiği 32 karakterlik rastgele şifreyle değiştirir (`PUT /auth/v1/user`) ve bunu yalnızca kendi eşitleme durumunda saklar; kod bundan sonra çalışmaz. Oturum düşerse saklı şifreyle sessizce yeniden girer. Bilgisayarı kaldırmak için patron listeden "Bağlantıyı kaldır" der (`envanter_remove_member`).
- **Ekranlar:** `isDeviceAccount(e-posta)` = boşluklar atılıp küçük harfe çevrildikten sonra `^pc-[2-9a-hjkmnp-z]{6}@envanter\.local$`. Bu hesaplar Kullanıcılar listesinde kişilerden ayrı, "Bağlı bilgisayarlar" bölümünde gösterilir; "Şifre belirle" sunulmaz.
- Test vektörleri: Mac `Tests/EnvanterCoreTests/Fixtures/pair-vectors.json`, web `test/fixtures/pair-vectors.json` (aynı içerik).

### Paylaşılan bilgisayarda çalışan

Bağlantı koduyla bağlanan mağaza bilgisayarı cihaz hesabıyla (`pc-…`) yazar; değişiklik geçmişinde kişi görünmez. Swift `SessionWorker` (`Worker.swift`), TS `src/lib/worker.ts`; ortak test vektörleri `worker-vectors.json` (Mac `Tests/EnvanterCoreTests/Fixtures/`, web `test/fixtures/`, aynı içerik). Veri modeli ve sunucu değişmez.

- **Soru:** cihaz hesabı (`isDeviceAccount`) şubeyi açınca oturumda bir kez "Şu an kim çalışıyor?": aktif ekip üyelerinin adları (liste sırasıyla; boş ad ve `nameKey`'i aynı olan ikinci ad atlanır) ve "Atla". Yan menüdeki ad ("Değiştir") pencereyi yeniden açar. Seçim yalnızca o bilgisayarda tutulur ve eşitlenmez: Mac'te uygulama açık kaldıkça (bellekte), web / Windows'ta tarayıcı oturumunda (`sessionStorage` `envanter.worker.<kullanıcı kimliği>`, `""` = atlandı). Ad, boşlukları kırpılarak kullanılır; boşsa seçilmemiş sayılır.
- **Değişiklik geçmişi:** özet boş değilse sonuna `" · " + ad` eklenir: "09.10.2026 sayımı: 90 Gr kapanış 120 → 110 · Murat A." (`p_summary` yine 500 karakterde kırpılır).
- **Sayan:** bir kalemin kapanışı girilince ya da değişince günün `countedBy`'ı boşsa çalışan yazılır; doluysa değişmez (aynı işlemde, ayrı geri alma adımı yok).
- **Zayi Ekle "Kim" varsayılanı:** günün sayanı, yoksa çalışan, yoksa bu hesaba bağlı ekip üyesi (cihaz hesabının bağlı üyesi aranmaz), yoksa boş.

### Günü kapatma: kontrol listesi, kapatılmamış günler, eski gün uyarısı

Swift `DayCloseCheck` / `UnclosedDays` / `OldDayWarning` (`DayClose.swift`), TS `src/lib/engine/dayClose.ts`; ortak test vektörleri `dayclose-vectors.json`. Kapatma yine yalnızca `"locked": true` yazar; sunucu kuralı (aşağıda "Kapatılmış gün") değişmedi.

- **Kontrol listesi** (`Engine.overview` değerlerinden): sırayla `counted` (aktif kalem varsa: "Sayım tamam: 21 / 21 kalem sayıldı." ✓ ya da "Sayım eksik: 18 / 21 kalem sayıldı, 3 kalem sayılmadı." ⚠), `sales` ("Satış raporu aktarıldı." ✓ ya da "Satış raporu aktarılmadı: satılan miktarlar ve farklar eksik hesaplanır." ⚠), `unknown` (yalnızca varsa: "2 satış ürününün reçetesi tanımlı değil: stoğa yansımadı." ⚠; personelde sonuna "Reçetesini patron veya müdür tanımlar."), `problems` (yalnızca varsa: "Tolerans dışı fark: 3 kalem." — bilgi, onay gerektirmez).
- **Onay:** `needsConfirm = personel || sayılan < toplam || satış yok || tanımsız reçete > 0`. Gerekmezse gün hemen kapanır ("13.10.2026 günü kapatıldı"). Pencere: "13.10.2026 günü kapatılsın mı?", satırlar, kural (personel "Günü kapatınca sayım ve satış değiştirilemez; kilidi yalnızca patron veya müdür açabilir.", patron / müdür "Sayım ve satış kilitlenir; kilidi daha sonra Günlük Sayım'dan açabilirsiniz."). Düğme uyarı yoksa "Günü Kapat", varsa "Yine de Kapat"; sayılmayan kalem varsa "Sayılmayanları Göster" (Günlük Sayım, Sayılmayan filtresi; gün açık kalır), web'de satış raporu yoksa "Satış raporu aktar". Mac'in metin penceresi satırları ✓ / ⚠ / • ile yazar; onay gerekiyorsa menüde "Günü Kapat…".
- **Kapatılmamış günler:** seçili gün dahil son 60 günde verisi olan, en az bir kalemi sayılmış ve kapatılmamış günler, yeniden eskiye, her biri kontrol listesiyle. Mac: Genel Bakış'taki "N sayılmış gün kapatılmadı" ya da Gün → Kapatılmamış Günler…; web: Genel Bakış → Bu ay → Kapatılmamış gün. Patron / müdür seçtiklerini "Seçilenleri Kapat" ile tek işlemde (tek geri alma adımı) kapatır; uyarısı olmayan günler önceden seçilidir; kapatılmış ya da sayımı olmayan gün atlanır ("3 gün kapatıldı"). Personel listeyi görür, günü açıp tek tek kapatır.
- **Eski gün uyarısı:** personel hesabı bugünden 7 günden eski (`bugün − gün > 7`) bir gün kaydını değiştirince uyarılır, yazma engellenmez: "7 günden eski bir güne giriş yapıyorsunuz" / "02.08.2026 günü seçili. Doğru günü seçtiğinizden emin olun; bu uyarı oturum başına bir kez gösterilir." (birden çok gün yazıldıysa en eskisi). Oturum: Mac'te uygulama açık kaldıkça, web'de tarayıcı oturumu (`sessionStorage` `envanter.oldDayWarned`).

### Sayım girişi: kalem arama ve toplayarak giriş

Swift `Fmt.parseCountExpression` (`Format.swift`), `ItemSearch` / `CountEntryText` (`CountEntry.swift`); TS `parseCountExpression` (`src/lib/format.ts`), `src/lib/countEntry.ts`. Ortak test vektörleri `count-vectors.json`; `format-vectors.json`'ın `countExpression` bölümü Swift'in ürettiği çıktıdır.

- **Toplayarak giriş** (Günlük Sayım'ın sayı hücreleri; web'de teslim alma ve Zayi Ekle miktarı da): boşluklar atılır; yalnızca `0-9 . , + x X * ×`; `+` ile en çok 20 terim, terimde en çok bir çarpma (`x`, `X`, `*`, `×`); boş terim geçersiz. Sayılar adet kalemde `parseQuantity` ("1.200" → 1200), kg kalemde `parse` ("1.200" → 1,2; "2,5" → 2,5) ile okunur. Sonuç `clean` ile yuvarlanır; sonlu, ≥ 0 ve < 10¹² olmalı. Eksi, bölme, parantez geçersizdir (hücre eski değerinde kalır). "12+8+5" → 25, "3x24+7" → 79, kg "2,5+1,25" → 3,75. İşlem kaydedilince ipucu ve ekran okuyucu "12+8+5 = 25" der (`countExpressionText`). Ayrı "+" düğmesi yoktur.
- **Kalem arama** (Günlük Sayım; Mac ⌘F ya da Gün → Kalem Ara, web `/` ya da Ctrl/⌘+F): arama ve ad boşlukları kırpılıp ASCII'ye katlanır (`TextFold.ascii` / `foldAscii`); kalem adı ya da kimliği aramayı içeriyorsa eşleşir; Tümü / Sayılmayan / Sorunlu filtresiyle birlikte uygulanır. Enter görünen ilk kalemin kapanışına gider, Esc aramayı temizler. Eşleşme yoksa "“pat” ile eşleşen kalem yok" ve "Aramayı temizle". Mac Stok Kalemleri'nde de aynı arama vardır (ararken sürükleyerek sıralama kapalı).
- **Dokunmatik (web):** kaba işaretçili (`pointer: coarse`) cihazlarda giriş alanlarının yazısı 16 px'tir (iOS odaklanınca yakınlaştırmasın); sayım hücrelerinde `enterkeyhint="next"`.

## 2. Supabase şeması

Tablolar `public` şemasında `envanter_` önekiyle durur. Migration dosyası `envantersite/supabase/migrations/20261009120000_envanter.sql`'dir. Supabase GitHub entegrasyonu bu dosyayı `main`'e birleştirmede `postgres` rolüyle, tek işlem (transaction) içinde otomatik uygular. Dosya idempotenttir; tekrar uygulanması zarar vermez.

```
envanter_workspaces (id uuid PK, name text, created_at, created_by uuid)
envanter_members    (workspace_id uuid FK, user_id uuid FK auth.users, role text, email text, added_at)
                    PK (workspace_id, user_id); role ∈ owner | manager | staff
envanter_invites    (workspace_id uuid FK, email text (küçük harf), role text, invited_by uuid, created_at)
                    PK (workspace_id, email)
envanter_docs       (workspace_id uuid FK, key text, body jsonb, rev bigint, deleted bool,
                     updated_at timestamptz, updated_by uuid, client text)
                    PK (workspace_id, key); index (workspace_id, rev)
envanter_activity   (id bigserial PK, workspace_id uuid, user_id uuid, email text, at timestamptz,
                     client text, key text, summary text); index (workspace_id, id desc)
                    key = belge anahtarı ya da 'members' (patronun üyelik işlemleri: hesap açma,
                    şifre belirleme, davet, yetki değişikliği, şubeden çıkarma; belge değil,
                    client = null)
envanter_rev_seq    belge her yazıldığında rev = nextval (çalışma alanları arasında tekdüze artar)
```

### Roller

| Rol | Okuma | Yazma |
| --- | --- | --- |
| owner (patron) | hepsi | hepsi + kullanıcı/yetki yönetimi (hesap açma, şifre belirleme, davet) + şube adı |
| manager (müdür) | hepsi | tüm belgeler |
| staff (personel) | hepsi | yalnızca `day:*` (sayım, satış, not); kapatılmış (kilitli) günü değiştiremez |

Sunucunun personel hata metni migration dosyasında sabit olduğundan hâlâ "(sayım, satış, vardiya, not)" der; istemciler bu yazmaları önceden engeller ve kendi metinlerini gösterir.

**Kapatılmış gün.** Kapatılan (kilitlenen, `"locked": true`) gün envanter geçmişini korur. Personel bir günü kapatabilir, ama sunucudaki güncel hali kilitli olan günü değiştiremez, kilidini açamaz ve silemez. Bunları yalnızca patron ve müdür yapabilir. Kural sunucuda `envanter_put` içinde uygulanır. İstemciler de aynı kuralı arayüzde gösterir: personel için kilitli gün salt okunurdur ve "Kilidi Aç" düğmesi yoktur.

Bir kullanıcı birden çok çalışma alanına (şubeye) üye olabilir. Patron tüm şubelerini tek hesaptan görür ve karşılaştırır.

### RLS

Üyeler kendi çalışma alanlarının `workspaces`, `members`, `docs` ve `activity` satırlarını okuyabilir. `invites` satırlarını yalnızca owner okuyabilir. Hiçbir tabloya doğrudan `insert/update/delete` izni yoktur; tüm yazmalar aşağıdaki RPC'lerle yapılır.

### RPC'ler

Hepsi `security definer` ve `set search_path = public, pg_temp` ile tanımlıdır. Çağıranı `auth.uid()` ile doğrular; yalnızca `authenticated` rolüne açıktır.

- `envanter_create_workspace(p_name text) returns uuid` — Şube açar ve çağıranı owner yapar. Yalnızca hiç şube yokken (ilk kurulum) ya da çağıran en az bir şubede owner ise izin verilir.
- `envanter_my_workspaces() returns table(id uuid, name text, role text)` — Önce `envanter_accept_invites()` çalışır.
- `envanter_accept_invites() returns integer` — Çağıranın e-postasına (`auth.jwt() ->> 'email'`, küçük harf) yapılmış davetleri üyeliğe çevirir ve sayısını döner. `auth.users` ekleme tetikleyicisi de aynı işi yapar. Patronun açtığı ya da şifresini belirlediği hesaplar (`raw_app_meta_data.envanter_managed_by`) davetleri kendiliğinden kabul etmez (e-posta sahipliği kanıtlanmamıştır, şifreyi o patron bilir); başka şubenin patronu böyle bir hesabı yeniden davet ederek (hesap var → doğrudan üye) ekler.
- `envanter_rename_workspace(p_workspace uuid, p_name text)` — Yalnızca owner.
- `envanter_put(p_workspace uuid, p_key text, p_body jsonb, p_base_rev bigint, p_deleted boolean default false, p_client text default null, p_summary text default null) returns table(ok boolean, rev bigint, body jsonb, deleted boolean)`
  - Belge yoksa ve `p_base_rev = 0` ise eklenir.
  - Belge varsa ve `rev = p_base_rev` ise güncellenir (`rev = nextval`).
  - Aksi halde yazılmaz: `ok = false` ve sunucudaki güncel `rev/body/deleted` döner (çakışma).
  - Rol yetkisi yoksa hata verir. Anahtar biçimi ve gövde tipi doğrulanır: `items/products/employees/orders` dizi, `settings` ve `day:*` nesne olmalıdır.
  - Kapatılmış gün: çağıran staff ise ve sunucudaki güncel gövde kilitliyse (`body -> 'locked' = true`, silinmemiş) değişiklik, kilit açma ve silme `42501` "Kapatılmış günü yalnızca müdür veya patron değiştirebilir." ile reddedilir. Aynı gövdeyi yeniden yazmak serbesttir. Bu denetim rev karşılaştırmasından **sonra** yapılır. Eski `p_base_rev` ile yazan istemci önce olağan çakışmayı (kilitli gövdeyle) alır. Bu yüzden `42501` alan istemcinin `base`'i her zaman sunucudaki kilitli haldir. İstemci o anahtar için `base`'i geri yükler ("sunucu kazanır"), kullanıcıya bir kez bildirir ve yeniden denemez. Yeni gün eklemek ve açık günü kapatmak personel için serbesttir. Boolean olmayan `locked` değerleri kilit sayılmaz.
  - Başarılı her yazma `envanter_activity`'e bir satır ekler. Özet metni (`p_summary`) istemci üretir; boşsa "güncellendi" yazılır. Örnek: "09.10.2026 sayımı: 90 Gr kapanış 120 → 110".
- `envanter_invite(p_workspace uuid, p_email text, p_role text)` — Yalnızca owner. Kullanıcı zaten kayıtlıysa doğrudan üye yapılır, değilse davet kaydedilir (kayıt olunca otomatik üye olur). Sonuç olarak `'member' | 'invited'` döner.
- `envanter_cancel_invite(p_workspace uuid, p_email text)` — Yalnızca owner.
- `envanter_set_role(p_workspace uuid, p_user uuid, p_role text)` — Yalnızca owner. Son owner düşürülemez.
- `envanter_remove_member(p_workspace uuid, p_user uuid)` — Yalnızca owner. Son owner silinemez. Rol denetimi her istekte üyeliğe bakar; çıkarılan üyenin erişimi hemen kesilir.
- `envanter_members_list(p_workspace uuid) returns table(user_id uuid, email text, role text, added_at timestamptz, pending boolean, can_set_password boolean)` — Üyeler ve bekleyen davetler. Davetleri yalnızca owner görür. `can_set_password`: çağıran (owner) bu üyenin şifresini `envanter_set_member_password` ile belirleyebilir mi (owner olmayanlar ve davetler için hep `false`).
- `envanter_create_account(p_workspace uuid, p_email text, p_password text, p_role text) returns text` — Yalnızca owner. E-posta gerektirmeden hesap açar (Supabase'in yerleşik e-postası yalnızca organizasyon ekibine ulaşır; özel SMTP yoksa davet/onay e-postası gelmez). E-postayla hesap yoksa e-postası onaylı, verilen şifreli bir hesap açılır (`auth.users` + `auth.identities`), `p_role` ile üye yapılır ve `'created'` döner; e-postası onaylı hesap varsa `envanter_invite` gibi üye yapılır, şifresine dokunulmaz ve `'member'` döner (farklı rolle zaten üyeyse `23505`). Hesap var ama e-postası onaylanmamışsa (kişi kendisi kayıt olmuş, doğrulama e-postası gelmemiş): çağıran şifresini belirleyebiliyorsa (`envanter_set_member_password` kuralları) hesap verilen şifreyle açılır, e-postası onaylanır, üye yapılır ve `'created'` döner; belirleyemiyorsa hiçbir şey değişmez ve `'unconfirmed'` döner. Şifre en az 8 karakter, en fazla 72 bayt (`22023`). Bu e-postaya bu şubede ve çağıranın patronu olduğu şubelerde bekleyen davetler kapanır; başka patronların davetleri beklemede kalır.
- `envanter_set_member_password(p_workspace uuid, p_user uuid, p_password text)` — Yalnızca owner. Üyenin şifresini belirler (eski şifre hemen geçmez), onaylanmamış e-postasını onaylar ve oturumlarını yenilenemez yapar (yenileme jetonları silinir; elde kalan erişim anahtarı süresi dolana kadar, varsayılan 1 saat, geçerlidir; erişimi hemen kesmek için `envanter_remove_member`). Hedef bu şubenin üyesi olmalı (`22023`), çağıranın kendisi olmamalı (`22023`; kendi şifresi `PUT /auth/v1/user` ile değişir), hiçbir şubede owner olmamalı ve üye olduğu her şubenin owner'ı çağıran olmalı (`42501`; başka bir patronun çalışanının hesabını ele geçirmeyi önler).
- Patronun üyelik işlemleri (`envanter_create_account`, `envanter_set_member_password`, `envanter_invite`, `envanter_cancel_invite`, `envanter_set_role`, `envanter_remove_member`) bir şey değiştirdiyse `envanter_activity`'e `key = 'members'` satırı yazar: "Hesap oluşturuldu: x (Personel)", "Hesap açıldı (doğrulanmamış kayıt): x (Personel)", "Mevcut hesap şubeye eklendi: x (Müdür)", "Davet edildi: x (Personel)", "Davetin yetkisi değişti: x (Personel → Müdür)", "Davet iptal edildi: x (Müdür)", "Yetki değişti: x (Müdür → Personel)", "Şubeden çıkarıldı: x (Personel)", "Şifre belirlendi: x; eski şifresi geçersiz, açık oturumları en geç 1 saat içinde kapanır". Şifre hiçbir yere yazılmaz.

### Hata kodları ve sınır durumlar

- Var olmayan belgeye sıfırdan farklı `p_base_rev` ile yazma: `ok = false`, `rev = 0`, `body = null`, `deleted = false` döner.
- Başarılı yazma kaydedilen gövdeyi döner (silinmişse `{}`).
- Yetki hatası: SQLSTATE `42501`, HTTP 403 (oturum yoksa 401). Örnekler: üye değil ("Bu şubeye erişiminiz yok."), personelin katalog yazması ("Personel (staff) yalnızca gün kayıtlarını …"), personelin kapatılmış günü değiştirmesi ("Kapatılmış günü yalnızca müdür veya patron değiştirebilir.").
- Üye değil: `22023`, HTTP 400.
- Son owner kuralı: `P0001`, HTTP 400.
- Var olan üyeyi farklı rolle davet (ya da `envanter_create_account`): `23505`, HTTP 409. Aynı rolle davet `'member'` döner.
- Hesap / şifre: şifre kuralı ve kendi şifresini belirleme `22023` (HTTP 400); owner olmayan çağıran, owner hedef ya da başka patronun şubesinde de çalışan hedef `42501` (HTTP 403).
- `day:*` anahtarları gerçek takvim günü olmalıdır.
- `p_client` 100, `p_summary` 500 karakterle kırpılır.
- Kilitli ama başka verisi olmayan gün silinmez (Mac'teki `isEmpty && !isLocked` kuralı). `salesImportedAt` kesirli saniye içermez (`2026-08-01T10:15:00Z`), çünkü Mac'in ISO 8601 çözücüsü kesirli saniyeyi kabul etmez.

### Okuma ve canlı güncelleme

**Okuma (pull):**
`GET /rest/v1/envanter_docs?workspace_id=eq.W&rev=gt.N&order=rev.asc&select=key,body,rev,deleted,updated_at,updated_by&limit=500`. Satırlar 500'lük sayfalarla okunur ve `N` her sayfada son `rev`'e ilerletilir.

**Canlı güncelleme:** `envanter_docs` ve `envanter_activity` tabloları `supabase_realtime` yayınına eklenir. İki istemci de değişiklikleri anında görür:

- **Web:** `postgres_changes` aboneliği (kanal adı web'e özeldir); bildirim gelince artımlı çekme. Realtime bağlanamazsa 15 sn'de bir, bağlıyken güvenlik ağı olarak 60 sn'de bir çeker.
- **Mac:** Supabase Realtime (Phoenix, `vsn=1.0.0`) soketi: `wss://<proje>/realtime/v1/websocket?apikey=<publishable key>&vsn=1.0.0`, konu `realtime:envanter-canli:<şube kimliği>`. Katılma gövdesi: `{"config":{"broadcast":{"ack":false,"self":false},"presence":{"key":<cihaz anahtarı>,"enabled":true},"postgres_changes":[{"event":"*","schema":"public","table":"envanter_docs","filter":"workspace_id=eq.<şube>"}],"private":false},"access_token":<jwt>}`. Her belge değişikliğinde ≈0,3 sn içinde çeker; 25 sn'de bir kalp atışı; kopunca 1, 2, 5, 10, 30 sn aralıklarla yeniden bağlanır ve bağlanınca kaçırdıklarını çeker; oturum yenilenince `access_token` olayı gönderir. Yerel değişiklik 2 sn sonra gönderilir; 60 sn'de bir eşitleme güvenlik ağı olarak sürer. Otomatik test ve ekran görüntüsü modlarında Realtime açılmaz.
- **Varlık (presence):** aynı konuda Mac `{client:"mac", branch, app, since, device?}` (cihaz anahtarı kurulum başına sabit, e-posta yok; `device` yalnızca bağlantı koduyla bağlanan bilgisayarda cihaz hesabının kullanıcı adıdır, örn. `pc-7kq2m9`, web "Bağlı bilgisayarlar" listesinde o bilgisayarı çevrimiçi gösterir), web `{client:"web", device?}` izler (anahtar `web-<rastgele>`; `device` yalnızca cihaz hesabıyla açık tarayıcıda). Windows uygulamasında (web paneli `window.envanterDesktop` ile çalışır) web `{client:"windows", branch, app, since, device?}` izler ve yazmalarında `p_client = "windows"` gönderir (Mac `"mac"`, tarayıcı `"web"`). Mağaza bilgisayarı = `client` `mac` ya da `windows` olan varlık: biri varsa "Mac çevrimiçi" / "Windows bilgisayarı çevrimiçi" (birden çoksa "N bilgisayar çevrimiçi"), yoksa son bilgisayar hareketinin türüne göre "Mac / Windows bilgisayarı / Mağaza bilgisayarı çevrimdışı · son veri …" görünür. Kanal herkese açık (private kanal veritabanı değişikliği ister): şube kimliğini ve publishable key'i bilen biri varlık bilgisini okuyabilir ya da sahte "çevrimiçi" gösterebilir; belge değişiklikleri RLS ile korunur.

**Mac uygulaması isteği:**
- Giriş: `POST {URL}/auth/v1/token?grant_type=password` (başlık `apikey: <publishable key>`). Yanıttaki `access_token` ve `refresh_token` saklanır; yenilenen anahtarlar hemen `esitleme.json`'a yazılır. Web paneliyle aynı giriş adı (e-posta ya da kullanıcı adı) ve şifre kullanılır.
- Yenileme reddedilirse (ör. patron şifre belirledi, kullanıcı şifresini başka yerde değiştirdi) oturum düşmüş sayılır: kullanıcıdan yeniden giriş istenir, bekleyen değişiklikler korunur.
- Sonraki istekler: `apikey` başlığı ve `Authorization: Bearer <access_token>`.
- RPC: `POST {URL}/rest/v1/rpc/<ad>`. Süre dolunca `grant_type=refresh_token` ile yenilenir.

## 3. Eşitleme algoritması (iki istemci için aynı)

İstemci durumu:

- `lastRev`: görülen en büyük `rev`.
- `base[key] = { rev, body }`: o belgenin sunucudan son alınan/yazılan hali.
- `dirty`: yerelde değişmiş, henüz gönderilmemiş anahtarlar.

**Çek (pull).** `rev > lastRev` olan her satır için:
- Anahtar `dirty` değilse sunucu sürümü yerele uygulanır. `deleted` ise yerelden silinir.
- `dirty` ise `merged = merge3(base.body, local, remote)` yerele yazılır, anahtar `dirty` kalır.
- Her iki durumda `base = remote` olur ve `lastRev` ilerletilir.

**Taşıma.** Çekmeden sonra, gönderimden önce, tanım yazabilen istemci eski sayım listesini ekibe taşır (bkz. §1 Ekip).

**Gönder (push).** Her `dirty` anahtar için (sıra: `items, products, employees, settings, orders`, sonra günler) `envanter_put(key, local, base.rev ?? 0, deleted)` çağrılır:
- `ok`: `base = { rev, body: local }` olur ve anahtar `dirty`'den çıkar.
- Çakışma: `local = merge3(base.body, local, server.body)`, `base = server` olur ve en fazla 3 kez yeniden denenir.
- Kalıcı hata (`42501` yetki, `22023` doğrulama …): anahtar `dirty`'den çıkar, yerel hal `base.body` ile değiştirilir (sunucu kazanır; `base` yoksa yerelden silinir), kullanıcıya bir kez bildirilir. Yeniden denenmez.
- Mac: gün belgesinde `42501` yalnızca `base` kilitliyse (kapatılmış gün) "sunucu kazanır" ile sonuçlanır; sonraki anahtarların gönderimi aynı turda sürer. Kilitsiz gün için `42501` (ör. şubeden çıkarılma) çevrimdışı işi kaybetmemek için yerel veriyi geri almaz: hata gösterilir, anahtar `dirty` kalır. Çakışma sınırı aşılan anahtar da `dirty` kalır, diğer anahtarlar gönderilmeye devam eder.

**Bekleyen değişikliklerin saklanması (web).** Bulut modunda gönderilmemiş belgeler tarayıcıda `localStorage` `envanter.pending.<kullanıcı>.<şube>` altında saklanır (sürüm, kullanıcı ve şube kimliği; belge başına `{key, baseRev, baseBody, localBody, since, force}`; yanıtı beklenen yazma "gönderildi" diye işaretlenir). Her değişiklikten en geç 250 ms sonra, ayrıca `pagehide`/`beforeunload`/sekme gizlenince yazılır; bekleyen kalmayınca silinir. Aynı kullanıcı aynı şubeyi açınca `base`, yerel hal ve `dirty` ilk çekmeden ÖNCE geri yüklenir; böylece normal `merge3` sunucudaki değişikliklerle birleştirir. "Gönderildi" işaretli yazmada sunucu o sürümün ötesine geçmişse yazmanın ulaştığı kabul edilir. Aynı kullanıcı ve şube için yalnızca bir sekme saklar (Web Locks); kapanan sekmenin kopyasını açık kalan sekme devralır. Oturum kendiliğinden düşerse bekleyenler ölü oturumla gönderilmez; aynı kullanıcı yeniden girince gönderilir. Demo modunda saklanmaz. Mac'te karşılığı `esitleme.json`'daki `base`/`dirty`'dir.

**Yerel rol denetimi (Mac).** Personel hesabıyla tanım belgelerine (items, products, settings, employees, orders) ya da yerelde kapatılmış bir güne dokunan işlem uygulanmadan bütünüyle reddedilir (web'deki `applyMany` / `dayChangeAllowed` ile aynı). Yarısı gönderilip yarısı sunucuca geri alınan işlem veriyi bozardı (ör. teslim alma: Gelen gider, sipariş açık kalır). Hiç kalem sayılmamış gün kapatılamaz (Gün menüsü ⌘L dahil); personel günü onaydan sonra kapatır, çünkü kilidi yalnızca patron veya müdür açabilir.

**Rol güncellemesi (Mac).** Patronun yetki değişikliği oturumu kapatmaz. Mac şube listesini (`envanter_my_workspaces`) açılıştan sonraki ilk eşitleme turunda, en geç 5 dakikada bir, uygulama öne geldiğinde ve bir yazması yetki yüzünden reddedildiğinde yeniden okur. Rol ya da şube adı değiştiyse turun başında güncellenir: önce eski rolün yazamadığı, `dirty` olmayan ve `base`'den ayrışmış tanım belgeleri `base`'e döner (terfide eski tanımlar gönderilmez), sonra rol ve ad değişir. Bekleyen (`dirty`) değişikliklere dokunulmaz; personele alınan müdürün bekleyen tanım değişikliği gönderimde `42501` ile reddedilir ve sunucudaki hal geri gelir. Şube listede yoksa (şubeden çıkarılma) bir şey değişmez.

**İlk bağlantı (Mac).** Bulut boşsa her şey yüklenir. Yerel veri yalnızca varsayılan (seed) haldeyse buluttan indirilir. İkisi de doluysa kullanıcıya sorulur: "Buluttakini İndir" (yerel yedek alınır) ya da "Bu Mac'tekini Yükle". Personel yüklerken tanım belgelerinde sunucudaki hal geçerli olur; personel Mac'i ayrıca her eşitlemede `dirty` olmayan ve `base`'den ayrışmış tanım belgelerini `base`'e döndürür (rol müdüre yükselince eski tanımlar yerel değişiklik sanılıp gönderilmez).

**Şube değişimi (Mac).** Başka bir şubeyle eşleşmiş Mac'in yerel verisi o şubenindir. Verisi olan şubeye geçişte o şubenin verisi indirilir (yerel yedek alınır). Boş şubeye geçişte hiçbir şey kendiliğinden yüklenmez; sorulur: "Yalnızca tanımları kopyala" (items, products, settings; şube adı yeni şubenin adı olur, günler, personel ve siparişler kopyalanmaz) ya da "Her şeyi kopyala". Vazgeçilirse önceki şubeyle eşitleme sürer.

**Çıkış (Mac).** Çıkış yalnızca oturum anahtarlarını siler; şube eşleşmesi (`base`, `lastRev`, `dirty`, rol) korunur ve eşitleme durur. Aynı sunucuda yeniden girişte (başka hesapla da) aynı şube seçilirse kaldığı yerden devam edilir: `base`'den ayrışan belgeler `dirty` olur ve olağan çek/gönder (merge3) ile gönderilir; arada web panelinde yapılan değişiklikler ezilmez. Eşleşme yalnızca "Bu Mac'i şubeden ayır" ile silinir.

**Ayrışma (Mac).** Açılışta ve yeniden girişte `base`'den ayrışan belgeler aranırken, `base` gövdesi Mac'çe çözülemeyen belge (ileriki sürümün biçimi, bozuk alan) ayrışmış sayılmaz: kullanıcı değiştirmedikçe üzerine yazılmaz.

**Kayıt sırası (Mac).** Eşitleme yerel veriyi değiştirdiyse önce veri dosyası, sonra eşitleme durumu (`esitleme.json`) yazılır; veri yazılamazsa durum da yazılmaz. Böylece ilerlemiş `base` diskte eski veriyle kalmaz (yeniden açılışta eski belgeler güncel `base.rev` ile çakışmasız gönderilip web'deki değişikliği ezerdi). Veri ve durum kayıtlarının hepsi aynı seri kuyrukta, arka planda yazılır: arayüz kodlamayı beklemez ve sonradan kuyruğa giren bir durum kaydı, bekleyen veri yazmasının önüne geçemez.

### merge3 (üç yollu birleştirme)

Girdiler JSON değerleridir: `base`, `local`, `remote`. Herhangi biri yok (`undefined`) olabilir.

1. `local == base` → `remote`
2. `remote == base` → `local`
3. `local == remote` → `local`
4. Üçü de **nesne** ise (`base` yoksa `{}` sayılır): anahtarların birleşimi için özyinelemeli `merge3(base[k], local[k], remote[k])`. Sonuç `undefined` ise anahtar yazılmaz.
5. `local` ve `remote` **kimlikli diziler** ise birleştirme kimliğe göre yapılır. Kimlikli dizi: tüm elemanlar `"id"` (ya da `"code"`) metin alanı olan nesnelerdir.
   - Her kimlik için `merge3(base[id], local[id], remote[id])` alınır.
   - Sıra: önce `local` sırası, sonra yalnızca `remote`'ta yeni olanlar `remote` sırasıyla eklenir.
   - Sonucu `undefined` olan eleman (bir tarafta silinmiş, diğerinde değişmemiş) çıkarılır.
6. Diğer her durumda (sayı, metin, kimliksiz dizi, tip farkı) **yerel kazanır** → `local`.

Eşitlik, JSON değerlerinin derin eşitliğidir: sayılar sayı olarak, nesnelerde anahtar sırası önemsiz. Boş dizi kimlikli dizi sayılır (silinen son eleman `[]` ile birleşir; bkz. §1 "Elle zayi"). Test vektörleri `docs/merge3-vectors.json` dosyasındadır (Mac `Tests/EnvanterCoreTests/Fixtures/` ve web `test/fixtures/` altında aynı içerik). İki istemci de bu vektörlerin tamamını geçmelidir.

## 4. Hesap motoru eşliği

Web paneli, Mac uygulamasının hesaplarını (fiili tüketim, fark, tolerans, fazla çıkış, kritik seviye, dönem özeti, kalem analizi, sipariş önerisi, takip şeridi) TypeScript'te aynen uygular. Eşlik testle korunur:

```
EnvanterTool demo --data-dir D --date 2026-08-31 --days 35
EnvanterTool metrics --data-dir D --date 2026-08-31 --from 2026-08-01 --to 2026-08-31 > metrics.json
```

`metrics.json` ve demo verisi (`envanter-verisi.json`) web deposunda test fikstürü olarak tutulur. TS motoru aynı sonuçları üretmelidir (±0,01 tolerans). Alanlar:

- kök: `date, from, to, calc, overview, summary, period, daily, orders, trend, estimates, thresholds`
- `calc[]`: `itemID, opening, openingIsAuto, incoming, transferIn, transferOut, closing, sold, waste, actual, diff, severity, belowMinimum, openingSource, openingBaseDate, carriedNet, carriedDays, isBaseline, openingJump, manualWaste`
- `overview`: `itemCount, countedItems, hasSales, salesLines, unknownLines, problemItems, shortageItems, belowMinimumItems, isLocked, isFullyCounted, hasNotableProblems, hasSignificantProblems`
- `summary[]`: `itemID, daysCounted, firstOpening, lastClosing, incoming, transferIn, transferOut, sold, waste, actual, diff, shortageQty, shortageDays, openingAdjust`
- `period`: `days, countedDays, salesDays`
- `daily[]`: `date, countedItems, problemItems, shortageItems, belowMinimumItems, hasSales, isLocked`
- `orders[]`: `itemID, stock, countedStock, stockDate, onOrder, dailyUsage, sampleDays, daysOfCover, target, suggested`
- `trend[]` (14 gün): `date, countedItems, problemItems, shortageItems`
- `estimates[]` (`--date` günü, aktif kalemler, dayanağı olanlar): `itemID, stock, baseDate, counted, below`
- `thresholds[]` (`--date` dahil son 28 gün): `itemID, tolerance, countedDays, minStock, dailyUsage, usageDays`

Kök yalnızca yeni alanlarla genişletilir; mevcut alanların adı değişmez. Demo verisi her günü saydığından devir kuralları eski sonuçları değiştirmez. Demo verisinde 26.08'de (Dondurucu arızası) Patates için elle 2 kg zayi vardır (`demo-zayi-1`): o günün ve dönem özetinin Patates zayisi ve farkı buna göre.

### Açılış devri (sayılmayan günler) ve ilk sayım

Swift `Engine` ve TS `Engine` aynı kuralı uygular; ortak test vektörleri `carry-vectors.json` (Mac `Tests/EnvanterCoreTests/Fixtures/`, web `test/fixtures/`, aynı içerik). Veri değişmez: hepsi türetilmiş değerdir.

- **Günün hareketi:** `net(gün)[kalem] = Gelen + Gelen transfer − Giden transfer − Satılan − Zayi`. Satılan / Zayi `calc` ile aynı kaynaktan (satış dökümü; döküm yoksa Excel'den gelen `legacySold/legacyWaste`; Zayi'ye elle girilen zayi eklenir).
- **Dayanak:** `D` gününden önceki en yakın gün; kapanışı varsa (`closing`) o kapanış, kapanışı yok ama elle açılışı varsa (`manualOpening`) o açılış. Dayanak `D`'den **31 günden** (`Engine.carryMaxDays` / `CARRY_MAX_DAYS`) eskiyse geçersizdir.
- **Tahmini açılış:** `dayanak değeri + Σ net(d)` (dayanak < d < D; elle açılışta dayanak gününün kendi hareketi de eklenir). `carriedDays` = net hareketi sıfırdan farklı yürünen gün sayısı. Sınırlanmaz: eksi tahmin girilmemiş Gelen işaretidir.
- **Satır:** `opening = elle açılış ?? tahmin ?? 0`. `openingSource`: `manual` (elle), `closing` (tahmin var, `carriedDays = 0` ve dayanak kapanış), `carried` (aksi halde), `none` (dayanak yok ya da eski). `openingBaseDate` dayanağın günü (eskiyse de yazılır), `carriedNet/carriedDays` yalnızca `closing/carried` iken dolu. `openingIsAuto = elle açılış yok`.
- **İlk sayım (`isBaseline`):** kapanış var, elle açılış yok ve geçerli dayanak yok → `actual`, `diff`, `severity` boş; satır sayılmış sayılır (`isCounted`), kritik seviye kapanışa göre. Sorunlu sayılmaz. Açılış'a 0 yazılırsa normal hesaplanır.
- **Açılış sıçraması:** elle açılış ve geçerli tahmin varsa `openingJump = elle açılış − tahmin` (Excel'den aktarılan, `importedFrom` taşıyan günlerde boş). `|sıçrama|` toleransı aşarsa Günlük Sayım'daki "Sorunlu" filtresine girer ve Fark ipucuna eklenir; `DayOverview.problemItems` değişmez.
- **Dönem özeti:** sayılmış (ilk sayım hariç) günlere ek olarak, dönem içinde kendisinden sonra gelen ilk sayımın **geçerli dayanağından** sonraki sayılmayan günler eklenir: gelen, transfer, satılan, zayi toplanır ve fiili tüketime `satılan + zayi` eklenir (`Σfark = Σsatılan + Σzayi − Σfiili` korunur). Geçerli dayanak: sayımın açılışı `closing/carried` ise `openingBaseDate`, elle (`manual`) ise 31 gün içindeki tahminin dayanağı; `none` (ilk sayım) devralmaz. Yani hareketleri birbirini götüren (net 0) günler ve elle açılışlı sayımdan önceki günler de girer (açılış farkı `openingAdjust`'ta); dayanak 31 günden eskiyse girmez. `firstOpening` ilk sayılan ya da devredilen günün açılışıdır; `daysCounted`, `daily`, fazla çıkış alanları yalnızca sayılan günlerdendir. `openingAdjust` = dönemdeki açılış sıçramalarının toplamı.
- **Sipariş önerisi:** `estimate = stockEstimate(kalem, D)` (aşağıda); `stock` = o gün sayıldıysa kapanış, değilse tahmin, sıfırın altına inmez (elle açılışa dayanan tahmin de). Dayanak yok ya da eskiyse `estimate` ve `stock` boş (stok bilinmiyor). `stockDate/countedStock` son sayımdır (değişmedi). "Mevcut stok" hücresi: değer ("18", "≈ 25", "—"), not ("sayım 28.08 + hareket", "açılış 02.08", "sayım 01.06 · 62 gün önce") ve ipucu (Stok Kalemleri'ndeki tahmin metni + "≈ N"; eskiyse "Son sayım N gün önce (…); stok bilinmiyor, öneri stok 0 kabul edilerek hesaplanır"). Günlük tüketim örnekleri değişmedi (sayılan günün fiilisi; ilk sayım örnek değildir): seyrek sayılan kalemde fiili artık yalnızca o günü kapsar.
- **Tahmini stok:** `stockEstimate(kalem, D)`: `D`'de sayıldıysa kapanış (`counted`), değilse `tahmini açılış(D + 1)` (sınırlanmaz); dayanak yoksa yok. `below = minStock > 0 && stock < minStock`. Genel Bakış "Kritik seviye altı" kartı: sayım varsa sayılanlar ("+N tahmini (sayılmayan)"), yoksa tahmini altta kalanlar ("tahmini · sayım girilmedi").
- **Hareketsizleri Doldur:** kapatılmış günde (`locked`) ve günün satış verisi yokken (`noSales`) yapılmaz. Yalnızca sayılmamış, hiç hareketi olmayan (gelen, transfer, satış, zayi — elle girilen zayi dahil), açılışı > 0 ve açılışı `closing` ya da `manual` olan satırlara `kapanış = açılış` yazılır; tahmini (devreden) açılış sayım yerine geçmez.
- **Metinler** (açılış ipucu, "≈ 25", "İlk sayım", devreden günler, tahmini stok, Sipariş'teki mevcut stok) iki istemcide aynıdır: Swift `OpeningText` / `StockEstimateText` / `OrderStockText`, TS `src/lib/engine/stockText.ts`.

### Eşik önerileri ve kurulum listesi

Ortak test vektörleri `threshold-vectors.json`.

- `thresholdSuggestions(D, 28)`: pencere `D` dahil son 28 günün kaydı olan günleri. **Tolerans** = sayılmış günlerin (ilk sayım hariç) `|fark|` değerlerinin %80'lik dilimi: artan sırada `⌈0,8·n⌉`. değer (tam sayıyla `(4n + 4) / 5`), en az 7 gün; adet tam sayıya, kg 0,01'e yukarı yuvarlanır, en az bir adım. **Kritik seviye** = aynı pencereyle sipariş önerisinin günlük tüketimi × 1,5; en az 7 örnek gün ve tüketim > 0; adet tam sayıya, kg 0,1'e yukarı. Yalnızca en az bir önerisi olan aktif kalemler döner.
- "Eşik önerileri" penceresi (patron / müdür) yalnızca farklı olan alanları listeler; tanımsız alanlar önceden seçilidir, elle girilmiş değerler yalnızca işaretlenirse değişir.
- **Kurulum listesi** (Genel Bakış, patron / müdür, tamamlanınca gizlenir; "Gizle" tercihi yalnızca o cihazda): toleransı > 0 ve kritik seviyesi > 0 aktif kalem sayısı, son 28 günde reçetesi tanımsız satılan farklı ürün kodu, mağaza bilgisayarı bağlantısı (web: bağlı bilgisayar ya da bilgisayardan gelen veri; Mac: web paneline bağlı).

**Takip şeridi** (iki istemcide aynı): `hasNotableProblems = problemItems > 0 && problemItems × 10 ≥ countedItems`, `hasSignificantProblems = problemItems > 0 && problemItems × 5 ≥ countedItems`. Sayım ve satış yok → boş ("Veri yok"); sayım yok → "Yalnızca satış"; belirgin → kırmızı ("Sayılanların %20'sinde fark"); dikkat ya da eksik sayım → sarı ("Eksik sayım ya da sayılanların %10'unda fark"); diğer → yeşil ("Sayım tam, fark az").
