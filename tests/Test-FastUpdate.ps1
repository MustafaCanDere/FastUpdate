<#
    FastUpdate testleri (Windows PowerShell 5.1)
    - Ana betik ve içindeki tüm iş kodları sözdizimi hatası içermiyor mu?
    - winget tablo ayrıştırıcısı İngilizce/Türkçe çıktıları doğru okuyor mu?
    - Arayüz (XAML) ve C# sınıfı yükleniyor mu?
#>
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '..\FastUpdate.ps1' | Resolve-Path
$failed = 0
function Assert($cond, [string]$msg) {
    if ($cond) { Write-Host "  [OK]   $msg" -ForegroundColor Green }
    else { Write-Host "  [HATA] $msg" -ForegroundColor Red; $script:failed++ }
}

Write-Host "Sözdizimi"
$tokens = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errs)
Assert ($errs.Count -eq 0) "FastUpdate.ps1 ayrıştırıldı ($($errs.Count) hata)"
$errs | ForEach-Object { Write-Host "         $($_.Extent.StartLineNumber): $($_.Message)" }

function Get-AssignedString([string]$name) {
    $a = $ast.Find({
        param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $n.Left.VariablePath.UserPath -eq $name
    }, $true)
    if ($a) { return $a.Right.Expression.Value }
    return $null
}

$jobs = 'CoreCode', 'ScanDriversCode', 'ScanAppsCode', 'ScanWindowsCode', 'UpdateWuCode', 'UpdateAppsCode',
        'UpdateVendorCode', 'BackupDriversCode', 'RestoreDriversCode', 'RestorePointCode'
foreach ($j in $jobs) {
    $code = Get-AssignedString $j
    if (-not $code) { Assert $false "$j bulunamadı"; continue }
    $e = $null; $t = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$t, [ref]$e)
    Assert ($e.Count -eq 0) "$j sözdizimi"
    $e | ForEach-Object { Write-Host "         $($_.Extent.StartLineNumber): $($_.Message)" }
}

Write-Host "winget ayrıştırıcı"
$sync = [hashtable]::Synchronized(@{ Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'; Result = $null })
. ([scriptblock]::Create((Get-AssignedString 'CoreCode')))

$en = @(
    "   - `b \ `b",
    "`r   `rName                    Id                           Version       Available      Source",
    "------------------------------------------------------------------------------------------------",
    "Google Chrome           Google.Chrome                129.0.6668.90 130.0.6723.70  winget",
    "7-Zip 23.01 (x64)       7zip.7zip                    23.01         24.08          winget",
    "Microsoft Visual C++ 2… Microsoft.VCRedist.2015+.x64 14.38.33130.0 14.40.33810.0  winget",
    "3 upgrades available.",
    "",
    "The following packages have an upgrade available, but require explicit targeting for upgrade:")
$r = @(ConvertFrom-WingetTable $en)
Assert ($r.Count -eq 3) "İngilizce: 3 paket ($($r.Count))"
Assert ($r[0].Id -eq 'Google.Chrome' -and $r[0].Available -eq '130.0.6723.70') "İngilizce: Chrome kimliği ve sürümü"
Assert ($r[2].Id -eq 'Microsoft.VCRedist.2015+.x64' -and $r[2].Version -eq '14.38.33130.0') "İngilizce: kısaltılmış adlı satır"

$tr = @(
    "Ad                      Kimlik                       Sürüm         Kullanılabilir Kaynak",
    "------------------------------------------------------------------------------------------",
    "Notepad++ (64-bit x64)  Notepad++.Notepad++          8.6.9         8.7.1          winget",
    "Discord                 Discord.Discord              1.0.9163      1.0.9170       winget",
    "2 yükseltme kullanılabilir.")
$r = @(ConvertFrom-WingetTable $tr)
Assert ($r.Count -eq 2) "Türkçe: 2 paket ($($r.Count))"
Assert ($r[1].Id -eq 'Discord.Discord' -and $r[1].Available -eq '1.0.9170' -and $r[1].Source -eq 'winget') "Türkçe: Discord satırı"

$none = @(ConvertFrom-WingetTable @('No installed package found matching input criteria.'))
Assert ($none.Count -eq 0) "Güncelleme yokken boş liste"

Write-Host "Arayüz"
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$csharp = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -match 'class FuItem' }, $true).Value
try { Add-Type -Language CSharp -TypeDefinition $csharp; Assert $true "FuItem sınıfı derlendi" } catch { Assert $false "FuItem: $($_.Exception.Message)" }

$xamlText = (Get-AssignedString 'xamlText').Replace('@@CHECK@@', (Get-AssignedString 'checkColumn'))
try {
    [xml]$xaml = $xamlText
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    $names = @($xaml.SelectNodes('//*[@Name]') | ForEach-Object { $_.Name })
    $missing = @($names | Where-Object { -not $w.FindName($_) })
    Assert ($missing.Count -eq 0) "XAML yüklendi, $($names.Count) adlandırılmış öğe bulundu"
} catch { Assert $false "XAML: $($_.Exception.Message)" }

Write-Host ""
if ($failed) { Write-Host "$failed test başarısız." -ForegroundColor Red; exit 1 }
Write-Host "Tüm testler geçti." -ForegroundColor Green
