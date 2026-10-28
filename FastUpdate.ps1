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

$AppVersion = '1.2.0'
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

#region Konsol penceresini gizle
# Arayüz modunda arkada siyah bir terminal penceresi görünmesin.
# Sadece bu işlem için açılmış bir konsolsa gizlenir (kullanıcının kendi terminaline dokunulmaz).
if (-not $Silent -and -not $ReportOnly) {
    try {
        Add-Type -Namespace FastUpdateNative -Name Console -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[DllImport("kernel32.dll")] public static extern uint GetConsoleProcessList(uint[] list, uint count);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@
        $h = [FastUpdateNative.Console]::GetConsoleWindow()
        if ($h -ne [IntPtr]::Zero -and [FastUpdateNative.Console]::GetConsoleProcessList((New-Object uint[] 4), 4) -le 1) {
            [void][FastUpdateNative.Console]::ShowWindow($h, 0)
        }
    } catch {}
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
              <DataGridTemplateColumn Header="" Width="44">
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
        Title="FastUpdate" Height="780" Width="1240" MinWidth="980" MinHeight="620"
        WindowStartupLocation="CenterScreen" WindowStyle="None" ResizeMode="CanResize"
        Background="#0B1220" Foreground="#E5ECF6" FontFamily="Segoe UI" FontSize="13"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="46" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>

  <Window.Resources>
    <SolidColorBrush x:Key="Card" Color="#111A2E"/>
    <SolidColorBrush x:Key="Line" Color="#1E2A44"/>
    <SolidColorBrush x:Key="Muted" Color="#8A9BB8"/>
    <SolidColorBrush x:Key="Accent" Color="#3B82F6"/>

    <!-- Genel düğme -->
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="#E5ECF6"/>
      <Setter Property="Background" Value="#1A2540"/>
      <Setter Property="BorderBrush" Value="#26324F"/>
      <Setter Property="Padding" Value="16,9"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.7"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#3B82F6"/>
      <Setter Property="BorderBrush" Value="#3B82F6"/>
      <Setter Property="Foreground" Value="White"/>
    </Style>
    <Style x:Key="Success" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#16A34A"/>
      <Setter Property="BorderBrush" Value="#16A34A"/>
      <Setter Property="Foreground" Value="White"/>
    </Style>
    <Style x:Key="Chrome" TargetType="Button">
      <Setter Property="Foreground" Value="#B8C4D9"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="46"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#1E293B"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ChromeClose" TargetType="Button" BasedOn="{StaticResource Chrome}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#C42B1C"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Yan menü öğesi -->
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#B8C4D9"/>
      <Setter Property="Margin" Value="10,2"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="GroupName" Value="nav"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" Background="Transparent" CornerRadius="8" Padding="12,10">
              <Grid>
                <Border x:Name="bar" Width="3" Height="18" CornerRadius="2" Background="#3B82F6" HorizontalAlignment="Left" Margin="-12,0,0,0" Visibility="Hidden"/>
                <ContentPresenter/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#141E33"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="#1A2540"/>
                <Setter TargetName="bar" Property="Visibility" Value="Visible"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Icon" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="0,0,14,0"/>
    </Style>
    <Style x:Key="Badge" TargetType="Border">
      <Setter Property="Background" Value="#3B82F6"/>
      <Setter Property="CornerRadius" Value="9"/>
      <Setter Property="Padding" Value="7,1"/>
      <Setter Property="HorizontalAlignment" Value="Right"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="CardBorder" TargetType="Border">
      <Setter Property="Background" Value="#111A2E"/>
      <Setter Property="BorderBrush" Value="#1E2A44"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="20"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E5ECF6"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="#E5ECF6"/>
      <Setter Property="Margin" Value="0,4"/>
    </Style>

    <!-- Tablo -->
    <Style TargetType="DataGrid">
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="CanUserResizeRows" Value="False"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="GridLinesVisibility" Value="None"/>
      <Setter Property="Background" Value="#111A2E"/>
      <Setter Property="RowBackground" Value="#111A2E"/>
      <Setter Property="AlternatingRowBackground" Value="#0F1729"/>
      <Setter Property="Foreground" Value="#E5ECF6"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="RowHeight" Value="38"/>
      <Setter Property="SelectionMode" Value="Extended"/>
      <Setter Property="SelectionUnit" Value="FullRow"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#0F1729"/>
      <Setter Property="Foreground" Value="#8A9BB8"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="12,10"/>
      <Setter Property="BorderBrush" Value="#1E2A44"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Background="Transparent" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="DataGridRow">
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#16213A"/></Trigger>
        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#1C2B4A"/></Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <Border Name="RootBorder" BorderBrush="#1E2A44" BorderThickness="1">
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="240"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition Height="46"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

      <!-- Başlık çubuğu -->
      <Border Grid.ColumnSpan="2" Background="#0F172A">
        <DockPanel>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="18,0,0,0">
            <Border Width="24" Height="24" CornerRadius="6" Background="#3B82F6">
              <Path Data="M13,2 L4,14 H11 L10,22 L20,9 H13 Z" Fill="White" Stretch="Uniform" Margin="5"/>
            </Border>
            <TextBlock Text="FastUpdate" FontWeight="Bold" FontSize="14" Margin="10,0,0,0" VerticalAlignment="Center"/>
            <TextBlock Name="TxtVersion" Text="" Foreground="#5E6E8C" FontSize="12" Margin="8,1,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button Name="BtnMin" Style="{StaticResource Chrome}" Content="&#xE921;"/>
            <Button Name="BtnMax" Style="{StaticResource Chrome}" Content="&#xE922;"/>
            <Button Name="BtnClose" Style="{StaticResource ChromeClose}" Content="&#xE8BB;"/>
          </StackPanel>
        </DockPanel>
      </Border>

      <!-- Yan menü -->
      <Border Grid.Row="1" Grid.RowSpan="2" Background="#0F172A" BorderBrush="#1E2A44" BorderThickness="0,0,1,0">
        <DockPanel Margin="0,12,0,12">
          <StackPanel DockPanel.Dock="Bottom" Margin="22,0">
            <TextBlock Text="Ücretsiz ve açık kaynak" Foreground="#5E6E8C" FontSize="11"/>
            <TextBlock Text="Yalnızca resmi kaynaklar" Foreground="#5E6E8C" FontSize="11"/>
          </StackPanel>
          <StackPanel>
            <RadioButton Name="NavHome" Style="{StaticResource Nav}" IsChecked="True">
              <DockPanel><TextBlock Style="{StaticResource Icon}" Text="&#xE80F;"/><TextBlock Text="Genel Bakış"/></DockPanel>
            </RadioButton>
            <TextBlock Text="GÜNCELLEMELER" Foreground="#5E6E8C" FontSize="11" FontWeight="SemiBold" Margin="24,16,0,6"/>
            <RadioButton Name="NavDrivers" Style="{StaticResource Nav}">
              <DockPanel><TextBlock Style="{StaticResource Icon}" Text="&#xE772;"/>
                <Border Name="BadgeDrivers" DockPanel.Dock="Right" Style="{StaticResource Badge}" Visibility="Collapsed"><TextBlock Name="CntDrivers" Foreground="White" FontSize="11" FontWeight="Bold"/></Border>
                <TextBlock Text="Sürücüler"/></DockPanel>
            </RadioButton>
            <RadioButton Name="NavHw" Style="{StaticResource Nav}">
              <DockPanel><TextBlock Style="{StaticResource Icon}" Text="&#xE950;"/>
                <Border Name="BadgeHw" DockPanel.Dock="Right" Style="{StaticResource Badge}" Background="#F59E0B" Visibility="Collapsed"><TextBlock Name="CntHw" Foreground="White" FontSize="11" FontWeight="Bold"/></Border>
                <TextBlock Text="Donanım"/></DockPanel>
            </RadioButton>
            <RadioButton Name="NavApps" Style="{StaticResource Nav}">
              <DockPanel><TextBlock Style="{StaticResource Icon}" Text="&#xE71D;"/>
                <Border Name="BadgeApps" DockPanel.Dock="Right" Style="{StaticResource Badge}" Visibility="Collapsed"><TextBlock Name="CntApps" Foreground="White" FontSize="11" FontWeight="Bold"/></Border>
                <TextBlock Text="Programlar"/></DockPanel>
            </RadioButton>
            <RadioButton Name="NavWindows" Style="{StaticResource Nav}">
              <DockPanel><TextBlock Style="{StaticResource Icon}" Text="&#xE895;"/>
                <Border Name="BadgeWindows" DockPanel.Dock="Right" Style="{StaticResource Badge}" Visibility="Collapsed"><TextBlock Name="CntWindows" Foreground="White" FontSize="11" FontWeight="Bold"/></Border>
                <TextBlock Text="Windows"/></DockPanel>
            </RadioButton>
            <TextBlock Text="DİĞER" Foreground="#5E6E8C" FontSize="11" FontWeight="SemiBold" Margin="24,16,0,6"/>
            <RadioButton Name="NavTools" Style="{StaticResource Nav}">
              <DockPanel><TextBlock Style="{StaticResource Icon}" Text="&#xE90F;"/><TextBlock Text="Araçlar ve Ayarlar"/></DockPanel>
            </RadioButton>
            <RadioButton Name="NavLog" Style="{StaticResource Nav}">
              <DockPanel><TextBlock Style="{StaticResource Icon}" Text="&#xE81C;"/><TextBlock Text="İşlem Geçmişi"/></DockPanel>
            </RadioButton>
          </StackPanel>
        </DockPanel>
      </Border>

      <!-- İçerik -->
      <Grid Grid.Row="1" Grid.Column="1" Margin="28,22,28,12">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>

        <DockPanel Margin="0,0,0,16">
          <Border Name="SearchBox" DockPanel.Dock="Right" Background="#111A2E" BorderBrush="#26324F" BorderThickness="1" CornerRadius="8" Width="260" Height="38" VerticalAlignment="Center" Visibility="Collapsed">
            <Grid Margin="12,0">
              <TextBlock Style="{StaticResource Icon}" Text="&#xE721;" FontSize="13" Foreground="#5E6E8C" HorizontalAlignment="Left"/>
              <TextBlock Name="SearchHint" Text="Ara..." Foreground="#5E6E8C" VerticalAlignment="Center" Margin="26,0,0,0" IsHitTestVisible="False"/>
              <TextBox Name="TxtSearch" Background="Transparent" BorderThickness="0" Foreground="#E5ECF6" CaretBrush="White" VerticalAlignment="Center" Margin="22,0,0,0"/>
            </Grid>
          </Border>
          <StackPanel>
            <TextBlock Name="TxtPageTitle" Text="Genel Bakış" FontSize="26" FontWeight="Bold"/>
            <TextBlock Name="TxtPageSub" Text="" Foreground="#8A9BB8" Margin="0,4,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </DockPanel>

        <StackPanel Name="ListBar" Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,14" Visibility="Collapsed">
          <Button Name="BtnUpdate" Style="{StaticResource Success}" Content="Seçilenleri Güncelle" IsEnabled="False"/>
          <Button Name="BtnSelAll" Content="Tümünü Seç"/>
          <Button Name="BtnSelNone" Content="Seçimi Kaldır"/>
          <Button Name="BtnIgnore" Content="Yok Say" ToolTip="Seçilen öğeler sonraki taramalarda gösterilmez"/>
        </StackPanel>

        <TabControl Name="Tabs" Grid.Row="2" Background="Transparent" BorderThickness="0" Padding="0">
          <TabControl.ItemContainerStyle>
            <Style TargetType="TabItem"><Setter Property="Visibility" Value="Collapsed"/></Style>
          </TabControl.ItemContainerStyle>

          <!-- 0: Genel bakış -->
          <TabItem Name="TabHome">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <StackPanel>
                <Border Style="{StaticResource CardBorder}" Padding="28">
                  <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                      <GradientStop Color="#1D3B7A" Offset="0"/>
                      <GradientStop Color="#111A2E" Offset="1"/>
                    </LinearGradientBrush>
                  </Border.Background>
                  <DockPanel>
                    <Grid DockPanel.Dock="Left" Width="110" Height="110" Margin="0,0,28,0">
                      <Ellipse Name="HeroRing" Stroke="#3B82F6" StrokeThickness="6" Opacity="0.9"/>
                      <TextBlock Name="HeroIcon" Style="{StaticResource Icon}" Text="&#xE83D;" FontSize="44" Margin="0" HorizontalAlignment="Center" Foreground="White"/>
                    </Grid>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock Name="HeroTitle" Text="Taramaya hazır" FontSize="28" FontWeight="Bold"/>
                      <TextBlock Name="HeroSub" Text="Sürücüleri, donanımı, programları ve Windows'u tek tıkla kontrol et." Foreground="#B8C4D9" Margin="0,6,0,18" TextWrapping="Wrap"/>
                      <StackPanel Orientation="Horizontal">
                        <Button Name="BtnScan" Style="{StaticResource Primary}" Padding="26,12" FontSize="14">
                          <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE721;" FontSize="14" Margin="0,0,10,0"/><TextBlock Name="TxtScanBtn" Text="Taramayı Başlat"/></StackPanel>
                        </Button>
                        <Button Name="BtnUpdateAll" Style="{StaticResource Success}" Padding="26,12" FontSize="14" IsEnabled="False">
                          <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE896;" FontSize="14" Margin="0,0,10,0"/><TextBlock Text="Önerilenleri Güncelle"/></StackPanel>
                        </Button>
                      </StackPanel>
                    </StackPanel>
                  </DockPanel>
                </Border>

                <UniformGrid Columns="4" Margin="-6,16,-6,0">
                  <Button Name="StatDrivers" Margin="6" Padding="0" Background="#111A2E" BorderBrush="#1E2A44" HorizontalContentAlignment="Stretch">
                    <StackPanel Margin="18,16" HorizontalAlignment="Left">
                      <TextBlock Style="{StaticResource Icon}" Text="&#xE772;" Foreground="#3B82F6" FontSize="20"/>
                      <TextBlock Name="NumDrivers" Text="-" FontSize="30" FontWeight="Bold" Margin="0,10,0,0"/>
                      <TextBlock Text="Sürücü güncellemesi" Foreground="#8A9BB8" FontWeight="Normal"/>
                      <TextBlock Name="NumProblems" Text="" Foreground="#EF4444" FontWeight="Normal" FontSize="12" Margin="0,2,0,0"/>
                    </StackPanel>
                  </Button>
                  <Button Name="StatHw" Margin="6" Padding="0" Background="#111A2E" BorderBrush="#1E2A44" HorizontalContentAlignment="Stretch">
                    <StackPanel Margin="18,16" HorizontalAlignment="Left">
                      <TextBlock Style="{StaticResource Icon}" Text="&#xE950;" Foreground="#F59E0B" FontSize="20"/>
                      <TextBlock Name="NumHw" Text="-" FontSize="30" FontWeight="Bold" Margin="0,10,0,0"/>
                      <TextBlock Text="Eski donanım sürücüsü" Foreground="#8A9BB8" FontWeight="Normal"/>
                      <TextBlock Name="NumHwTotal" Text="" Foreground="#8A9BB8" FontWeight="Normal" FontSize="12" Margin="0,2,0,0"/>
                    </StackPanel>
                  </Button>
                  <Button Name="StatApps" Margin="6" Padding="0" Background="#111A2E" BorderBrush="#1E2A44" HorizontalContentAlignment="Stretch">
                    <StackPanel Margin="18,16" HorizontalAlignment="Left">
                      <TextBlock Style="{StaticResource Icon}" Text="&#xE71D;" Foreground="#A855F7" FontSize="20"/>
                      <TextBlock Name="NumApps" Text="-" FontSize="30" FontWeight="Bold" Margin="0,10,0,0"/>
                      <TextBlock Text="Program güncellemesi" Foreground="#8A9BB8" FontWeight="Normal"/>
                    </StackPanel>
                  </Button>
                  <Button Name="StatWindows" Margin="6" Padding="0" Background="#111A2E" BorderBrush="#1E2A44" HorizontalContentAlignment="Stretch">
                    <StackPanel Margin="18,16" HorizontalAlignment="Left">
                      <TextBlock Style="{StaticResource Icon}" Text="&#xE895;" Foreground="#22C55E" FontSize="20"/>
                      <TextBlock Name="NumWindows" Text="-" FontSize="30" FontWeight="Bold" Margin="0,10,0,0"/>
                      <TextBlock Text="Windows güncellemesi" Foreground="#8A9BB8" FontWeight="Normal"/>
                    </StackPanel>
                  </Button>
                </UniformGrid>

                <Border Style="{StaticResource CardBorder}" Margin="0,10,0,0">
                  <StackPanel>
                    <TextBlock Text="Bu bilgisayar" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,12"/>
                    <ItemsControl Name="SysList">
                      <ItemsControl.ItemTemplate>
                        <DataTemplate>
                          <DockPanel Margin="0,4">
                            <TextBlock Text="{Binding Key}" Width="150" Foreground="#8A9BB8"/>
                            <TextBlock Text="{Binding Value}" TextWrapping="Wrap"/>
                          </DockPanel>
                        </DataTemplate>
                      </ItemsControl.ItemTemplate>
                    </ItemsControl>
                  </StackPanel>
                </Border>
              </StackPanel>
            </ScrollViewer>
          </TabItem>

          <!-- 1: Sürücüler -->
          <TabItem Name="TabDrivers">
            <Border Style="{StaticResource CardBorder}" Padding="0" ClipToBounds="True">
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
            </Border>
          </TabItem>

          <!-- 2: Donanım -->
          <TabItem Name="TabHw">
            <Border Style="{StaticResource CardBorder}" Padding="0" ClipToBounds="True">
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
            </Border>
          </TabItem>

          <!-- 3: Programlar -->
          <TabItem Name="TabApps">
            <Border Style="{StaticResource CardBorder}" Padding="0" ClipToBounds="True">
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
            </Border>
          </TabItem>

          <!-- 4: Windows -->
          <TabItem Name="TabWindows">
            <Border Style="{StaticResource CardBorder}" Padding="0" ClipToBounds="True">
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
            </Border>
          </TabItem>

          <!-- 5: Araçlar ve ayarlar -->
          <TabItem Name="TabTools">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <StackPanel>
                <UniformGrid Columns="2" Margin="-6,0">
                  <Border Style="{StaticResource CardBorder}" Margin="6">
                    <StackPanel>
                      <TextBlock Style="{StaticResource Icon}" Text="&#xE8F1;" Foreground="#3B82F6" FontSize="22" HorizontalAlignment="Left"/>
                      <TextBlock Text="Sürücü yedeği" FontSize="16" FontWeight="SemiBold" Margin="0,10,0,4"/>
                      <TextBlock Text="Kurulu tüm sürücüleri bir klasöre yedekle, Windows'u yeniden kurduğunda tek tıkla geri yükle." Foreground="#8A9BB8" TextWrapping="Wrap" Margin="0,0,0,14"/>
                      <StackPanel Orientation="Horizontal">
                        <Button Name="BtnBackup" Style="{StaticResource Primary}" Content="Yedekle"/>
                        <Button Name="BtnRestoreDrv" Content="Geri Yükle"/>
                      </StackPanel>
                    </StackPanel>
                  </Border>
                  <Border Style="{StaticResource CardBorder}" Margin="6">
                    <StackPanel>
                      <TextBlock Style="{StaticResource Icon}" Text="&#xE777;" Foreground="#22C55E" FontSize="22" HorizontalAlignment="Left"/>
                      <TextBlock Text="Sistem geri yükleme noktası" FontSize="16" FontWeight="SemiBold" Margin="0,10,0,4"/>
                      <TextBlock Text="Bir sorun olursa bilgisayarı bu ana döndürebilmek için güvenli bir nokta oluştur." Foreground="#8A9BB8" TextWrapping="Wrap" Margin="0,0,0,14"/>
                      <StackPanel Orientation="Horizontal">
                        <Button Name="BtnRestorePoint" Style="{StaticResource Primary}" Content="Şimdi Oluştur"/>
                      </StackPanel>
                    </StackPanel>
                  </Border>
                  <Border Style="{StaticResource CardBorder}" Margin="6">
                    <StackPanel>
                      <TextBlock Style="{StaticResource Icon}" Text="&#xE9F9;" Foreground="#A855F7" FontSize="22" HorizontalAlignment="Left"/>
                      <TextBlock Text="Rapor" FontSize="16" FontWeight="SemiBold" Margin="0,10,0,4"/>
                      <TextBlock Text="Sistem bilgisi ve tarama sonuçlarını paylaşılabilir bir HTML raporuna kaydet." Foreground="#8A9BB8" TextWrapping="Wrap" Margin="0,0,0,14"/>
                      <StackPanel Orientation="Horizontal">
                        <Button Name="BtnReport" Style="{StaticResource Primary}" Content="Rapor Kaydet"/>
                        <Button Name="BtnLogs" Content="Günlük Klasörü"/>
                      </StackPanel>
                    </StackPanel>
                  </Border>
                  <Border Style="{StaticResource CardBorder}" Margin="6">
                    <StackPanel>
                      <TextBlock Style="{StaticResource Icon}" Text="&#xE787;" Foreground="#F59E0B" FontSize="22" HorizontalAlignment="Left"/>
                      <TextBlock Text="Otomatik çalıştırma" FontSize="16" FontWeight="SemiBold" Margin="0,10,0,8"/>
                      <RadioButton Name="RbAutoOff" GroupName="auto" Content="Kapalı"/>
                      <RadioButton Name="RbAutoScan" GroupName="auto" Content="Her pazar 12:00'de tara (pencere açılır)"/>
                      <RadioButton Name="RbAutoSilent" GroupName="auto" Content="Her pazar 12:00'de sessizce güncelle"/>
                    </StackPanel>
                  </Border>
                </UniformGrid>

                <Border Style="{StaticResource CardBorder}" Margin="0,10,0,0">
                  <StackPanel>
                    <TextBlock Text="Ayarlar" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,12"/>
                    <CheckBox Name="ChkRestore" Content="Sürücü ve Windows güncellemelerinden önce geri yükleme noktası oluştur" Margin="0,0,0,10"/>
                    <DockPanel>
                      <Button Name="BtnUnignore" Content="Sıfırla" DockPanel.Dock="Right" Margin="0"/>
                      <TextBlock Name="TxtIgnored" Text="Yok sayılan öğe yok." Foreground="#8A9BB8" VerticalAlignment="Center"/>
                    </DockPanel>
                  </StackPanel>
                </Border>

                <Border Style="{StaticResource CardBorder}" Margin="0,16,0,0">
                  <DockPanel>
                    <Button Name="BtnGithub" Content="GitHub ve yeni sürümler" DockPanel.Dock="Right" Margin="0" VerticalAlignment="Center"/>
                    <StackPanel>
                      <TextBlock Name="TxtAbout" Text="FastUpdate" FontSize="16" FontWeight="SemiBold"/>
                      <TextBlock Text="Ücretsiz ve açık kaynak (MIT). Sürücüler Windows Update ve üreticilerin resmi araçlarından, programlar winget'ten gelir. Hiçbir veri toplanmaz." Foreground="#8A9BB8" TextWrapping="Wrap" Margin="0,4,16,0"/>
                    </StackPanel>
                  </DockPanel>
                </Border>
              </StackPanel>
            </ScrollViewer>
          </TabItem>

          <!-- 6: İşlem geçmişi -->
          <TabItem Name="TabLog">
            <Border Style="{StaticResource CardBorder}" Padding="4">
              <TextBox Name="TxtLog" IsReadOnly="True" FontFamily="Cascadia Mono, Consolas" FontSize="12" Background="Transparent" Foreground="#C9D7E8"
                       VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap" BorderThickness="0" Padding="12"/>
            </Border>
          </TabItem>
        </TabControl>
      </Grid>

      <!-- Durum çubuğu -->
      <Border Grid.Row="2" Grid.Column="1" Background="#0F172A" BorderBrush="#1E2A44" BorderThickness="0,1,0,0" Padding="28,10">
        <DockPanel>
          <ProgressBar Name="Progress" DockPanel.Dock="Right" Width="220" Height="6" Visibility="Hidden" Foreground="#3B82F6" Background="#1E2A44" BorderThickness="0"/>
          <TextBlock Name="TxtStatus" Text="Hazır." Foreground="#B8C4D9" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
        </DockPanel>
      </Border>
    </Grid>
  </Border>
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
$ui.TxtVersion.Text = "v$AppVersion"
$ui.TxtAbout.Text = "FastUpdate $AppVersion"

# Arama kutusu: tüm listelerde ad, kimlik, tür, üretici ve durumda arar
function ConvertTo-Brush([string]$hex) { return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex) }

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
$ui.TxtSearch.Add_TextChanged({
    $ui.SearchHint.Visibility = $(if ($ui.TxtSearch.Text) { 'Hidden' } else { 'Visible' })
    foreach ($c in $allCollections) { [System.Windows.Data.CollectionViewSource]::GetDefaultView($c).Refresh() }
})

# Pencere düğmeleri (özel başlık çubuğu)
$ui.BtnMin.Add_Click({ $window.WindowState = 'Minimized' })
$ui.BtnMax.Add_Click({ $window.WindowState = $(if ($window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }) })
$ui.BtnClose.Add_Click({ $window.Close() })
$window.Add_StateChanged({
    # Ekranı kaplayınca kenarların taşmaması için
    $ui.RootBorder.Margin = [System.Windows.Thickness]::new($(if ($window.WindowState -eq 'Maximized') { 7 } else { 0 }))
    $ui.BtnMax.Content = $(if ($window.WindowState -eq 'Maximized') { [string][char]0xE923 } else { [string][char]0xE922 })
})

# Sayfalar
$Pages = [ordered]@{
    NavHome    = @{ Index = 0; Title = 'Genel Bakış'; Sub = ''; List = $false }
    NavDrivers = @{ Index = 1; Title = 'Sürücüler'; Sub = "Windows Update'teki Microsoft onaylı sürücü güncellemeleri ve sorunlu cihazlar."; List = $true }
    NavHw      = @{ Index = 2; Title = 'Donanım'; Sub = 'Ekran kartı, yonga seti, ağ, ses ve diğer donanım sürücüleri. En yeni GPU sürücüleri için üretici aracını seçin.'; List = $true }
    NavApps    = @{ Index = 3; Title = 'Programlar'; Sub = 'winget ile sessizce güncellenebilen programlar.'; List = $true }
    NavWindows = @{ Index = 4; Title = 'Windows'; Sub = 'Bekleyen Windows güncellemeleri. İsteğe bağlı olanlar varsayılan olarak seçilmez.'; List = $true }
    NavTools   = @{ Index = 5; Title = 'Araçlar ve Ayarlar'; Sub = 'Yedekleme, geri yükleme, rapor ve otomatik çalıştırma.'; List = $false }
    NavLog     = @{ Index = 6; Title = 'İşlem Geçmişi'; Sub = "Yapılan her işlemin ayrıntılı kaydı."; List = $false }
}
function Show-Page([string]$nav) {
    $p = $Pages[$nav]
    $ui.Tabs.SelectedIndex = $p.Index
    $ui.TxtPageTitle.Text = $p.Title
    $ui.TxtPageSub.Text = $(if ($nav -eq 'NavHome') { $script:homeSub } else { $p.Sub })
    $vis = $(if ($p.List) { 'Visible' } else { 'Collapsed' })
    $ui.ListBar.Visibility = $vis
    $ui.SearchBox.Visibility = $vis
    if (-not $ui[$nav].IsChecked) { $ui[$nav].IsChecked = $true }
}
foreach ($k in @($Pages.Keys)) {
    $ui[$k].Add_Checked({ param($s, $e) Show-Page $s.Name })
}
$script:homeSub = 'Sürücülerini, donanımını, programlarını ve Windows güncellemelerini tek yerden yönet.'
$ui.StatDrivers.Add_Click({ Show-Page 'NavDrivers' })
$ui.StatHw.Add_Click({ Show-Page 'NavHw' })
$ui.StatApps.Add_Click({ Show-Page 'NavApps' })
$ui.StatWindows.Add_Click({ Show-Page 'NavWindows' })
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
    $ui.TxtScanBtn.Text = $(if ($busy) { 'Çalışıyor...' } elseif ($script:scanned) { 'Yeniden Tara' } else { 'Taramayı Başlat' })
    $canUpdate = (-not $busy) -and ((Get-ItemCount) -gt 0)
    $ui.BtnUpdate.IsEnabled = $canUpdate
    $ui.BtnUpdateAll.IsEnabled = $canUpdate
    $ui.Progress.IsIndeterminate = $busy
    $ui.Progress.Visibility = $(if ($busy) { 'Visible' } else { 'Hidden' })
    if ($busy) { $ui.HeroRing.StrokeDashArray = [System.Windows.Media.DoubleCollection]::Parse('4 3') }
    else { $ui.HeroRing.StrokeDashArray = $null }
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

# Arka plan işlerinden gelen günlük ve durum mesajlarını arayüze aktarır
$script:spin = 0
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(150)
$timer.Add_Tick({
    $msg = $null
    while ($sync.Queue.TryDequeue([ref]$msg)) {
        $parts = $msg -split '\|', 3
        if ($parts[0] -eq 'LOG') {
            $ui.TxtLog.AppendText($parts[1] + "`r`n"); $ui.TxtLog.ScrollToEnd()
            Write-LogFile $parts[1]
            $ui.TxtStatus.Text = ($parts[1] -replace '^\d\d:\d\d:\d\d\s+', '')
        } elseif ($parts[0] -eq 'STATUS') {
            $it = Get-ItemById $parts[1]
            if ($it) { $it.Status = $parts[2] }
        }
    }
    if ($script:job) {
        $script:spin = ($script:spin + 1) % 7
        $ui.HeroRing.StrokeDashOffset = -$script:spin
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
$script:scanned = $false

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

function Set-Badge([string]$name, [int]$n) {
    $ui["Cnt$name"].Text = "$n"
    $ui["Badge$name"].Visibility = $(if ($n -gt 0) { 'Visible' } else { 'Collapsed' })
}

function Update-IgnoredText {
    $n = @($Settings.Ignored).Count
    $ui.TxtIgnored.Text = $(if ($n) { "$n öğe yok sayılıyor ve taramalarda gösterilmiyor." } else { 'Yok sayılan öğe yok.' })
}

function Update-Summary {
    $d = @($drivers | Where-Object { $_.Kind -eq 'driver' }).Count
    $p = @($drivers | Where-Object { $_.Kind -eq 'problem' }).Count
    $h = @($hardware | Where-Object { $_.Kind -eq 'hw' }).Count
    $o = @($hardware | Where-Object { $_.Kind -eq 'hw' -and $_.Status -like 'Eski*' }).Count
    $a = $apps.Count
    $w = $winUpd.Count
    Set-Badge 'Drivers' ($d + $p)
    Set-Badge 'Hw' $o
    Set-Badge 'Apps' $a
    Set-Badge 'Windows' $w
    $ui.NumDrivers.Text = "$d"
    $ui.NumProblems.Text = $(if ($p) { "$p sorunlu cihaz" } else { '' })
    $ui.NumHw.Text = "$o"
    $ui.NumHwTotal.Text = "$h sürücü analiz edildi"
    $ui.NumApps.Text = "$a"
    $ui.NumWindows.Text = "$w"
    $total = $d + $a + $w
    if ($total -eq 0 -and $p -eq 0) {
        $ui.HeroTitle.Text = 'Her şey güncel'
        $ui.HeroIcon.Text = [string][char]0xE73E
        $ui.HeroRing.Stroke = (ConvertTo-Brush '#22C55E')
    } else {
        $ui.HeroTitle.Text = "$total güncelleme bulundu"
        $ui.HeroIcon.Text = [string][char]0xE7BA
        $ui.HeroRing.Stroke = (ConvertTo-Brush '#F59E0B')
    }
    $script:homeSub = 'Son tarama: ' + (Get-Date -Format 'dd.MM.yyyy HH:mm') + $(if ($script:ignoredCount) { " · $($script:ignoredCount) öğe yok sayıldı" } else { '' })
    $ui.HeroSub.Text = $(if ($total) { 'Önerilen güncellemeler seçili. Tek tıkla hepsini kurabilir ya da sekmelerden tek tek seçebilirsin.' } else { 'Sürücülerin, programların ve Windows güncel görünüyor.' })
    if ($ui.NavHome.IsChecked) { $ui.TxtPageSub.Text = $script:homeSub }
    $ui.TxtStatus.Text = "Tarama bitti: $d sürücü, $a program, $w Windows güncellemesi. $p sorunlu cihaz, $o eski donanım sürücüsü."
    $script:scanned = $true
}

function Start-Scan {
    foreach ($c in $allCollections) { $c.Clear() }
    $script:ignoredCount = 0
    $ui.HeroTitle.Text = 'Taranıyor...'
    $ui.HeroSub.Text = 'Sürücüler, donanım, programlar ve Windows güncellemeleri kontrol ediliyor. Bu 1-3 dakika sürebilir.'
    $ui.HeroIcon.Text = [string][char]0xE721
    $ui.HeroRing.Stroke = (ConvertTo-Brush '#3B82F6')
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
    $ui.HeroTitle.Text = 'Güncelleniyor...'
    $ui.HeroSub.Text = 'İlerlemeyi listelerdeki Durum sütunundan ve İşlem Geçmişi sayfasından izleyebilirsin.'
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
        $ui.HeroTitle.Text = 'Güncelleme tamamlandı'
        $ui.HeroIcon.Text = [string][char]0xE73E
        $ui.HeroRing.Stroke = (ConvertTo-Brush '#22C55E')
        $ui.HeroSub.Text = 'Sonuçları listelerdeki Durum sütununda görebilirsin. Kontrol için yeniden tarayabilirsin.'
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
    Update-AutoRadios
}

$script:autoUpdating = $false
function Update-AutoRadios {
    $script:autoUpdating = $true
    $m = Get-AutoMode
    $ui.RbAutoOff.IsChecked    = $m -eq 'off'
    $ui.RbAutoScan.IsChecked   = $m -eq 'scan'
    $ui.RbAutoSilent.IsChecked = $m -eq 'silent'
    $script:autoUpdating = $false
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
$ui.BtnUpdateAll.Add_Click({ Start-Update })

function Get-CurrentCollection {
    switch ($ui.Tabs.SelectedIndex) {
        2 { return ,$hardware }
        3 { return ,$apps }
        4 { return ,$winUpd }
        default { return ,$drivers }
    }
}
$ui.BtnSelAll.Add_Click({ foreach ($i in (Get-CurrentCollection)) { if ($i.Updatable) { $i.Selected = $true } } })
$ui.BtnSelNone.Add_Click({ foreach ($i in (Get-CurrentCollection)) { $i.Selected = $false } })

$ui.BtnIgnore.Add_Click({
    $col = Get-CurrentCollection
    $sel = @($col | Where-Object { $_.Selected -and $_.Updatable })
    if ($sel.Count -eq 0) { [System.Windows.MessageBox]::Show('Bu sayfada seçili öğe yok.', 'FastUpdate') | Out-Null; return }
    $Settings.Ignored = @(@($Settings.Ignored) + @($sel | ForEach-Object { $_.Id }) | Select-Object -Unique)
    Save-Settings $Settings
    foreach ($i in $sel) { [void]$col.Remove($i); Write-UiLog "Yok sayıldı: $($i.Name)" }
    Update-IgnoredText
    if ($script:scanned) { Update-Summary }
})

$ui.BtnUnignore.Add_Click({
    $n = @($Settings.Ignored).Count
    $Settings.Ignored = @()
    Save-Settings $Settings
    Update-IgnoredText
    Write-UiLog "$n yok sayılan öğe sıfırlandı. Görmek için yeniden tarayın."
})

$ui.ChkRestore.Add_Click({ $Settings.RestorePoint = [bool]$ui.ChkRestore.IsChecked; Save-Settings $Settings })

$ui.BtnBackup.Add_Click({
    $p = Select-Folder 'Sürücü yedeğinin kaydedileceği klasörü seçin' $true
    if ($p) {
        $dest = Join-Path $p ('FastUpdate-Surucu-Yedegi-' + (Get-Date -Format 'yyyyMMdd-HHmm'))
        Add-Job 'Sürücüler yedekleniyor...' $BackupDriversCode @{ Path = $dest } ({ param($r) if (Test-Path $dest) { Start-Process explorer.exe $dest } }.GetNewClosure())
    }
})
$ui.BtnRestoreDrv.Add_Click({
    $p = Select-Folder 'Daha önce alınmış sürücü yedeği klasörünü seçin' $false
    if ($p) { Add-Job 'Sürücü yedeği geri yükleniyor...' $RestoreDriversCode @{ Path = $p } $null }
})
$ui.BtnRestorePoint.Add_Click({ Add-Job 'Geri yükleme noktası oluşturuluyor...' $RestorePointCode $null $null })

$ui.BtnReport.Add_Click({
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
$ui.BtnLogs.Add_Click({ Start-Process explorer.exe $LogDir })

$ui.RbAutoOff.Add_Checked({ if (-not $script:autoUpdating) { Set-AutoMode 'off' } })
$ui.RbAutoScan.Add_Checked({ if (-not $script:autoUpdating) { Set-AutoMode 'scan' } })
$ui.RbAutoSilent.Add_Checked({
    if ($script:autoUpdating) { return }
    $a = [System.Windows.MessageBox]::Show("Her pazar 12:00'de, sorulmadan tüm sürücü ve program güncellemeleri kurulacak (yok sayılanlar hariç). Onaylıyor musunuz?", 'FastUpdate', 'YesNo', 'Question')
    if ($a -eq 'Yes') { Set-AutoMode 'silent' } else { Update-AutoRadios }
})

$ui.BtnGithub.Add_Click({ Start-Process "$RepoUrl/releases" })

$window.Add_ContentRendered({
    $script:sysInfo = Get-SystemSummary
    $ui.SysList.ItemsSource = @($script:sysInfo.GetEnumerator())
    Update-AutoRadios
    Update-IgnoredText
    Show-Page 'NavHome'
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
