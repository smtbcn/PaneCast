# PaneCast — Windows tarafını PC'de derleyip koşan hat (derleme PC'de yapılır, ADR-008).
#
# Bu betik yalnız build-host üzerinde çalışır; Mac tarafı scripts/win-build.sh ile çağırır.
# Kişisel değer taşımaz: dev shell yolu vswhere'den çözülür, çıktı klasörü kullanıcı profilidir.
#
# Kullanım: build-win.ps1 <exe-adi> <kaynak dosyaları (panecast-src'ye göre göreli)>
#   örn: build-win.ps1 pairingVectors tools/pairingVectors.cpp src/Crypto.cpp src/Pairing.cpp
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)][string[]]$Sources
)

$ErrorActionPreference = 'Stop'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
# `-products *` olmadan Build Tools görünmüyor (ölçüldü: installationPath boş döndü).
$vsPath = (& $vswhere -latest -products * -property installationPath | Out-String).Trim()
if (-not $vsPath) { Write-Output 'HATA=VS_BuildTools_yok'; exit 2 }
Import-Module (Join-Path $vsPath 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments '-arch=x64' | Out-Null

$src = Join-Path $env:USERPROFILE 'panecast-src'
$out = Join-Path $env:USERPROFILE 'panecast-build'
New-Item -ItemType Directory -Force -Path $out | Out-Null
Set-Location $out

# Bayat exe testi yanıltır: derleme başarısızsa eski haliyle koşabilir (ölçüldü).
Remove-Item (Join-Path $out "$Name.exe") -ErrorAction SilentlyContinue

# Kitap listesi parametre olarak DEĞİL ortamdan gelıyor: `-File` konumsal bağlamada
# ValueFromRemainingArguments ile ikinci parametre çakışıyor (ölçüldü: ilk kaynak /link
# sonrasına düşüyordu).
$libs = if ($env:PANECAST_LIBS) { $env:PANECAST_LIBS -split ' ' } else { @('bcrypt.lib', 'crypt32.lib') }
$clArgs = @('/nologo', '/std:c++17', '/EHsc', '/utf-8', '/W4')
foreach ($s in $Sources) { $clArgs += (Join-Path $src ($s -replace '/', '\')) }
$clArgs += @('/Fe:' + (Join-Path $out "$Name.exe"))
$clArgs += '/link'
$clArgs += $libs

Write-Output ('CL=' + ($clArgs -join ' '))
# cl banner'ı stderr'e yazıyor; PowerShell onu hat kaydı yapar. Derlemeyi duraklatmamak için
# hata tercihi geçici olarak bırakılır ve çıktı düz metin olarak toplanır.
$ErrorActionPreference = 'Continue'
$log = Join-Path $out "$Name.build.log"
& cl @clArgs 2>&1 | ForEach-Object { "$_" } | Out-File -Encoding utf8 $log
if (-not (Test-Path (Join-Path $out "$Name.exe"))) {
    Write-Output 'SONUC=derleme_basarisiz'
    Get-Content $log | Select-Object -First 25
    exit 1
}
Write-Output 'DERLEME=tamam'
& (Join-Path $out "$Name.exe")
Write-Output ('CIKIS=' + $LASTEXITCODE)
exit $LASTEXITCODE
