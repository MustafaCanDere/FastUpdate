<#
    Arayüzün örnek verilerle ekran görüntülerini üretir (README ve görsel kontrol için).
    Kullanım: .\tests\Render-Screenshots.ps1 -OutDir docs
#>
param([string]$OutDir = (Join-Path $PSScriptRoot '..\docs'))
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '..\FastUpdate.ps1' | Resolve-Path
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$tokens = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errs)
function Get-AssignedString([string]$name) {
    $a = $ast.Find({
        param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $n.Left.VariablePath.UserPath -eq $name
    }, $true)
    return $a.Right.Expression.Value
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$csharp = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -match 'class FuItem' }, $true).Value
Add-Type -Language CSharp -TypeDefinition $csharp

[xml]$xaml = (Get-AssignedString 'xamlText').Replace('@@CHECK@@', (Get-AssignedString 'checkColumn'))
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($node in $xaml.SelectNodes('//*[@Name]')) { $ui[$node.Name] = $window.FindName($node.Name) }

function New-Item2($kind, $name, $cat, $cur, $new, $size, $src, $status, $upd = $true) {
    $i = New-Object FuItem
    $i.Kind = $kind; $i.Id = [guid]::NewGuid().ToString(); $i.Name = $name; $i.Category = $cat
    $i.CurrentVersion = $cur; $i.NewVersion = $new; $i.Size = $size; $i.Source = $src; $i.Status = $status
    $i.Updatable = $upd; $i.Selected = $upd
    return $i
}
$drivers = New-Object 'System.Collections.ObjectModel.ObservableCollection[FuItem]'
$drivers.Add((New-Item2 driver 'Realtek PCIe GbE Family Controller' 'Net' '10.68.815.2023  (15.08.2023)' '12.06.2025 tarihli' '1,8 MB' 'Realtek' 'Güncelleme var'))
$drivers.Add((New-Item2 driver 'Intel(R) Wi-Fi 6 AX201 160MHz' 'Net' '22.200.0.6  (12.03.2023)' '04.09.2025 tarihli' '38,2 MB' 'Intel' 'Güncelleme var'))
$drivers.Add((New-Item2 driver 'Realtek High Definition Audio' 'MEDIA' '6.0.9235.1  (20.09.2021)' '18.02.2025 tarihli' '62,4 MB' 'Realtek' 'Güncelleme var'))
$drivers.Add((New-Item2 driver 'AMD SMBus' 'System' '5.12.0.38  (10.01.2022)' '01.07.2025 tarihli' '640 KB' 'Advanced Micro Devices' 'Güncelleme var'))
$drivers.Add((New-Item2 problem 'Bilinmeyen aygıt' 'Sorunlu cihaz' '-' '-' '-' '-' 'Sürücü yüklü değil' $false))
$ui.GridDrivers.ItemsSource = $drivers

$ui.NumDrivers.Text = '4'; $ui.NumProblems.Text = '1 sorunlu cihaz'
$ui.NumHw.Text = '2'; $ui.NumHwTotal.Text = '18 sürücü analiz edildi'
$ui.NumApps.Text = '7'; $ui.NumWindows.Text = '2'
foreach ($b in @(@('Drivers', 5), @('Hw', 2), @('Apps', 7), @('Windows', 2))) { $ui["Cnt$($b[0])"].Text = "$($b[1])"; $ui["Badge$($b[0])"].Visibility = 'Visible' }
$ui.HeroTitle.Text = '13 güncelleme bulundu'
$ui.HeroIcon.Text = [string][char]0xE7BA
$ui.HeroRing.Stroke = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#F59E0B')
$ui.HeroSub.Text = 'Önerilen güncellemeler seçili. Tek tıkla hepsini kurabilir ya da sekmelerden tek tek seçebilirsin.'
$ui.TxtScanBtn.Text = 'Yeniden Tara'
$ui.BtnUpdateAll.IsEnabled = $true; $ui.BtnUpdate.IsEnabled = $true
$ui.TxtVersion.Text = 'v1.2.0'
$ui.TxtPageSub.Text = 'Son tarama: 28.10.2026 10:42'
$ui.TxtStatus.Text = 'Tarama bitti: 4 sürücü, 7 program, 2 Windows güncellemesi. 1 sorunlu cihaz, 2 eski donanım sürücüsü.'
$sys = [ordered]@{ 'İşletim sistemi' = 'Microsoft Windows 11 Pro (10.0.26100)'; 'İşlemci' = 'AMD Ryzen 7 5800X 8-Core Processor'
                   'Ekran kartı' = 'NVIDIA GeForce RTX 3070'; 'Bellek' = '31,9 GB'; 'Anakart' = 'ASUSTeK TUF GAMING B550-PLUS'; 'Sistem diski' = '212 GB boş / 931 GB' }
$ui.SysList.ItemsSource = @($sys.GetEnumerator())

function Invoke-Pump {
    $f = New-Object System.Windows.Threading.DispatcherFrame
    [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background,
        [System.Windows.Threading.DispatcherOperationCallback]{ param($o) $o.Continue = $false; $null }, $f)
    [System.Windows.Threading.Dispatcher]::PushFrame($f)
}

function Save-Shot([string]$file) {
    1..3 | ForEach-Object { Invoke-Pump }
    $window.UpdateLayout()
    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$window.ActualWidth, [int]$window.ActualHeight, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($window)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [System.IO.File]::Create((Join-Path $OutDir $file))
    $enc.Save($fs); $fs.Close()
    Write-Host "Kaydedildi: $file"
}

$window.ShowActivated = $false
$window.WindowStartupLocation = 'Manual'
$window.Left = 0; $window.Top = 0
$window.Show()

$ui.Tabs.SelectedIndex = 0
Save-Shot 'screenshot-home.png'

$ui.NavDrivers.IsChecked = $true
$ui.Tabs.SelectedIndex = 1
$ui.TxtPageTitle.Text = 'Sürücüler'
$ui.TxtPageSub.Text = "Windows Update'teki Microsoft onaylı sürücü güncellemeleri ve sorunlu cihazlar."
$ui.ListBar.Visibility = 'Visible'; $ui.SearchBox.Visibility = 'Visible'
Save-Shot 'screenshot-drivers.png'

$ui.NavTools.IsChecked = $true
$ui.Tabs.SelectedIndex = 5
$ui.TxtPageTitle.Text = 'Araçlar ve Ayarlar'
$ui.TxtPageSub.Text = 'Yedekleme, geri yükleme, rapor ve otomatik çalıştırma.'
$ui.ListBar.Visibility = 'Collapsed'; $ui.SearchBox.Visibility = 'Collapsed'
Save-Shot 'screenshot-tools.png'

$window.Close()
