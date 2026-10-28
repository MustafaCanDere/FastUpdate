# FastUpdate

**Ücretsiz, açık kaynak ve reklamsız sürücü ve program güncelleyici.** Driver Booster benzeri bir araçtır ama hiçbir ücretli özellik, reklam ya da üçüncü taraf sürücü sunucusu kullanmaz. Her şey Microsoft'un ve donanım üreticilerinin resmi kaynaklarından gelir.

[![Test ve Derleme](https://github.com/MustafaCanDere/FastUpdate/actions/workflows/build.yml/badge.svg)](https://github.com/MustafaCanDere/FastUpdate/actions/workflows/build.yml)

![FastUpdate genel bakış](https://raw.githubusercontent.com/MustafaCanDere/FastUpdate/screenshots/screenshot-home.png)

<details><summary>Diğer ekranlar</summary>

![Sürücüler](https://raw.githubusercontent.com/MustafaCanDere/FastUpdate/screenshots/screenshot-drivers.png)
![Araçlar ve ayarlar](https://raw.githubusercontent.com/MustafaCanDere/FastUpdate/screenshots/screenshot-tools.png)

</details>

## İndir

**[Son sürümü indir (Releases)](https://github.com/MustafaCanDere/FastUpdate/releases/latest)** ve `FastUpdate.exe` dosyasını çalıştır. Kurulum gerekmez.

> Program imzasız olduğu için Windows SmartScreen "Bilinmeyen yayımcı" uyarısı gösterebilir. **Ek bilgi > Yine de çalıştır** ile açabilirsin. Kaynak kodun tamamı bu depodadır.

Program kendi penceresinde açılır, terminal penceresi görünmez. Alternatif olarak depoyu indirip `FastUpdate.bat` dosyasına çift tıklayabilirsin.

## Özellikler

| Sekme / Araç | Ne yapar | Kaynak |
|---|---|---|
| **Sürücüler** | Güncellemesi olan sürücüleri, kurulu ve yeni sürümüyle listeler, tek tıkla kurar. İsteğe bağlı sürücüler dahildir. | Windows Update |
| **Sorunlu cihazlar** | Sürücüsü eksik veya hata veren cihazları (Aygıt Yöneticisi'ndeki sarı ünlemliler) gösterir. | Windows |
| **Donanım** | Ekran kartı, yonga seti, Wi-Fi, ses, Bluetooth, depolama ve kamera sürücülerinin sürümünü, tarihini ve yaşını gösterir. 3 yıldan eski olanları işaretler. | Windows |
| **Üretici araçları** | NVIDIA, AMD veya Intel donanımı varsa üreticinin ücretsiz resmi aracını kurar ya da günceller. En yeni oyun ve yonga seti sürücüleri buradan gelir. | NVIDIA App, AMD Adrenalin, Intel DSA |
| **Programlar** | Chrome, Firefox, 7-Zip, VLC, Discord, Steam, Visual C++ gibi programlardan güncellemesi olanları sessizce günceller. | winget |
| **Windows** | Bekleyen Windows güncellemelerini (güvenlik, .NET, Defender vb.) listeler ve kurar. | Windows Update |
| **Güvenlik** | Kurulumdan önce otomatik sistem geri yükleme noktası oluşturur. | Windows |
| **Sürücü yedekleme** | Kurulu tüm üçüncü taraf sürücüleri bir klasöre yedekler ve gerekirse geri yükler. | DISM / pnputil |
| **Yok sayma listesi** | İstemediğin güncellemeleri bir daha gösterilmeyecek şekilde gizler. | |
| **HTML rapor** | Sistem bilgisi ve tüm tarama sonuçlarını paylaşılabilir bir rapora kaydeder. | |
| **Otomatik çalıştırma** | Her pazar otomatik tarama veya sessiz güncelleme ayarlar. | Görev Zamanlayıcı |
| **Arama** | Tüm sekmelerde ad, kimlik, üretici ve durumda arar. | |

## Kullanım

1. Programı aç, yönetici izni sorulunca **Evet** de.
2. **Taramayı Başlat**'a tıkla. Tarama internet hızına göre 1-3 dakika sürer.
3. Sekmelerde güncellemek istediklerini işaretle ve **Seçilenleri Güncelle**'ye tıkla.
4. Yeniden başlatma gerekirse program sorar.

En yeni ekran kartı sürücüsü için: **Donanım** sekmesinde üretici aracını seç, güncelle, sonra aracı Başlat menüsünden açıp sürücüyü oradan kur.

### Komut satırı

```powershell
FastUpdate.exe -Scan                       # Açılır açılmaz taramaya başlar
FastUpdate.exe -Silent                     # Arayüzsüz, tüm sürücü ve programları günceller
FastUpdate.exe -ReportOnly                 # Sadece tarar, masaüstüne HTML rapor kaydeder
FastUpdate.exe -ReportOnly -ReportPath C:\rapor.html
```

`.exe` yerine `FastUpdate.ps1` de aynı parametrelerle çalışır.

## Gereksinimler

- Windows 10 (1809 ve sonrası) veya Windows 11
- İnternet bağlantısı
- Program güncellemeleri için winget. Windows 10/11'de hazır gelir, yoksa FastUpdate seni Microsoft Store'daki ücretsiz **Uygulama Yükleyici** sayfasına yönlendirir.

## Güvenlik ve gizlilik

- Sürücüler sekmesindeki her sürücü Microsoft tarafından imzalanmış ve onaylanmıştır.
- Program hiçbir veri toplamaz. Microsoft, winget ve seçtiğin üretici sunucuları dışında hiçbir yere bağlanmaz.
- Ayarlar ve günlükler `%APPDATA%\FastUpdate` klasöründe tutulur.

## Geliştirme

Tek dosyalık bir Windows PowerShell 5.1 + WPF uygulamasıdır.

```powershell
.\tests\Test-FastUpdate.ps1          # Birim testleri
```

Her `main` gönderiminde GitHub Actions, programı gerçek bir Windows makinesinde test eder, örnek bir tarama raporu üretir ve `.exe` dosyasını derler. `FastUpdate.ps1` içindeki `$AppVersion` artırılıp `main`'e gönderildiğinde o sürüm `.exe` ile birlikte Releases sayfasında otomatik yayınlanır.

## Lisans

[MIT](LICENSE)
