# MacCleaner

RAM kullanımını gösteren, bellek sorunlarını tespit eden, diskteki çöpleri tarayıp seçtiklerini silen ve her işlemden sonra rapor tutan yerel macOS uygulaması (SwiftUI, macOS 14+).

## Kurulum

```bash
./build.sh --install --open   # derler, /Applications/MacCleaner.app olarak kurar ve açar
./build.sh                    # yalnızca dist/MacCleaner.app oluşturur
./build.sh --dmg              # ayrıca dist/MacCleaner-<sürüm>.dmg kurulum imajını oluşturur
```

Terminal Rosetta altında çalışsa bile betik yerel (arm64) derler. Uygulama yalnızca Apple Silicon Mac'lerde çalışır.

### İndirilen DMG'yi açmak

Uygulama ad-hoc imzalıdır, Apple notarizasyonundan geçmemiştir. İnternetten indirilen kopyayı ilk açışta macOS engeller. `MacCleaner.app`'i Applications'a sürükledikten sonra şunlardan birini yap:

- Uygulamayı bir kez açmayı dene, sonra Sistem Ayarları → Gizlilik ve Güvenlik → **"Yine de Aç"** düğmesine bas.
- Ya da Terminal'de: `xattr -dr com.apple.quarantine /Applications/MacCleaner.app`

## Bölümler

- **Genel Bakış:** RAM, disk, açık kalma süresi, önemli tespitler ve son rapor.
- **Bellek:** Activity Monitor ile aynı hesapla bellek dağılımı (uygulama / wired / sıkıştırılmış / önbellek), swap ve bellek baskısı. Süreçler, yardımcı süreçleri ait oldukları uygulamanın altında toplanarak listelenir. Kendi süreçlerini kapatabilir ya da zorla kapatabilirsin; sistem süreçleri korunur.
  - Tespitler: uzun süre yeniden başlatılmama, şişmiş sistem servisleri (ör. `fseventsd`), yüksek wired/swap, sahipsiz `xcdevice` ve Flutter/Dart süreçleri, Gradle/Kotlin daemon'ları, Rosetta ile çalışan uygulamalar.
  - `purge` ile dosya önbelleğini boşaltma (yönetici şifresi ister).
- **Disk Temizliği:** Tarama yapar, bulunanları kategorilere ayırır. "Güvenli" öğeler varsayılan olarak seçilir, "Dikkat" öğeleri seçilmez; her öğenin altında silinince ne olacağı yazar. Onay ekranından sonra silinir.
  - **Silinmiş uygulama kalıntıları:** Kaldırılan uygulamaların Library'de bıraktığı veriler (Application Support, Containers, Group Containers, Caches, Preferences, HTTPStorages, WebKit, Saved Application State) uygulama bazında gruplanır. Programı artık olmayan LaunchAgent'lar da bulunur.
- **Raporlar:** Her temizlikte önce/sonra ölçümleri ve öğe öğe sonuçlar kaydedilir (`~/Library/Application Support/MacCleaner/Reports`). Markdown olarak kopyalanabilir veya kaydedilebilir.

## Güvenlik kuralları

- Hiçbir şey onaysız silinmez; İndirilenler'deki dosyalar kalıcı silinmez, Çöp Kutusu'na taşınır.
- Chrome gibi Chromium tabanlı uygulamaların kod imzası kopyalarından, uygulama açıldığından beri oluşturulmuş olanlara dokunulmaz. Açılış zamanı bilinmiyorsa hepsi korunur.
- Gradle ve NDK sürümleri, taranan projelerde kullanılmıyorsa önerilir. Taranan klasörler: `~/Documents`, `~/Desktop`, `~/Developer`, `~/Projects` ve benzerleri.
- Açık olan tarayıcının önbelleği, çalışan Xcode'un DerivedData'sı ve açık emülatörün verisi "Dikkat" olarak işaretlenir ya da hiç taranmaz.
- Bir veri, şunlardan biriyle eşleşiyorsa kalıntı sayılmaz: kurulu ya da çalışan bir uygulama (eklentileri ve yardımcıları dahil), LaunchServices'in bildiği bir uygulama, aynı imza ekibinden bir uygulama (grup kapsayıcıları için), Homebrew paketleri ve komut satırı araçları. Apple verileri de kalıntı sayılmaz. Son 30 günde değişmiş veriler "hâlâ kullanılıyor" kabul edilir. Kalıntılar her zaman "Dikkat" olarak işaretlenir ve seçili gelmez.
- Boyutlar `du` ile ölçülür. APFS kopyaları veri paylaştığı için tahmin gerçek kazançtan büyük olabilir; rapor, disk ölçümüyle bulunan gerçek değeri ayrıca gösterir.

## İzinler

İlk taramada macOS Belgeler, Masaüstü ve İndirilenler klasörleri için, kalıntı taramasında da diğer uygulamaların verilerine erişim için izin isteyebilir. Çöp Kutusu'nun da taranması için Sistem Ayarları → Gizlilik ve Güvenlik → Tam Disk Erişimi'nden MacCleaner'a izin ver; bu izin diğer sorulara da gerek bırakmaz.

## Komut satırı

```bash
open /Applications/MacCleaner.app --args -section memory           # doğrudan Bellek bölümünü aç
open /Applications/MacCleaner.app --args -section cleanup -scan YES # Disk Temizliği'ni aç ve taramayı başlat
```

## Lisans

MIT. Ayrıntılar için [LICENSE](LICENSE) dosyasına bak.
