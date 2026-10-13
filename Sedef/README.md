# Sedef: iPad için 120 Hz GeForce NOW tarayıcısı

Sedef, tek bir iş için yapılmış bir tarayıcı: **GeForce NOW'u (play.geforcenow.com) iPad Pro'nun 120 Hz ProMotion ekranında 120 FPS akışla oynatmak.** Safari'nin koyduğu sınırları (60 FPS, 1600×1200, yalnızca H.264) kaldırır. Bu fikir CloudGear'dakine benzer; Sedef ücretsiz ve açık kaynaklı.

> Adı, Renault Toros'un rengi olan *Sedef Kırmızı*dan geliyor. İkonu da o renkte. 🙂

---

## 1. Safari'de neden 60 FPS'te kalıyor? (Temelden açıklama)

60 FPS sınırı tek bir yerden gelmiyor. Üç ayrı katman var ve üçünün de açılması gerekiyor:

| Katman | Sınırı koyan | Sedef'in çözümü |
|---|---|---|
| **1. Sunucuya giden istek** | GeForce NOW'un web sayfası, iPad'de çalıştığını anlayınca sunucudan **60 FPS** ister. | İstek iPad'den çıkmadan önce içindeki `framesPerSecond` alanını **120** yapar. |
| **2. Kimlik** | Sayfa, tarayıcının iPad/Safari olduğunu `userAgent`, dokunmatik nokta sayısı gibi işaretlerden anlar. | Tarayıcı kendini **Windows PC'deki Chrome** olarak tanıtır. Sunucuya da `nv-device-os: WINDOWS` bilgisi gider. |
| **3. Ekran** | ProMotion ekran, içerik az değişince pil için kendini 60 Hz veya altına düşürür. WebKit de sayfa çizimini varsayılan olarak 60 Hz'e yakın tutar. | Uygulama paneli sürekli **120 Hz**'de tutar (`CADisplayLink`). WebKit'in "60 FPS'e yakın çiz" ayarını da kapatır. |

**Benzetme:** Restoranda garson (GFN sayfası) iPad'le geldiğini görünce sipariş fişine "60" yazıyor. Sedef, fiş mutfağa (NVIDIA sunucusu) gitmeden önce onu "120" yapıyor. Ama mutfak yine de **üyelik kartına** bakıyor: paketin 120 FPS'e izin vermiyorsa sunucu 60 gönderir. Yani Sedef sınırı kaldırır, ama paketinin hakkı olmayan bir şeyi veremez.

### İstek gerçekte neye benziyor?

GeForce NOW bir oyun başlatırken `https://<bölge>.nvidiagrid.net/v2/session` adresine şöyle bir JSON gönderir (kısaltılmış hali):

```json
{
  "sessionRequestData": {
    "clientRequestMonitorSettings": [
      { "widthInPixels": 1600, "heightInPixels": 1200, "framesPerSecond": 60 }
    ]
  }
}
```

Sedef, sayfanın `fetch` ve `XMLHttpRequest` fonksiyonlarını sarar ve bu istek giderken `framesPerSecond` değerini 120 yapar. İstersen çözünürlüğü de değiştirir. Başka hiçbir isteğe dokunmaz. Aynı yöntemi masaüstünde [GeForce Infinity](https://github.com/AstralVixen/GeForce-Infinity) (MIT lisanslı) ve [bu mitmproxy betiği](https://gist.github.com/a9udn9u/85e0c8e863db85c5b62320766bd7b2e9) de kullanıyor. Sedef bunu iPad'de, sayfanın içinden yapıyor.

---

## 2. Gereksinimler

- **iPad Pro** (ProMotion ekranlı; M5 dahil). iPadOS 17 veya üstü.
- **GeForce NOW üyeliği:** 120 FPS'i sunucu ancak paketin izin veriyorsa gönderir. Ultimate pakette kesin var. Diğer paketlerin güncel sınırlarını NVIDIA'nın üyelik sayfasından kontrol et.
- **İnternet:** 5 GHz Wi-Fi ya da USB-C Ethernet adaptörü. 1440p/120 için en az ~35 Mbps.
- **Pil ayarları:** Düşük Güç Modu kapalı olmalı. *Ayarlar ▸ Erişilebilirlik ▸ Hareket ▸ Kare Hızını Sınırla* da kapalı olmalı, yoksa iPad 60 Hz'e kilitlenir.

---

## 3. Kurulum

### Yol A: Swift Playgrounds (Mac gerekmez, ücretsiz) ✅ önerilen

1. App Store'dan **Swift Playgrounds**'u indir (Apple'ın ücretsiz uygulaması).
2. `Sedef.swiftpm` klasörünü iPad'e al:
   - GitHub'da depo sayfasında **Code ▸ Download ZIP**'e bas. **Dosyalar** uygulamasında zip'e dokununca açılır.
   - Ya da sana gönderilen `Sedef.swiftpm.zip` dosyasını Dosyalar'da açarak.
3. Dosyalar'da **`Sedef/Sedef.swiftpm`** öğesine dokun. Swift Playgrounds'ta açılır.
4. Sağ üstteki **▶︎ (Çalıştır)** düğmesine bas, sonra uygulamayı tam ekrana al.

Not: Playgrounds'ta yapılan uygulama ana ekrana ayrı bir simge olarak kurulmaz, Playgrounds'un içinden çalışır. Her seferinde Playgrounds'u açıp ▶︎'ye basman yeterli.

### Yol B: IPA dosyası + yan yükleme (ana ekranda gerçek uygulama)

1. GitHub'da depo ▸ **Actions** ▸ **Sedef** iş akışı ▸ son başarılı çalıştırma ▸ **Artifacts ▸ Sedef-ipa**. İçinden `Sedef.ipa` çıkar.
2. Bir bilgisayarda **Sideloadly** ya da **AltStore/SideStore** ile kendi Apple ID'nle imzalayıp iPad'e yükle.
3. iPad'de **Ayarlar ▸ Gizlilik ve Güvenlik ▸ Geliştirici Modu**'nu aç. **Ayarlar ▸ Genel ▸ VPN ve Cihaz Yönetimi**'nden kendi Apple ID'ne güven.
4. Ücretsiz Apple ID ile imzalanan uygulamalar **7 günde bir** yeniden imzalanmalı. AltStore/SideStore bunu otomatik yapabilir.

Mac'in varsa: `brew install xcodegen && cd Sedef/Xcode && xcodegen generate && open Sedef.xcodeproj`. Sonra Xcode'da kendi "Personal Team"ini seçip iPad'e doğrudan yükle.

---

## 4. Kullanım

1. Uygulama açılınca GeForce NOW gelir. NVIDIA hesabınla giriş yap (giriş pencereleri ayrı bir sayfa olarak açılır).
2. GFN'nin kendi ayarlarında da kare hızı olarak 120'yi seç (seçenek görünüyorsa).
3. Bir oyun başlat. Altta şu bildirim çıkar:
   **"GFN'den 2560×1440 @ 120 FPS istendi (site 60 istiyordu)"**. Bu, isteğin değiştirildiği anlamına gelir.
4. Sağ üstteki **istatistik göstergesine (HUD)** bak:

```
Ekran 120 Hz
Akış 120 fps · ekranda 119 · 2560×1440 · H264
41.8 Mbps · ping 17 ms
İstek 2560×1440 @ 120
```

| Satır | Anlamı |
|---|---|
| **Ekran 120 Hz** | iPad'in paneli şu an gerçekten 120 Hz'de yenileniyor (ölçülen değer). |
| **Akış 120 fps** | Sunucudan saniyede 120 kare geliyor ve çözülüyor. **Asıl kanıt bu.** |
| **ekranda 119** | Bunlardan kaçı gerçekten ekrana çizildi. |
| **2560×1440 · H264** | Gelen görüntünün çözünürlüğü ve kodeği. |
| **Mbps / ping** | Bant genişliği ve gecikme. |

### Menü ve kısayollar

- **Köşedeki ⚙︎ düğmesi:** Ayarlar, Yenile, Geri, Ana sayfa, HUD aç/kapat. Birkaç saniye sonra soluklaşır, oyunu kapatmaz.
- **Üç parmakla basılı tut:** Ayarlar açılır. Menü düğmesini gizlediysen bu yolla geri gelirsin.
- Klavyeyle: **⌘ ,** ayarlar · **⇧⌘ R** yenile · **⇧⌘ I** istatistikler.

---

## 5. Ayarlar

| Ayar | Varsayılan | Açıklama |
|---|---|---|
| Kare hızı | **120 FPS** | Oturum isteğine yazılan FPS. "GFN'ye bırak" seçilirse hiç değiştirilmez. |
| Çözünürlük | Otomatik | GFN'nin seçtiği kalır. İstersen 2560×1440, 2048×1536 (iPad'in 4:3 oranı) gibi bir değer zorlayabilirsin. |
| Tarayıcı kimliği | **Windows PC · Chrome** | Sınırları kaldıran ayar. Sorun olursa "Mac · Safari"yi dene. |
| Sunucuya Windows olarak bildir | Açık | `nv-device-os: WINDOWS` başlığı. |
| Ekranı 120 Hz'de tut | Açık | ProMotion'ı en yüksek hızda tutar. Biraz daha fazla pil harcar. |
| WebKit 60 FPS sınırını kaldır | Açık | Safari'deki *"Prefer Page Rendering Updates near 60fps"* anahtarının aynısı. |
| H.265 / AV1 kodekleri | Kapalı | Deneysel. Aynı bit hızında daha iyi görüntü verebilir. Sorun çıkarsa kapat. |

Akışla ilgili ayarlar (FPS, çözünürlük, kimlik, kodek) değişince sayfa yeniden yüklenir. Bunları oyuna girmeden önce ayarla.

---

## 6. Sorun giderme

| Belirti | Olası neden ve çözüm |
|---|---|
| Oyun başlamıyor / siyah ekran | Kimliği **Mac · Safari** yap. Olmazsa çözünürlüğü **Otomatik**, kodekleri **kapalı** yap. |
| HUD'da **Akış 60 fps** | Üyelik paketin 120'ye izin vermiyor olabilir. Ya da o oyun/sunucu 120 desteklemiyor olabilir. GFN'nin kendi ayarında 120'yi seçtiğinden emin ol. |
| HUD'da **Ekran 60 Hz** | Düşük Güç Modu açık, *Kare Hızını Sınırla* açık ya da iPad ısınmış. |
| "İstek …" satırı hiç çıkmıyor | GFN bir güncelleme ile istek biçimini değiştirmiş olabilir. Sayfayı yenile; devam ederse betiğin güncellenmesi gerekir. |
| Giriş penceresi kapanmıyor | Sağ üstteki **✕** ile kapat; giriş yine tamamlanmış olur. |
| Sitedeki bir metin kutusuna dokununca klavye açılmıyor | Sedef 1.0'daki hata; güncel paketle düzeldi. Hâlâ olursa kutunun dışına, sonra tekrar kutuya dokun. |
| **Oyunun içindeki** bir kutuya (ör. Steam girişi) dokununca klavye açılmıyor | O kutu bir web kutusu değil, yayındaki videonun parçası. Şimdilik Bluetooth/Magic Keyboard gibi fiziksel bir klavye kullan. |
| Kontrolcü görünmüyor | Sayfa açıkken kontrolcüde bir tuşa bas. Tarayıcılar kontrolcüyü ancak ilk tuşa basınca görür. |

---

## 7. Dürüst notlar ve sınırlamalar

- **Resmi değil.** NVIDIA web istemcisini değiştirirse Sedef'in istek değiştirme kısmı bozulabilir. Kullanım koşulları NVIDIA'nındır, sorumluluk kullanıcıdadır.
- **Fare kilidi (pointer lock) yok.** iPadOS'taki WebKit henüz bu özelliği desteklemiyor. Bu yüzden FPS oyunlarında fareyle kamera çevirmek düzgün çalışmaz. **Kontrolcü önerilir.** Klavye çalışır.
- **WebKit'in 60 FPS ayarı özel (private) API'dir.** Bu yüzden uygulama App Store'a uygun değil, kişisel kullanım içindir. Yeni iPadOS sürümleri bu ayarı yok sayabilir. Video akışı WebKit'te ayrı bir video katmanında gösterildiği için bu teoride 120 FPS'i engellemez. Gerçekte ne olduğunu HUD'daki **"ekranda"** değeri gösterir.
- Kod bir Mac'te derlenip gerçek bir iPad'de test edilmedi. Swift Playgrounds bir hata gösterirse hata satırını bana gönder.

---

## 8. Dosya yapısı (merak edersen)

```
Sedef/
├── Sedef.swiftpm/                ← Swift Playgrounds'ta açılan paket
│   ├── Package.swift             ← uygulama tanımı (ad, ikon, yönler)
│   ├── Info-Extra.plist          ← fare/klavye ve 120 Hz için sistem anahtarları
│   └── App/
│       ├── SedefApp.swift        ← giriş noktası, tam ekran ayarları
│       ├── BrowserViewController.swift ← WKWebView, menü, HUD, giriş pencereleri
│       ├── GFNScript.swift       ← GFN sayfasına enjekte edilen JavaScript (işin kalbi)
│       ├── DisplayRateBooster.swift    ← ekranı 120 Hz'de tutan CADisplayLink
│       ├── WebKitTweaks.swift    ← WebKit'in gizli özellik anahtarları
│       ├── KeyboardFocus.swift   ← metin kutularında ekran klavyesinin açılması
│       ├── BrowserSettings.swift ← ayarlar, kimlikler, çözünürlükler
│       ├── SettingsView.swift    ← ayarlar ekranı (SwiftUI)
│       └── Overlay.swift         ← HUD metni ve istatistik modeli
├── Xcode/project.yml             ← IPA üretmek için Xcode projesi (XcodeGen)
└── tests/gfn-script.test.mjs     ← enjekte edilen betiğin testleri (Node.js)
```

Enjekte edilen betiğin testlerini çalıştırmak için: `node --test Sedef/tests/*.test.mjs`
