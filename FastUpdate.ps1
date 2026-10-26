<#
    FastUpdate - Ücretsiz sürücü ve program güncelleyici
    -----------------------------------------------------
    Sürücüler            : Windows Update (Microsoft'un resmi sürücü kataloğu)
    Donanım (GPU/yonga)  : NVIDIA, AMD, Intel resmi araçları
    Programlar           : winget (Microsoft'un resmi paket yöneticisi)
    Windows güncellemeleri: Windows Update

    Hiçbir üçüncü taraf sunucu, reklam veya ücretli özellik yoktur.
    Windows 10 (1809+) / Windows 11, Windows PowerShell 5.1 ile çalışır.

    Komut satırı:
      FastUpdate.ps1                 Arayüzü açar
      FastUpdate.ps1 -Scan           Arayüzü açar ve hemen taramaya başlar
      FastUpdate.ps1 -Silent         Arayüz olmadan tüm sürücü ve programları günceller
      FastUpdate.ps1 -ReportOnly [-ReportPath dosya.html]
                                     Sadece tarar ve HTML rapor kaydeder
#>
param(
    [switch]$Scan,
    [switch]$Silent,
    [switch]$ReportOnly,
    [string]$ReportPath
)

$AppVersion = '1.1.0'
$RepoUrl    = 'https://github.com/MustafaCanDere/FastUpdate'

#region Yol, ayar ve günlük
# ps2exe ile derlenmiş .exe'de $PSCommandPath boş olur
$SelfPath = if ($PSCommandPath) { $PSCommandPath } else { [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }
$IsExe    = $SelfPath -like '*.exe'

$DataDir     = Join-Path $env:APPDATA 'FastUpdate'
$LogDir      = Join-Path $DataDir 'logs'
$SettingsFile = Join-Path $DataDir 'settings.json'
New-Item -ItemType Directory -Force -Path $LogDir -ErrorAction SilentlyContinue | Out-Null
$LogFile = Join-Path $LogDir ((Get-Date -Format 'yyyy-MM-dd') + '.log')

function Write-LogFile([string]$line) {
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
}

function Get-Settings {
    $s = [pscustomobject]@{ Ignored = @(); RestorePoint = $true }
    if (Test-Path $SettingsFile) {
        try {
            $j = Get-Content $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.Ignored) { $s.Ignored = @($j.Ignored) }
            if ($null -ne $j.RestorePoint) { $s.RestorePoint = [bool]$j.RestorePoint }
        } catch {}
    }
    return $s
}
function Save-Settings($s) {
    try { $s | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8 } catch {}
}
$Settings = Get-Settings

function Get-LaunchCommand([string]$extraArgs) {
    if ($IsExe) { return @{ File = $SelfPath; Args = $extraArgs } }
    return @{ File = 'powershell.exe'
              Args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SelfPath`" $extraArgs" }
}
#endregion

#region Yönetici olarak yeniden başlat
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $passArgs = @()
    if ($Scan) { $passArgs += '-Scan' }
    if ($Silent) { $passArgs += '-Silent' }
    if ($ReportOnly) { $passArgs += '-ReportOnly' }
    if ($ReportPath) { $passArgs += "-ReportPath `"$ReportPath`"" }
    $cmd = Get-LaunchCommand ($passArgs -join ' ')
    try {
        if ($cmd.Args) { Start-Process -FilePath $cmd.File -Verb RunAs -ArgumentList $cmd.Args }
        else { Start-Process -FilePath $cmd.File -Verb RunAs }
    } catch {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show('FastUpdate sürücü kurabilmek için yönetici izni ister.', 'FastUpdate') | Out-Null
    }
    exit
}
#endregion

#region Arka plan işlerinde kullanılan ortak kod
# Bu kod her arka plan işinin başına eklenir. Arayüz nesnelerine dokunmaz;
# sadece $sync.Queue kuyruğuna mesaj yazar:  "LOG|metin"  veya  "STATUS|id|metin"
$CoreCode = @'
$ErrorActionPreference = 'Continue'

function Log([string]$m)  { $sync.Queue.Enqueue("LOG|" + (Get-Date -Format 'HH:mm:ss') + "  " + $m) }
function SetStatus([string]$id, [string]$m) { $sync.Queue.Enqueue("STATUS|$id|$m") }

function Format-Size([double]$b) {
    if ($b -le 0) { return '-' }
    if ($b -ge 1GB) { return ('{0:N1} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    return ('{0:N0} KB' -f ($b / 1KB))
}

# Harici bir komutu çalıştırır, çıktısını doğru kodlamayla okur (winget UTF-8 yazar)
function Invoke-Native([string]$File, [string[]]$Arguments, [System.Text.Encoding]$Encoding = [System.Text.Encoding]::UTF8) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = (@($Arguments) | ForEach-Object { if ("$_" -match '[\s"]') { '"' + ("$_" -replace '"', '\"') + '"' } else { "$_" } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = $Encoding
    $psi.StandardErrorEncoding = $Encoding
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $o = $p.StandardOutput.ReadToEndAsync()
        $e = $p.StandardError.ReadToEndAsync()
        $p.WaitForExit()
        return [pscustomobject]@{ Code = $p.ExitCode; Lines = @(($o.Result + "`n" + $e.Result) -split "`n") }
    } catch {
        return [pscustomobject]@{ Code = -1; Lines = @($_.Exception.Message) }
    }
}

function Get-OemEncoding {
    try { return [System.Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) }
    catch { return [System.Text.Encoding]::Default }
}

function Get-WingetPath {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # Yönetici oturumunda WindowsApps PATH'te olmayabilir
    $c = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($c) { return $c.FullName }
    $u = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path $u) { return $u }
    return $null
}

# winget çıktısındaki boş/ilerleme satırlarını ayıklar (günlüğe yazmak için)
function Select-UsefulLines([string[]]$Lines, [int]$Last = 3) {
    @($Lines | ForEach-Object { (("$_" -split "`r") | Where-Object { $_ -ne '' } | Select-Object -Last 1) } |
        Where-Object { $_ -match '\w' -and $_ -notmatch '^[\s\-\\\|/]*$' -and $_ -notmatch '[█▒]' }) | Select-Object -Last $Last
}

# winget'in tablo çıktısını sütun konumlarına göre ayrıştırır (dil bağımsız)
function ConvertFrom-WingetTable([string[]]$Lines) {
    $clean = foreach ($l in $Lines) {
        $parts = @(("$l" -split "`r") | Where-Object { $_ -ne '' })
        $x = if ($parts.Count) { $parts[-1] } else { '' }   # \r ile üzerine yazılan ilerleme satırları
        $x = $x -replace '^.*[\b]', ''                         # geri silme (\b) ile çizilen dönen çubuk
        $x.TrimEnd()
    }
    $clean = @($clean)
    $sep = -1
    for ($i = 1; $i -lt $clean.Count; $i++) { if ($clean[$i] -match '^-{10,}$') { $sep = $i; break } }
    if ($sep -lt 1) { return @() }
    $header = $clean[$sep - 1]
    $cols = @([regex]::Matches($header, '\S+') | ForEach-Object { $_.Index })
    if ($cols.Count -lt 4) { return @() }
    $result = @()
    for ($i = $sep + 1; $i -lt $clean.Count; $i++) {
        $row = $clean[$i]
        if ([string]::IsNullOrWhiteSpace($row) -or $row.Length -le $cols[3]) { break }
        $f = @()
        for ($c = 0; $c -lt $cols.Count; $c++) {
            $start = $cols[$c]
            if ($start -ge $row.Length) { $f += ''; continue }
            $len = if ($c + 1 -lt $cols.Count) { [Math]::Min($cols[$c + 1], $row.Length) - $start } else { $row.Length - $start }
            $f += $row.Substring($start, [Math]::Max(0, $len)).Trim()
        }
        if (-not $f[1] -or $f[1] -match '\s') { continue }
        $result += [pscustomobject]@{
            Name = $f[0]; Id = $f[1]; Version = $f[2]; Available = $f[3]
            Source = $(if ($cols.Count -ge 5) { $f[4] } else { 'winget' })
        }
    }
    return $result
}

function New-WuSearcher {
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'FastUpdate'
    $searcher = $session.CreateUpdateSearcher()
    $searcher.Online = $true
    $searcher.ServerSelection = 2   # doğrudan Microsoft Windows Update (WSUS/politika engelini aşar)
    return @{ Session = $session; Searcher = $searcher }
}
'@
#endregion

#region İş kodları
$ScanDriversCode = @'
$items = New-Object System.Collections.ArrayList

# Windows'un takılı donanımı yeniden algılamasını iste (eksik sürücüleri ortaya çıkarır)
[void](Invoke-Native 'pnputil.exe' @('/scan-devices') (Get-OemEncoding))

Log "Donanım ve kurulu sürücüler okunuyor..."
$installed = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue)
$entities  = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue)
$byDevice = @{}
foreach ($d in $installed) { if ($d.DeviceID) { $byDevice[[string]$d.DeviceID] = $d } }
Log ("{0} cihaz, {1} kurulu sürücü bulundu." -f $entities.Count, $installed.Count)

# Bir donanım kimliğini (HWID) taşıyan cihazı bulur
function Find-Device([string]$hw) {
    if (-not $hw) { return $null }
    foreach ($e in $entities) {
        if (@($e.HardwareID) -icontains $hw -or @($e.CompatibleID) -icontains $hw) { return $e }
    }
    return $null
}

$updatedDevices = @{}
Log "Windows Update üzerinden sürücü güncellemeleri aranıyor (isteğe bağlı sürücüler dahil, birkaç dakika sürebilir)..."
try {
    $wu = New-WuSearcher
    $res = $wu.Searcher.Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
    foreach ($u in $res.Updates) {
        $dev = Find-Device ([string]$u.DriverHardwareID)
        $curText = '-'
        if ($dev) {
            $updatedDevices[[string]$dev.PNPDeviceID] = $true
            $cur = $byDevice[[string]$dev.PNPDeviceID]
            if ($cur) {
                $curText = [string]$cur.DriverVersion
                if ($cur.DriverDate) { $curText += '  (' + ([datetime]$cur.DriverDate).ToString('dd.MM.yyyy') + ')' }
            } else { $curText = 'Sürücü yok' }
        }
        $newText = '-'
        try { $newText = ([datetime]$u.DriverVerDate).ToString('dd.MM.yyyy') + ' tarihli' } catch {}
        [void]$items.Add([pscustomobject]@{
            Kind = 'driver'; Id = $u.Identity.UpdateID; Updatable = $true
            Name = $(if ($u.DriverModel) { "$($u.DriverModel)" } else { $u.Title })
            Category = $(if ($u.DriverClass) { "$($u.DriverClass)" } else { 'Sürücü' })
            CurrentVersion = $curText; NewVersion = $newText
            Size = Format-Size $u.MaxDownloadSize
            Source = $(if ($u.DriverManufacturer) { "$($u.DriverManufacturer)" } else { 'Windows Update' })
            Status = 'Güncelleme var'
        })
    }
    Log ("Windows Update: {0} sürücü güncellemesi bulundu." -f $res.Updates.Count)
} catch {
    Log ("Windows Update araması başarısız: " + $_.Exception.Message)
    Log "Windows Update hizmetinin (wuauserv) çalıştığından ve internet bağlantısı olduğundan emin olun."
}

Log "Sorunlu / sürücüsü eksik cihazlar kontrol ediliyor..."
$problems = @($entities | Where-Object { $_.ConfigManagerErrorCode -ne 0 -and $_.ConfigManagerErrorCode -ne 22 })
foreach ($p in $problems) {
    $why = switch ($p.ConfigManagerErrorCode) {
        28 { 'Sürücü yüklü değil' }
        1  { 'Yanlış yapılandırılmış' }
        10 { 'Cihaz başlatılamıyor' }
        43 { 'Cihaz hata bildirdi' }
        default { "Hata kodu $($p.ConfigManagerErrorCode)" }
    }
    if ($updatedDevices.ContainsKey([string]$p.PNPDeviceID)) { $why += ' - Windows Update çözümü listede' }
    [void]$items.Add([pscustomobject]@{
        Kind = 'problem'; Id = [string]$p.PNPDeviceID; Updatable = $false
        Name = $(if ($p.Name) { $p.Name } else { $p.PNPDeviceID })
        Category = 'Sorunlu cihaz'; CurrentVersion = '-'; NewVersion = '-'; Size = '-'
        Source = $(if ($p.Manufacturer) { $p.Manufacturer } else { '-' })
        Status = $why
    })
}
Log ("{0} sorunlu cihaz bulundu." -f $problems.Count)

# ---- Donanım envanteri: ana donanımların sürücü sürümü ve yaşı ----
Log "Donanım sürücüleri analiz ediliyor..."
$classNames = @{ 'DISPLAY' = 'Ekran kartı'; 'NET' = 'Ağ / Wi-Fi'; 'MEDIA' = 'Ses'; 'BLUETOOTH' = 'Bluetooth'
                 'SCSIADAPTER' = 'Depolama'; 'HDC' = 'Depolama'; 'SYSTEM' = 'Yonga seti'; 'USB' = 'USB'
                 'CAMERA' = 'Kamera'; 'IMAGE' = 'Kamera'; 'BIOMETRIC' = 'Biyometrik'; 'HIDCLASS' = 'Giriş aygıtı' }
$seen = @{}
$hwCount = 0
foreach ($d in $installed) {
    $cls = ([string]$d.DeviceClass).ToUpper()
    if (-not $classNames.ContainsKey($cls) -or -not $d.DeviceName) { continue }
    if ([string]$d.DeviceID -match '^(ROOT|SWD|HTREE)\\') { continue }                  # sanal aygıtlar
    if ([string]$d.Manufacturer -match '^(Microsoft|\(Standard|\(Standart|Generic)') { continue }  # Windows'un genel sürücüleri
    if (($cls -in @('SYSTEM', 'USB', 'HIDCLASS')) -and [string]$d.Manufacturer -notmatch 'Intel|AMD|Advanced Micro|NVIDIA|Realtek|Qualcomm|MediaTek') { continue }
    $key = "$($d.DeviceName)|$($d.DriverVersion)"
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true

    $dateText = '-'; $ageText = '-'; $years = 0
    if ($d.DriverDate) {
        $dt = [datetime]$d.DriverDate
        $dateText = $dt.ToString('dd.MM.yyyy')
        $years = ((Get-Date) - $dt).TotalDays / 365.25
        $ageText = $(if ($years -lt 1) { '{0} ay' -f [int][Math]::Max(1, $years * 12) } else { '{0:N1} yıl' -f $years })
    }
    $status = 'Windows Update''e göre güncel'
    if ($years -ge 3) { $status = 'Eski - üretici aracıyla kontrol edin' }
    if ($updatedDevices.ContainsKey([string]$d.DeviceID)) { $status = 'Güncelleme var (Sürücüler sekmesinde)' }
    [void]$items.Add([pscustomobject]@{
        Kind = 'hw'; Id = "hw:" + [string]$d.DeviceID; Updatable = $false
        Name = [string]$d.DeviceName; Category = $classNames[$cls]
        CurrentVersion = [string]$d.DriverVersion; NewVersion = $dateText; Size = $ageText
        Source = [string]$d.Manufacturer; Status = $status
    })
    $hwCount++
}
Log ("{0} donanım sürücüsü analiz edildi." -f $hwCount)

# ---- Üretici araçları: Windows Update'ten daha yeni GPU/yonga seti sürücüleri için ----
$gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
$cpu  = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
$vendors = @()
if ($gpus | Where-Object { $_.PNPDeviceID -match 'VEN_10DE' }) {
    $vendors += @{ Name = 'NVIDIA App (GeForce ekran kartı sürücüsü)'; Maker = 'NVIDIA'
                   Ids = @('Nvidia.NVIDIAApp', 'Nvidia.GeForceExperience'); Url = 'https://www.nvidia.com/tr-tr/software/nvidia-app/' }
}
if (($gpus | Where-Object { $_.PNPDeviceID -match 'VEN_1002' }) -or ($cpu -and $cpu.Manufacturer -match 'AMD')) {
    $vendors += @{ Name = 'AMD Software: Adrenalin / yonga seti sürücüleri'; Maker = 'AMD'
                   Ids = @('AMD.AMDSoftwareAdrenalinEdition'); Url = 'https://www.amd.com/en/support/download/drivers.html' }
}
if (($gpus | Where-Object { $_.PNPDeviceID -match 'VEN_8086' }) -or ($cpu -and $cpu.Manufacturer -match 'Intel')) {
    $vendors += @{ Name = 'Intel Sürücü ve Destek Asistanı (grafik, Wi-Fi, Bluetooth, yonga seti)'; Maker = 'Intel'
                   Ids = @('Intel.IntelDriverAndSupportAssistant'); Url = 'https://www.intel.com.tr/content/www/tr/tr/support/detect.html' }
}

$winget = Get-WingetPath
foreach ($v in $vendors) {
    $action = "url:" + $v.Url
    $status = 'Resmi indirme sayfası açılır'
    if ($winget) {
        foreach ($wid in $v.Ids) {
            $r = Invoke-Native $winget @('list', '--id', $wid, '--exact', '--accept-source-agreements', '--disable-interactivity')
            if ($r.Code -eq 0) { $action = "upgrade:$wid"; $status = 'Kurulu - güncellenir'; break }
            $r = Invoke-Native $winget @('show', '--id', $wid, '--exact', '--accept-source-agreements', '--disable-interactivity')
            if ($r.Code -eq 0) { $action = "install:$wid"; $status = 'Ücretsiz kurulur (winget)'; break }
        }
    }
    [void]$items.Add([pscustomobject]@{
        Kind = 'vendor'; Id = $action; Updatable = $true; Name = $v.Name; Category = 'Üretici aracı'
        CurrentVersion = '-'; NewVersion = 'En yeni sürücü'; Size = '-'; Source = $v.Maker; Status = $status
    })
    Log ("Üretici aracı önerisi: {0}" -f $v.Name)
}
$sync.Result = $items
'@

$ScanAppsCode = @'
$items = New-Object System.Collections.ArrayList
$winget = Get-WingetPath
if (-not $winget) {
    Log "winget bulunamadı. Microsoft Store'dan 'Uygulama Yükleyici' (App Installer) kurun ve tekrar deneyin."
    $sync.Result = 'NOWINGET'
    return
}
Log "Programlar winget ile taranıyor..."
$list = $null

# 1) Varsa resmi PowerShell modülü (yapılandırılmış veri, en güvenilir yol)
if (Get-Module -ListAvailable -Name Microsoft.WinGet.Client) {
    try {
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
        $list = @(Get-WinGetPackage -ErrorAction Stop | Where-Object { $_.IsUpdateAvailable } | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Id = $_.Id; Version = "$($_.InstalledVersion)"
                               Available = "$(@($_.AvailableVersions)[0])"; Source = "$($_.Source)" }
        })
        Log "Microsoft.WinGet.Client modülü kullanıldı."
    } catch { $list = $null }
}

# 2) Yoksa winget komutunun çıktısını ayrıştır
if ($null -eq $list) {
    $r = Invoke-Native $winget @('upgrade', '--accept-source-agreements', '--disable-interactivity')
    $list = @(ConvertFrom-WingetTable $r.Lines)
    if ($list.Count -eq 0 -and ($r.Lines -join "`n") -notmatch '-{10,}') {
        Select-UsefulLines $r.Lines | ForEach-Object { Log "winget: $_" }
    }
}

foreach ($p in $list) {
    [void]$items.Add([pscustomobject]@{
        Kind = 'app'; Id = $p.Id; Updatable = $true; Name = $p.Name; Category = 'Program'
        CurrentVersion = $p.Version; NewVersion = $p.Available; Size = '-'
        Source = $p.Source; Status = 'Güncelleme var'
    })
}
Log ("{0} program için güncelleme bulundu." -f $items.Count)
$sync.Result = $items
'@

$ScanWindowsCode = @'
$items = New-Object System.Collections.ArrayList
Log "Windows güncellemeleri aranıyor..."
try {
    $wu = New-WuSearcher
    $res = $wu.Searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
    foreach ($u in $res.Updates) {
        $kb = @($u.KBArticleIDs)
        $cats = @(); foreach ($c in $u.Categories) { $cats += [string]$c.Name }
        [void]$items.Add([pscustomobject]@{
            Kind = 'windows'; Id = $u.Identity.UpdateID; Updatable = $true
            Name = [string]$u.Title
            Category = $(if ($cats.Count) { $cats[0] } else { 'Güncelleme' })
            CurrentVersion = $(if ($kb.Count) { 'KB' + $kb[0] } else { '-' })
            NewVersion = $(if ($u.MsrcSeverity) { [string]$u.MsrcSeverity } else { '-' })
            Size = Format-Size $u.MaxDownloadSize
            Source = 'Windows Update'
            Status = $(if ($u.AutoSelectOnWebSites) { 'Önerilen' } else { 'İsteğe bağlı' })
        })
    }
    Log ("{0} Windows güncellemesi bulundu." -f $res.Updates.Count)
} catch {
    Log ("Windows güncellemeleri aranamadı: " + $_.Exception.Message)
}
$sync.Result = $items
'@

# Windows Update üzerinden sürücü ve Windows güncellemelerini kurar
$UpdateWuCode = @'
$ids = @($jobArg.Ids)
if ($jobArg.RestorePoint) {
    Log "Sistem geri yükleme noktası oluşturuluyor..."
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description 'FastUpdate - guncelleme oncesi' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Log "Geri yükleme noktası oluşturuldu."
    } catch { Log ("Geri yükleme noktası oluşturulamadı (devam ediliyor): " + $_.Exception.Message) }
}

$wu = New-WuSearcher
$session = $wu.Session
Log "Seçilen güncellemeler Windows Update'te hazırlanıyor..."
$res = $wu.Searcher.Search("IsInstalled=0 and IsHidden=0")
$ok = 0; $fail = 0; $reboot = $false

foreach ($u in $res.Updates) {
    $id = $u.Identity.UpdateID
    if ($ids -notcontains $id) { continue }
    $name = if ($u.DriverModel) { $u.DriverModel } else { $u.Title }
    try {
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        $coll = New-Object -ComObject Microsoft.Update.UpdateColl
        [void]$coll.Add($u)

        SetStatus $id 'İndiriliyor...'
        Log "İndiriliyor: $name"
        $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll
        [void]$dl.Download()

        SetStatus $id 'Kuruluyor...'
        Log "Kuruluyor: $name"
        $inst = $session.CreateUpdateInstaller(); $inst.Updates = $coll
        $r = $inst.Install()
        $code = $r.GetUpdateResult(0).ResultCode
        if ($code -eq 2 -or $code -eq 3) {
            $ok++
            if ($r.RebootRequired) { $reboot = $true; SetStatus $id 'Kuruldu (yeniden başlatma gerekli)' }
            else { SetStatus $id 'Kuruldu' }
            Log "Başarılı: $name"
        } else {
            $fail++; SetStatus $id "Başarısız (kod $code)"
            Log "Başarısız: $name (sonuç kodu $code)"
        }
    } catch {
        $fail++; SetStatus $id 'Hata'
        Log ("Hata: $name - " + $_.Exception.Message)
    }
}
Log "Windows Update kurulumu bitti. Başarılı: $ok, başarısız: $fail."
if ($reboot) { Log "Değişikliklerin tamamlanması için bilgisayarı yeniden başlatın." }
$sync.Result = @{ Reboot = $reboot; Ok = $ok; Fail = $fail }
'@

$UpdateAppsCode = @'
$winget = Get-WingetPath
$ok = 0; $fail = 0
foreach ($id in @($jobArg.Ids)) {
    SetStatus $id 'Güncelleniyor...'
    Log "Güncelleniyor: $id"
    $r = Invoke-Native $winget @('upgrade', '--id', $id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($r.Code -eq 0) {
        $ok++; SetStatus $id 'Güncellendi'; Log "Başarılı: $id"
    } elseif ($r.Code -eq -1978335189) {
        $ok++; SetStatus $id 'Zaten güncel'; Log "Zaten güncel: $id"
    } else {
        $fail++; SetStatus $id ("Başarısız (0x{0:X8})" -f $r.Code)
        Select-UsefulLines $r.Lines | ForEach-Object { Log "   $_" }
        Log "Başarısız: $id (program açıksa kapatıp tekrar deneyin)"
    }
}
Log "Program güncellemesi bitti. Başarılı: $ok, başarısız: $fail."
$sync.Result = @{ Ok = $ok; Fail = $fail }
'@

$UpdateVendorCode = @'
$winget = Get-WingetPath
foreach ($id in @($jobArg.Ids)) {
    $kind, $target = $id -split ':', 2
    if ($kind -eq 'url') {
        SetStatus $id 'İndirme sayfası açıldı'
        Log "Üreticinin resmi sayfası açılıyor: $target"
        Start-Process $target
        continue
    }
    $verb = if ($kind -eq 'install') { 'install' } else { 'upgrade' }
    SetStatus $id $(if ($verb -eq 'install') { 'Kuruluyor...' } else { 'Güncelleniyor...' })
    Log "Üretici aracı ($verb): $target"
    $r = Invoke-Native $winget @($verb, '--id', $target, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($r.Code -eq 0 -or $r.Code -eq -1978335189 -or $r.Code -eq -1978335135) {
        SetStatus $id 'Hazır - araçtan sürücüleri güncelleyin'
        Log "$target hazır. Başlat menüsünden açıp 'Sürücüler' bölümünden en yeni sürücüyü kurun."
    } else {
        SetStatus $id ("Başarısız (0x{0:X8})" -f $r.Code)
        Select-UsefulLines $r.Lines | ForEach-Object { Log "   $_" }
    }
}
$sync.Result = $null
'@

$BackupDriversCode = @'
$dest = $jobArg.Path
Log "Üçüncü taraf sürücüler yedekleniyor: $dest"
try {
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $r = @(Export-WindowsDriver -Online -Destination $dest -ErrorAction Stop)
    Log ("{0} sürücü yedeklendi." -f $r.Count)
} catch {
    Log ("Export-WindowsDriver başarısız, pnputil deneniyor: " + $_.Exception.Message)
    $r = Invoke-Native 'pnputil.exe' @('/export-driver', '*', $dest) (Get-OemEncoding)
    Select-UsefulLines $r.Lines 2 | ForEach-Object { Log "   $_" }
    if ($r.Code -eq 0) { Log "Sürücüler yedeklendi." } else { Log "Yedekleme başarısız (kod $($r.Code))." }
}
Log "Yedeği geri yüklemek için: Araçlar > Sürücü yedeğini geri yükle."
'@

$RestoreDriversCode = @'
$src = $jobArg.Path
Log "Sürücüler yedekten kuruluyor: $src"
$r = Invoke-Native 'pnputil.exe' @('/add-driver', (Join-Path $src '*.inf'), '/subdirs', '/install') (Get-OemEncoding)
Select-UsefulLines $r.Lines 6 | ForEach-Object { Log "   $_" }
if ($r.Code -eq 0 -or $r.Code -eq 3010) { Log "Sürücü yedeği kuruldu. Yeniden başlatmanız gerekebilir." }
else { Log "Bazı sürücüler kurulamadı (kod $($r.Code))." }
'@

$RestorePointCode = @'
Log "Sistem geri yükleme noktası oluşturuluyor..."
try {
    Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
    Checkpoint-Computer -Description 'FastUpdate - elle olusturuldu' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
    Log "Geri yükleme noktası oluşturuldu."
} catch {
    Log ("Oluşturulamadı: " + $_.Exception.Message)
    Log "Not: Windows 24 saatte bir geri yükleme noktasına izin verir."
}
'@
#endregion

#region Sistem bilgisi ve rapor
function Get-SystemSummary {
    $info = [ordered]@{}
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $info['İşletim sistemi'] = "$($os.Caption) ($($os.Version))"
        $info['Bellek'] = '{0:N1} GB' -f ($os.TotalVisibleMemorySize / 1MB)
    } catch {}
    try { $info['İşlemci'] = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim() } catch {}
    try { $info['Ekran kartı'] = (@(Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name }) -join ', ') } catch {}
    try {
        $b = Get-CimInstance Win32_BaseBoard
        $info['Anakart'] = "$($b.Manufacturer) $($b.Product)".Trim()
    } catch {}
    try {
        $bios = Get-CimInstance Win32_BIOS
        $info['BIOS'] = "$($bios.SMBIOSBIOSVersion)" + $(if ($bios.ReleaseDate) { ' (' + ([datetime]$bios.ReleaseDate).ToString('dd.MM.yyyy') + ')' } else { '' })
    } catch {}
    try {
        $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
        $info['Sistem diski'] = '{0:N0} GB boş / {1:N0} GB' -f ($d.FreeSpace / 1GB), ($d.Size / 1GB)
    } catch {}
    return $info
}

function Save-HtmlReport([string]$Path, $SysInfo, $Sections) {
    $enc = { param($t) [System.Net.WebUtility]::HtmlEncode([string]$t) }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(@"
<!doctype html><html lang="tr"><head><meta charset="utf-8"><title>FastUpdate Raporu</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1b2433;background:#f3f5f9}
h1{margin:0 0 4px}h2{margin-top:28px}.muted{color:#5b6577}
table{border-collapse:collapse;width:100%;background:#fff;font-size:13px}
th,td{border-bottom:1px solid #e6eaf0;padding:6px 8px;text-align:left}th{background:#eef2f7}
.card{background:#fff;border:1px solid #d8dee8;border-radius:8px;padding:12px 16px}
</style></head><body>
<h1>FastUpdate Raporu</h1><div class="muted">$(& $enc (Get-Date -Format 'dd.MM.yyyy HH:mm')) &middot; $(& $enc $env:COMPUTERNAME) &middot; FastUpdate $AppVersion</div>
<h2>Sistem</h2><div class="card"><table>
"@)
    foreach ($k in $SysInfo.Keys) { [void]$sb.Append("<tr><th>$(& $enc $k)</th><td>$(& $enc $SysInfo[$k])</td></tr>") }
    [void]$sb.Append('</table></div>')
    foreach ($s in $Sections) {
        $rows = @($s.Items)
        [void]$sb.Append("<h2>$(& $enc $s.Title) ($($rows.Count))</h2>")
        if ($rows.Count -eq 0) { [void]$sb.Append('<p class="muted">Kayıt yok.</p>'); continue }
        [void]$sb.Append('<table><tr>')
        foreach ($c in $s.Columns) { [void]$sb.Append("<th>$(& $enc $c[1])</th>") }
        [void]$sb.Append('</tr>')
        foreach ($r in $rows) {
            [void]$sb.Append('<tr>')
            foreach ($c in $s.Columns) { [void]$sb.Append("<td>$(& $enc $r.($c[0]))</td>") }
            [void]$sb.Append('</tr>')
        }
        [void]$sb.Append('</table>')
    }
    [void]$sb.Append("<p class='muted'>$(& $enc $RepoUrl)</p></body></html>")
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
}

$ReportColumns = @{
    driver  = @(@('Name', 'Sürücü'), @('Category', 'Sınıf'), @('CurrentVersion', 'Kurulu'), @('NewVersion', 'Yeni'), @('Size', 'Boyut'), @('Source', 'Üretici'), @('Status', 'Durum'))
    hw      = @(@('Name', 'Donanım'), @('Category', 'Tür'), @('CurrentVersion', 'Sürücü sürümü'), @('NewVersion', 'Tarih'), @('Size', 'Yaşı'), @('Source', 'Üretici'), @('Status', 'Durum'))
    app     = @(@('Name', 'Program'), @('Id', 'Kimlik'), @('CurrentVersion', 'Kurulu'), @('NewVersion', 'Yeni'), @('Source', 'Kaynak'), @('Status', 'Durum'))
    windows = @(@('Name', 'Güncelleme'), @('Category', 'Kategori'), @('CurrentVersion', 'KB'), @('NewVersion', 'Önem'), @('Size', 'Boyut'), @('Status', 'Durum'))
}
#endregion

#region Komut satırı modu (-Silent / -ReportOnly)
if ($Silent -or $ReportOnly) {
    $sync = [hashtable]::Synchronized(@{ Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'; Result = $null })
    $hasConsole = $Host.Name -eq 'ConsoleHost'
    function Invoke-JobSync([string]$Code, $jobArg) {
        $sync.Result = $null
        . ([scriptblock]::Create($CoreCode + "`n" + $Code))
        $m = $null
        while ($sync.Queue.TryDequeue([ref]$m)) {
            $parts = $m -split '\|', 3
            if ($parts[0] -eq 'LOG') { Write-LogFile $parts[1]; if ($hasConsole) { Write-Host $parts[1] } }
        }
        return $sync.Result
    }
    Write-LogFile ("==== FastUpdate $AppVersion " + $(if ($Silent) { 'sessiz güncelleme' } else { 'rapor' }) + " ====")
    $ignored = @($Settings.Ignored)
    $all = @(Invoke-JobSync $ScanDriversCode $null) + @(Invoke-JobSync $ScanAppsCode $null)
    if ($ReportOnly) { $all += @(Invoke-JobSync $ScanWindowsCode $null) }
    $all = @($all | Where-Object { $_ -and $_ -isnot [string] -and $ignored -notcontains $_.Id })

    if ($ReportOnly) {
        if (-not $ReportPath) { $ReportPath = Join-Path ([Environment]::GetFolderPath('Desktop')) ('FastUpdate-Rapor-' + (Get-Date -Format 'yyyyMMdd-HHmm') + '.html') }
        Save-HtmlReport $ReportPath (Get-SystemSummary) @(
            @{ Title = 'Sürücü güncellemeleri ve sorunlu cihazlar'; Items = @($all | Where-Object { $_.Kind -in 'driver', 'problem' }); Columns = $ReportColumns.driver }
            @{ Title = 'Donanım sürücüleri'; Items = @($all | Where-Object { $_.Kind -in 'hw', 'vendor' }); Columns = $ReportColumns.hw }
            @{ Title = 'Program güncellemeleri'; Items = @($all | Where-Object { $_.Kind -eq 'app' }); Columns = $ReportColumns.app }
            @{ Title = 'Windows güncellemeleri'; Items = @($all | Where-Object { $_.Kind -eq 'windows' }); Columns = $ReportColumns.windows })
        Write-LogFile "Rapor kaydedildi: $ReportPath"
        if ($hasConsole) { Write-Host "Rapor kaydedildi: $ReportPath" }
        exit 0
    }

    $drvIds = @($all | Where-Object { $_.Kind -eq 'driver' } | ForEach-Object { $_.Id })
    $appIds = @($all | Where-Object { $_.Kind -eq 'app' } | ForEach-Object { $_.Id })
    if ($drvIds.Count) { [void](Invoke-JobSync $UpdateWuCode @{ Ids = $drvIds; RestorePoint = $Settings.RestorePoint }) }
    if ($appIds.Count) { [void](Invoke-JobSync $UpdateAppsCode @{ Ids = $appIds }) }
    Write-LogFile "Sessiz güncelleme bitti."
    exit 0
}
#endregion

#region Arayüz
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

Add-Type -Language CSharp -TypeDefinition @'
using System.ComponentModel;
public class FuItem : INotifyPropertyChanged {
    private bool _selected;
    private string _status;
    public event PropertyChangedEventHandler PropertyChanged;
    private void On(string n) { if (PropertyChanged != null) PropertyChanged(this, new PropertyChangedEventArgs(n)); }
    public bool Selected { get { return _selected; } set { _selected = value; On("Selected"); } }
    public string Status { get { return _status; } set { _status = value; On("Status"); } }
    public bool Updatable { get; set; }
    public string Kind { get; set; }
    public string Id { get; set; }
    public string Name { get; set; }
    public string Category { get; set; }
    public string CurrentVersion { get; set; }
    public string NewVersion { get; set; }
    public string Size { get; set; }
    public string Source { get; set; }
}
'@

$checkColumn = @'
            <DataGridTemplateColumn Header="" Width="34">
              <DataGridTemplateColumn.CellTemplate>
                <DataTemplate>
                  <CheckBox IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" IsEnabled="{Binding Updatable}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </DataTemplate>
              </DataGridTemplateColumn.CellTemplate>
            </DataGridTemplateColumn>
'@

$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="FastUpdate - Ücretsiz Sürücü ve Program Güncelleyici" Height="760" Width="1160" MinWidth="900" MinHeight="560"
        WindowStartupLocation="CenterScreen" Background="#F3F5F9" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#C9D1DE"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#1F6FEB"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderBrush" Value="#1F6FEB"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style TargetType="DataGrid">
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#E6EAF0"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#D8DEE8"/>
      <Setter Property="RowHeight" Value="28"/>
      <Setter Property="SelectionMode" Value="Extended"/>
    </Style>
  </Window.Resources>
  <DockPanel>
    <Menu DockPanel.Dock="Top" Background="#E9EDF3" Padding="6,2">
      <MenuItem Header="_Araçlar">
        <MenuItem Name="MnuBackup" Header="Sürücüleri yedekle..."/>
        <MenuItem Name="MnuRestoreDrv" Header="Sürücü yedeğini geri yükle..."/>
        <MenuItem Name="MnuRestorePoint" Header="Geri yükleme noktası oluştur"/>
        <Separator/>
        <MenuItem Name="MnuReport" Header="Rapor kaydet (HTML)..."/>
        <MenuItem Name="MnuLogs" Header="Günlük klasörünü aç"/>
        <Separator/>
        <MenuItem Header="Otomatik çalıştırma">
          <MenuItem Name="MnuAutoOff" Header="Kapalı" IsCheckable="True"/>
          <MenuItem Name="MnuAutoScan" Header="Her pazar tara (pencere açılır)" IsCheckable="True"/>
          <MenuItem Name="MnuAutoSilent" Header="Her pazar sessizce güncelle" IsCheckable="True"/>
        </MenuItem>
        <Separator/>
        <MenuItem Name="MnuUnignore" Header="Yok sayılanları sıfırla"/>
      </MenuItem>
      <MenuItem Header="_Yardım">
        <MenuItem Name="MnuGithub" Header="GitHub sayfası ve yeni sürümler"/>
        <MenuItem Name="MnuAbout" Header="Hakkında"/>
      </MenuItem>
    </Menu>

    <DockPanel Margin="16,12,16,16">
      <Grid DockPanel.Dock="Top" Margin="0,0,0,10">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel>
          <TextBlock Text="FastUpdate" FontSize="24" FontWeight="Bold" Foreground="#1B2433"/>
          <TextBlock Foreground="#5B6577" TextWrapping="Wrap" Text="Sürücüler Windows Update ve üreticilerin (NVIDIA, AMD, Intel) resmi araçlarıyla, programlar winget ile güncellenir. Tamamen ücretsiz ve reklamsız."/>
        </StackPanel>
        <Border Grid.Column="1" Background="White" BorderBrush="#D8DEE8" BorderThickness="1" CornerRadius="6" Padding="10,6" Margin="12,0,0,0" MaxWidth="460">
          <TextBlock Name="TxtSys" Foreground="#3A4556" FontSize="12" TextWrapping="Wrap" Text="Sistem bilgisi okunuyor..."/>
        </Border>
      </Grid>

      <DockPanel DockPanel.Dock="Top" Margin="0,0,0,10" LastChildFill="False">
        <Button Name="BtnScan" Content="Taramayı Başlat" Style="{StaticResource Primary}"/>
        <Button Name="BtnUpdate" Content="Seçilenleri Güncelle" Style="{StaticResource Primary}" Background="#1A7F37" BorderBrush="#1A7F37" IsEnabled="False"/>
        <Button Name="BtnSelAll" Content="Tümünü Seç"/>
        <Button Name="BtnSelNone" Content="Seçimi Kaldır"/>
        <Button Name="BtnIgnore" Content="Seçilenleri Yok Say" ToolTip="Seçilen öğeler sonraki taramalarda gösterilmez"/>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
          <TextBlock Text="Ara:" VerticalAlignment="Center" Margin="0,0,6,0" Foreground="#5B6577"/>
          <TextBox Name="TxtSearch" Width="200" Padding="4,4" VerticalContentAlignment="Center"/>
        </StackPanel>
      </DockPanel>

      <CheckBox Name="ChkRestore" DockPanel.Dock="Top" Margin="0,0,0,8" Content="Sürücü ve Windows güncellemelerinden önce sistem geri yükleme noktası oluştur"/>

      <Grid DockPanel.Dock="Bottom" Margin="0,10,0,0">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="140"/></Grid.RowDefinitions>
        <DockPanel Grid.Row="0" Margin="0,0,0,6">
          <ProgressBar Name="Progress" DockPanel.Dock="Right" Width="220" Height="10" Visibility="Hidden"/>
          <TextBlock Name="TxtStatus" Text="Hazır. Başlamak için 'Taramayı Başlat'a tıklayın." Foreground="#1B2433" FontWeight="SemiBold"/>
        </DockPanel>
        <TextBox Name="TxtLog" Grid.Row="1" IsReadOnly="True" FontFamily="Consolas" FontSize="12" Background="#0F1720" Foreground="#C9D7E8"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap" BorderThickness="0" Padding="8"/>
      </Grid>

      <TabControl Name="Tabs">
        <TabItem Name="TabDrivers" Header="Sürücüler">
          <DataGrid Name="GridDrivers">
            <DataGrid.Columns>
@@CHECK@@
              <DataGridTextColumn Header="Cihaz / Sürücü" Width="2*" Binding="{Binding Name}" IsReadOnly="True"/>
              <DataGridTextColumn Header="Sınıf" Width="110" Binding="{Binding Category}" IsReadOnly="True"/>
              <DataGridTextColumn Header="Kurulu sürüm" Width="170" Binding="{Binding CurrentVersion}" IsReadOnly="True"/>
              <DataGridTextColumn Header="Yeni sürüm" Width="120" Binding="{Binding NewVersion}" IsReadOnly="True"/>
              <DataGridTextColumn Header="Boyut" Width="80" Binding="{Binding Size}" IsReadOnly="True"/>
              <DataGridTextColumn Header="Üretici" Width="130" Binding="{Binding Source}" IsReadOnly="True"/>
              <DataGridTextColumn Header="Durum" Width="200" Binding="{Binding Status}" IsReadOnly="True"/>
            </DataGrid.Columns>
          </DataGrid>
        </TabItem>
        <TabItem Name="TabHw" Header="Donanım">
          <DataGrid Name="GridHw">
            <DataGrid.Columns>
@@CHECK@@
              <DataGridTextColumn Header="Donanım" Width="2*" Binding="{Binding Name}" IsReadOnly="True"/>
              <DataGridTextColumn Header="Tür" Width="110" Binding="{Binding Category}" IsReadOnly="True"/>
              <DataGridTextColumn Header="Sürücü sürümü" Width="140" Binding="{Binding CurrentVersion}" IsReadOnly="True"/>
              <DataGridTextColumn Header="Sürücü tarihi" Width="100" Binding="{Binding NewVersion}" IsReadOnly="True"/>
              <DataGridTextColumn Header="Yaşı" Width="70" Binding="{Binding Size}" IsReadOnly="True"/>
              <DataGridTextColumn Header="Üretici" Width="120" Binding="{Binding Source}" IsReadOnly="True"/>
              <DataGridTextColumn Header="Durum" Width="240" Binding="{Binding Status}" IsReadOnly="True"/>
            </DataGrid.Columns>
          </DataGrid>
        </TabItem>
        <TabItem Name="TabApps" Header="Programlar">
          <DataGrid Name="GridApps">
            <DataGrid.Columns>
@@CHECK@@
              <DataGridTextColumn Header="Program" Width="2*" Binding="{Binding Name}" IsReadOnly="True"/>
              <DataGridTextColumn Header="Kimlik" Width="1.5*" Binding="{Binding Id}" IsReadOnly="True"/>
              <DataGridTextColumn Header="Kurulu sürüm" Width="130" Binding="{Binding CurrentVersion}" IsReadOnly="True"/>
              <DataGridTextColumn Header="Yeni sürüm" Width="130" Binding="{Binding NewVersion}" IsReadOnly="True"/>
              <DataGridTextColumn Header="Kaynak" Width="80" Binding="{Binding Source}" IsReadOnly="True"/>
              <DataGridTextColumn Header="Durum" Width="170" Binding="{Binding Status}" IsReadOnly="True"/>
            </DataGrid.Columns>
          </DataGrid>
        </TabItem>
        <TabItem Name="TabWindows" Header="Windows">
          <DataGrid Name="GridWindows">
            <DataGrid.Columns>
@@CHECK@@
              <DataGridTextColumn Header="Güncelleme" Width="3*" Binding="{Binding Name}" IsReadOnly="True"/>
              <DataGridTextColumn Header="Kategori" Width="150" Binding="{Binding Category}" IsReadOnly="True"/>
              <DataGridTextColumn Header="KB" Width="100" Binding="{Binding CurrentVersion}" IsReadOnly="True"/>
              <DataGridTextColumn Header="Önem" Width="90" Binding="{Binding NewVersion}" IsReadOnly="True"/>
              <DataGridTextColumn Header="Boyut" Width="80" Binding="{Binding Size}" IsReadOnly="True"/>
              <DataGridTextColumn Header="Durum" Width="200" Binding="{Binding Status}" IsReadOnly="True"/>
            </DataGrid.Columns>
          </DataGrid>
        </TabItem>
      </TabControl>
    </DockPanel>
  </DockPanel>
</Window>
'@
[xml]$xaml = $xamlText.Replace('@@CHECK@@', $checkColumn)

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($node in $xaml.SelectNodes('//*[@Name]')) { $ui[$node.Name] = $window.FindName($node.Name) }

$drivers  = New-Object 'System.Collections.ObjectModel.ObservableCollection[FuItem]'
$hardware = New-Object 'System.Collections.ObjectModel.ObservableCollection[FuItem]'
$apps     = New-Object 'System.Collections.ObjectModel.ObservableCollection[FuItem]'
$winUpd   = New-Object 'System.Collections.ObjectModel.ObservableCollection[FuItem]'
$ui.GridDrivers.ItemsSource = $drivers
$ui.GridHw.ItemsSource      = $hardware
$ui.GridApps.ItemsSource    = $apps
$ui.GridWindows.ItemsSource = $winUpd
$allCollections = @($drivers, $hardware, $apps, $winUpd)
$ui.ChkRestore.IsChecked = $Settings.RestorePoint

# Arama kutusu: tüm sekmelerde ad, kimlik, tür, üretici ve durumda arar
$filter = [Predicate[object]]{
    param($i)
    $t = $ui.TxtSearch.Text
    if ([string]::IsNullOrWhiteSpace($t)) { return $true }
    foreach ($v in @($i.Name, $i.Id, $i.Category, $i.Source, $i.Status)) {
        if ($v -and $v.IndexOf($t.Trim(), [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}
foreach ($c in $allCollections) { [System.Windows.Data.CollectionViewSource]::GetDefaultView($c).Filter = $filter }
$ui.TxtSearch.Add_TextChanged({ foreach ($c in $allCollections) { [System.Windows.Data.CollectionViewSource]::GetDefaultView($c).Refresh() } })
#endregion

#region İş kuyruğu (arayüz donmasın diye işler ayrı runspace'te çalışır)
$sync = [hashtable]::Synchronized(@{
    Queue  = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    Result = $null
})
$script:job = $null
$script:pending = New-Object System.Collections.Queue   # sırayla çalışacak işler

function Write-UiLog([string]$m) {
    $line = (Get-Date -Format 'HH:mm:ss') + "  " + $m
    $ui.TxtLog.AppendText($line + "`r`n")
    $ui.TxtLog.ScrollToEnd()
    Write-LogFile $line
}

function Get-ItemCount { $n = 0; foreach ($c in $allCollections) { $n += $c.Count }; return $n }

function Set-Busy([bool]$busy, [string]$text) {
    $ui.BtnScan.IsEnabled = -not $busy
    $ui.BtnUpdate.IsEnabled = (-not $busy) -and ((Get-ItemCount) -gt 0)
    $ui.Progress.IsIndeterminate = $busy
    $ui.Progress.Visibility = $(if ($busy) { 'Visible' } else { 'Hidden' })
    if ($text) { $ui.TxtStatus.Text = $text }
}

function Add-Job([string]$Title, [string]$Code, $Argument, [scriptblock]$OnDone) {
    $script:pending.Enqueue(@{ Title = $Title; Code = $Code; Arg = $Argument; OnDone = $OnDone })
    if (-not $script:job) { Start-NextJob }
}

function Start-NextJob {
    if ($script:pending.Count -eq 0) { return }
    $j = $script:pending.Dequeue()
    Set-Busy $true $j.Title
    $sync.Result = $null
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    $rs.SessionStateProxy.SetVariable('jobArg', $j.Arg)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($CoreCode + "`n" + $j.Code)
    $script:job = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); OnDone = $j.OnDone }
}

function Get-ItemById([string]$id) {
    foreach ($c in $allCollections) { foreach ($i in $c) { if ($i.Id -eq $id) { return $i } } }
    return $null
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)
$timer.Add_Tick({
    $msg = $null
    while ($sync.Queue.TryDequeue([ref]$msg)) {
        $parts = $msg -split '\|', 3
        if ($parts[0] -eq 'LOG') {
            $ui.TxtLog.AppendText($parts[1] + "`r`n"); $ui.TxtLog.ScrollToEnd()
            Write-LogFile $parts[1]
        } elseif ($parts[0] -eq 'STATUS') {
            $it = Get-ItemById $parts[1]
            if ($it) { $it.Status = $parts[2] }
        }
    }
    if ($script:job -and $script:job.Handle.IsCompleted) {
        $j = $script:job
        $script:job = $null
        try {
            [void]$j.PS.EndInvoke($j.Handle)
            foreach ($e in $j.PS.Streams.Error) { Write-UiLog ("Hata: " + $e.ToString()) }
        } catch { Write-UiLog ("Hata: " + $_.Exception.Message) }
        $j.PS.Dispose(); $j.RS.Dispose()
        if ($j.OnDone) {
            try { & $j.OnDone $sync.Result } catch { Write-UiLog ("Hata: " + $_.Exception.Message) }
        }
        if ($script:pending.Count -gt 0) { Start-NextJob }
        else { Set-Busy $false $null }
    }
})
$timer.Start()
#endregion

#region Tarama ve güncelleme
$script:ignoredCount = 0

function Add-Items($collection, $result) {
    foreach ($r in @($result)) {
        if ($null -eq $r -or $r -is [string]) { continue }
        if (@($Settings.Ignored) -contains [string]$r.Id) { $script:ignoredCount++; continue }
        $it = New-Object FuItem
        foreach ($p in 'Kind','Id','Name','Category','CurrentVersion','NewVersion','Size','Source','Status') { $it.$p = [string]$r.$p }
        $it.Updatable = [bool]$r.Updatable
        # Windows'un isteğe bağlı güncellemeleri varsayılan olarak seçilmez
        $it.Selected = [bool]$r.Updatable -and -not ($r.Kind -eq 'windows' -and $r.Status -eq 'İsteğe bağlı')
        $collection.Add($it)
    }
}

function Update-Summary {
    $d = @($drivers | Where-Object { $_.Kind -eq 'driver' }).Count
    $p = @($drivers | Where-Object { $_.Kind -eq 'problem' }).Count
    $h = @($hardware | Where-Object { $_.Kind -eq 'hw' }).Count
    $o = @($hardware | Where-Object { $_.Kind -eq 'hw' -and $_.Status -like 'Eski*' }).Count
    $a = $apps.Count
    $w = $winUpd.Count
    $ui.TabDrivers.Header = "Sürücüler ($d)"
    $ui.TabHw.Header      = "Donanım ($h)"
    $ui.TabApps.Header    = "Programlar ($a)"
    $ui.TabWindows.Header = "Windows ($w)"
    $text = "Tarama bitti: $d sürücü, $a program, $w Windows güncellemesi. $p sorunlu cihaz, $o eski donanım sürücüsü."
    if ($script:ignoredCount) { $text += " ($($script:ignoredCount) yok sayıldı)" }
    $ui.TxtStatus.Text = $text
}

function Start-Scan {
    foreach ($c in $allCollections) { $c.Clear() }
    $script:ignoredCount = 0
    Write-UiLog "Tarama başladı."
    Add-Job 'Sürücüler ve donanım taranıyor...' $ScanDriversCode $null {
        param($r)
        Add-Items $drivers  @(@($r) | Where-Object { $_.Kind -in 'driver', 'problem' })
        Add-Items $hardware @(@($r) | Where-Object { $_.Kind -eq 'vendor' })
        Add-Items $hardware @(@($r) | Where-Object { $_.Kind -eq 'hw' })
    }
    Add-Job 'Programlar taranıyor...' $ScanAppsCode $null {
        param($r)
        if ($r -eq 'NOWINGET') {
            $ans = [System.Windows.MessageBox]::Show("Program güncellemeleri için Microsoft'un ücretsiz 'Uygulama Yükleyici' (winget) uygulaması gerekiyor.`n`nMicrosoft Store sayfası açılsın mı?", 'FastUpdate', 'YesNo', 'Question')
            if ($ans -eq 'Yes') { Start-Process 'ms-windows-store://pdp/?productid=9NBLGGH4NNS1' }
        } else { Add-Items $apps $r }
    }
    Add-Job 'Windows güncellemeleri taranıyor...' $ScanWindowsCode $null {
        param($r)
        Add-Items $winUpd $r
        Update-Summary
    }
}

function Get-Checked($collection, [string[]]$kinds) {
    @($collection | Where-Object { $_.Selected -and $_.Updatable -and $kinds -contains $_.Kind } | ForEach-Object { $_.Id })
}

function Start-Update {
    $selWu     = @(Get-Checked $drivers @('driver')) + @(Get-Checked $winUpd @('windows'))
    $selVendor = @(Get-Checked $hardware @('vendor'))
    $selApps   = @(Get-Checked $apps @('app'))
    $total = $selWu.Count + $selVendor.Count + $selApps.Count
    if ($total -eq 0) {
        [System.Windows.MessageBox]::Show('Güncellenecek öğe seçilmedi.', 'FastUpdate') | Out-Null
        return
    }
    $msg = "Toplam $total öğe güncellenecek:`n`n" +
           "  Sürücü + Windows güncellemesi: $($selWu.Count)`n" +
           "  Üretici sürücü aracı: $($selVendor.Count)`n" +
           "  Program: $($selApps.Count)`n`nDevam edilsin mi?"
    if ([System.Windows.MessageBox]::Show($msg, 'FastUpdate', 'YesNo', 'Question') -ne 'Yes') { return }

    $Settings.RestorePoint = [bool]$ui.ChkRestore.IsChecked
    Save-Settings $Settings
    if ($selWu.Count -gt 0) {
        Add-Job 'Sürücüler ve Windows güncellemeleri kuruluyor...' $UpdateWuCode @{ Ids = $selWu; RestorePoint = $Settings.RestorePoint } {
            param($r)
            if ($r -and $r.Reboot) { $script:needReboot = $true }
        }
    }
    if ($selVendor.Count -gt 0) {
        Add-Job 'Üretici sürücü araçları hazırlanıyor...' $UpdateVendorCode @{ Ids = $selVendor } $null
    }
    if ($selApps.Count -gt 0) {
        Add-Job 'Programlar güncelleniyor...' $UpdateAppsCode @{ Ids = $selApps } $null
    }
    Add-Job 'Bitiriliyor...' '$sync.Result = $null' $null {
        param($r)
        $ui.TxtStatus.Text = 'Güncelleme tamamlandı.'
        if ($script:needReboot) {
            $script:needReboot = $false
            $a = [System.Windows.MessageBox]::Show("Kurulumu tamamlamak için yeniden başlatma gerekiyor.`nŞimdi yeniden başlatılsın mı?", 'FastUpdate', 'YesNo', 'Question')
            if ($a -eq 'Yes') { Restart-Computer -Force }
        }
    }
}
$script:needReboot = $false
#endregion

#region Araçlar
$AutoTaskName = 'FastUpdate Haftalık'

function Get-AutoMode {
    $t = Get-ScheduledTask -TaskName $AutoTaskName -ErrorAction SilentlyContinue
    if (-not $t) { return 'off' }
    if ((@($t.Actions)[0].Arguments) -match '-Silent') { return 'silent' }
    return 'scan'
}

function Set-AutoMode([string]$mode) {
    try {
        Unregister-ScheduledTask -TaskName $AutoTaskName -Confirm:$false -ErrorAction SilentlyContinue
        if ($mode -ne 'off') {
            $cmd = Get-LaunchCommand $(if ($mode -eq 'silent') { '-Silent' } else { '-Scan' })
            $action    = New-ScheduledTaskAction -Execute $cmd.File -Argument $cmd.Args
            $trigger   = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '12:00'
            $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
            $settingsT = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
            Register-ScheduledTask -TaskName $AutoTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settingsT -Force | Out-Null
        }
        Write-UiLog $(switch ($mode) { 'off' { 'Otomatik çalıştırma kapatıldı.' } 'scan' { 'Her pazar 12:00 otomatik tarama ayarlandı.' } 'silent' { 'Her pazar 12:00 sessiz otomatik güncelleme ayarlandı.' } })
    } catch { Write-UiLog ("Zamanlanmış görev ayarlanamadı: " + $_.Exception.Message) }
    Update-AutoMenu
}

function Update-AutoMenu {
    $m = Get-AutoMode
    $ui.MnuAutoOff.IsChecked    = $m -eq 'off'
    $ui.MnuAutoScan.IsChecked   = $m -eq 'scan'
    $ui.MnuAutoSilent.IsChecked = $m -eq 'silent'
}

function Select-Folder([string]$description, [bool]$newFolder) {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $description
    $dlg.ShowNewFolderButton = $newFolder
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    return $null
}
#endregion

#region Olaylar
$ui.BtnScan.Add_Click({ Start-Scan })
$ui.BtnUpdate.Add_Click({ Start-Update })

function Get-CurrentCollection {
    $t = $ui.Tabs.SelectedItem
    if ([object]::ReferenceEquals($t, $ui.TabHw))      { return ,$hardware }
    if ([object]::ReferenceEquals($t, $ui.TabApps))    { return ,$apps }
    if ([object]::ReferenceEquals($t, $ui.TabWindows)) { return ,$winUpd }
    return ,$drivers
}
$ui.BtnSelAll.Add_Click({ foreach ($i in (Get-CurrentCollection)) { if ($i.Updatable) { $i.Selected = $true } } })
$ui.BtnSelNone.Add_Click({ foreach ($i in (Get-CurrentCollection)) { $i.Selected = $false } })

$ui.BtnIgnore.Add_Click({
    $col = Get-CurrentCollection
    $sel = @($col | Where-Object { $_.Selected -and $_.Updatable })
    if ($sel.Count -eq 0) { [System.Windows.MessageBox]::Show('Bu sekmede seçili öğe yok.', 'FastUpdate') | Out-Null; return }
    $Settings.Ignored = @(@($Settings.Ignored) + @($sel | ForEach-Object { $_.Id }) | Select-Object -Unique)
    Save-Settings $Settings
    foreach ($i in $sel) { [void]$col.Remove($i); Write-UiLog "Yok sayıldı: $($i.Name)" }
})

$ui.MnuUnignore.Add_Click({
    $n = @($Settings.Ignored).Count
    $Settings.Ignored = @()
    Save-Settings $Settings
    Write-UiLog "$n yok sayılan öğe sıfırlandı. Görmek için yeniden tarayın."
})

$ui.MnuBackup.Add_Click({
    $p = Select-Folder 'Sürücü yedeğinin kaydedileceği klasörü seçin' $true
    if ($p) {
        $dest = Join-Path $p ('FastUpdate-Surucu-Yedegi-' + (Get-Date -Format 'yyyyMMdd-HHmm'))
        Add-Job 'Sürücüler yedekleniyor...' $BackupDriversCode @{ Path = $dest } ({ param($r) if (Test-Path $dest) { Start-Process explorer.exe $dest } }.GetNewClosure())
    }
})
$ui.MnuRestoreDrv.Add_Click({
    $p = Select-Folder 'Daha önce alınmış sürücü yedeği klasörünü seçin' $false
    if ($p) { Add-Job 'Sürücü yedeği geri yükleniyor...' $RestoreDriversCode @{ Path = $p } $null }
})
$ui.MnuRestorePoint.Add_Click({ Add-Job 'Geri yükleme noktası oluşturuluyor...' $RestorePointCode $null $null })

$ui.MnuReport.Add_Click({
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'HTML rapor (*.html)|*.html'
    $dlg.FileName = 'FastUpdate-Rapor-' + (Get-Date -Format 'yyyyMMdd-HHmm') + '.html'
    if ($dlg.ShowDialog()) {
        Save-HtmlReport $dlg.FileName $script:sysInfo @(
            @{ Title = 'Sürücü güncellemeleri ve sorunlu cihazlar'; Items = @($drivers); Columns = $ReportColumns.driver }
            @{ Title = 'Donanım sürücüleri'; Items = @($hardware); Columns = $ReportColumns.hw }
            @{ Title = 'Program güncellemeleri'; Items = @($apps); Columns = $ReportColumns.app }
            @{ Title = 'Windows güncellemeleri'; Items = @($winUpd); Columns = $ReportColumns.windows })
        Write-UiLog "Rapor kaydedildi: $($dlg.FileName)"
        Start-Process $dlg.FileName
    }
})
$ui.MnuLogs.Add_Click({ Start-Process explorer.exe $LogDir })

$ui.MnuAutoOff.Add_Click({ Set-AutoMode 'off' })
$ui.MnuAutoScan.Add_Click({ Set-AutoMode 'scan' })
$ui.MnuAutoSilent.Add_Click({
    $a = [System.Windows.MessageBox]::Show("Her pazar 12:00'de, sorulmadan tüm sürücü ve program güncellemeleri kurulacak (yok sayılanlar hariç). Onaylıyor musunuz?", 'FastUpdate', 'YesNo', 'Question')
    if ($a -eq 'Yes') { Set-AutoMode 'silent' } else { Update-AutoMenu }
})

$ui.MnuGithub.Add_Click({ Start-Process "$RepoUrl/releases" })
$ui.MnuAbout.Add_Click({
    [System.Windows.MessageBox]::Show("FastUpdate $AppVersion`n`nÜcretsiz ve açık kaynak sürücü ve program güncelleyici.`nYalnızca Microsoft ve donanım üreticilerinin resmi kaynaklarını kullanır.`n`n$RepoUrl", 'Hakkında') | Out-Null
})

$window.Add_ContentRendered({
    $script:sysInfo = Get-SystemSummary
    $ui.TxtSys.Text = (@($script:sysInfo.Keys | ForEach-Object { "$($_): $($script:sysInfo[$_])" }) -join "`n")
    Update-AutoMenu
    if ($Scan) { Start-Scan }
})

$window.Add_Closing({
    if ($script:job) {
        $a = [System.Windows.MessageBox]::Show("Devam eden bir işlem var. Yine de kapatılsın mı?", 'FastUpdate', 'YesNo', 'Warning')
        if ($a -ne 'Yes') { $_.Cancel = $true; return }
        try { [void]$script:job.PS.BeginStop($null, $null) } catch {}
    }
    $Settings.RestorePoint = [bool]$ui.ChkRestore.IsChecked
    Save-Settings $Settings
    $timer.Stop()
})
#endregion

Write-UiLog "FastUpdate $AppVersion hazır. Yönetici olarak çalışıyor."
[void]$window.ShowDialog()
[Environment]::Exit(0)
