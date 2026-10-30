# PaneCast — Windows yayıncı ön koşul kırısı (Faz 0, birinci bölüm: araç zinciri ve ortam)
#
# Amaç: Windows tarafında hangi API'nin FİİLEN kullanılabildiğini ölçmeden kod yazmamak.
# Bu betik yalnız okur; hiçbir şey kurmaz, hiçbir ayarı değiştirmez.
#
# Koşum (Mac'ten):  ssh <build-host> 'powershell -NoProfile -File probe.ps1'
#           ya da PC'de:  powershell -NoProfile -ExecutionPolicy Bypass -File .\win-env-probe.ps1
#
# Çıktı satırları `ALAN=değer` biçimindedir: Mac tarafındaki betikler bunu okur.
# Cihaz/ağ kimliği (SSID, makine adı, IP) BİLREK olarak basılmaz — depo açık kaynak.

$ErrorActionPreference = 'SilentlyContinue'

function Line([string]$k, $v) { '{0}={1}' -f $k, $v }

# --- işletim sistemi ve donanım -------------------------------------------------
$os = Get-CimInstance Win32_OperatingSystem
Line 'OS_BUILD' $os.BuildNumber                     # process-loopback sesi için >= 20348 gerekir
Line 'OS_CAPTION' $os.Caption
$cs = Get-CimInstance Win32_ComputerSystem
Line 'CPU_LOGICAL' $cs.NumberOfLogicalProcessors
Line 'RAM_GB' ([math]::Round($cs.TotalPhysicalMemory / 1GB, 1))
Get-CimInstance Win32_VideoController | ForEach-Object {
    # AdapterRAM 32 bit sayaçtır: 4 GB kartlar 1 GB görünebilir — ölçüm olarak olduğu gibi yazılıyor.
    Line 'GPU' ($_.Name + '|driver=' + $_.DriverVersion + '|adapterRAM_mb=' + [math]::Round($_.AdapterRAM / 1MB))
}

# --- kabuk ve dil zaman damgası -------------------------------------------------
Line 'PS_VERSION' $PSVersionTable.PSVersion.ToString()
Line 'UI_CULTURE' ([System.Globalization.CultureInfo]::CurrentUICulture.Name)
# Konsol kod sayfası Türkçe metni bozabildiği için ölçülüyor: çıktı dosyaya alınınca gerekiyor.
Line 'CONSOLE_CP' ([System.Text.Encoding]::Console.OutputEncoding.WebName)

# --- derleyici ------------------------------------------------------------------
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path $vswhere) {
    # `-products *` olmadan Build Tools görünmüyor (ölçüldü: installationPath boş döndü).
    $vsPath = (& $vswhere -latest -products * -property installationPath | Out-String).Trim()
    Line 'VS_PATH' $vsPath
    if ($vsPath) {
        $devshell = Join-Path $vsPath 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll'
        if (Test-Path $devshell) {
            Import-Module $devshell
            Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments '-arch=x64' | Out-Null
            $cl = (& cl /BANNER 2>&1 | Select-Object -First 1 | Out-String).Trim()
            Line 'CL' $cl
            Line 'LINK' ((& link /SHOWCONFIG 2>&1 | Select-Object -First 1 | Out-String).Trim())
        }
        Line 'VC_TOOLS' ((& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Out-String).Trim() -ne '')
    }
} else { Line 'VS_PATH' 'VSWHERE_YOK' }

# --- Windows SDK: Media Foundation + WinRT başlık ve import kütüphaneleri -------
$kitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$sdkDirs = Get-ChildItem (Join-Path $kitsRoot 'Lib') -Directory | Sort-Object Name -Descending
if ($sdkDirs) {
    $sdk = $sdkDirs[0].Name
    Line 'SDK_VERSION' $sdk
    foreach ($lib in @('mfplat.lib', 'mf.lib', 'mfreadwrite.lib', 'mfuuid.lib', 'windowsapp.lib', 'strmiids.lib', 'mincore.lib', 'mfsensorgroup.lib')) {
        Line ('LIB_' + ($lib -replace '\.lib', '')) (Test-Path (Join-Path $kitsRoot "Lib\$sdk\um\x64\$lib"))
    }
    foreach ($h in @('um\mfapi.h', 'um\mfidl.h', 'um\mftransform.h', 'um\audioengineactivation.h', 'winrt\windows.graphics.capture.h', 'winrt\windows.foundation.h', 'um\d3d11_4.h')) {
        Line ('HDR_' + (Split-Path $h -Leaf)) (Test-Path (Join-Path $kitsRoot "Include\$sdk\$h"))
    }
} else { Line 'SDK_VERSION' 'YOK' }

# --- ses ve ağ ------------------------------------------------------------------
Line 'SVC_Audiosrv' (Get-Service Audiosrv).Status
Line 'AUDIO_SINK_COUNT' ((Get-CimInstance Win32_SoundDevice | Measure-Object).Count)
Get-NetConnectionProfile | ForEach-Object {
    # Public profilinde Windows Firewall gelen bağlantıları varsayılan olarak keser:
    # TCP 7610 (TV'nin bilgisayarı araması) ve UDP 5353 (DNS-SD) bundan etkilenir.
    Line 'NET_CATEGORY' $_.NetworkCategory
    Line 'NET_INTERFACE_METRIC' $_.InterfaceMetric
}
Get-NetFirewallProfile | ForEach-Object { Line ('FW_' + $_.Name) ($_.Enabled.ToString() + '/defaul inbound=' + $_.DefaultInboundAction) }
Line 'FW_RULE_7610' ((Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '7610|Pane' } | Measure-Object).Count)

# --- medya yakalama yeteneği ----------------------------------------------------
Line 'WGC_SUPPORTED' ((Get-CimInstance Win32_OperatingSystem).BuildNumber -ge 17134)  # Windows.Graphics.Capture: 1803+
Line 'PROCESS_LOOPBACK_SUPPORTED' ((Get-CimInstance Win32_OperatingSystem).BuildNumber -ge 20348)

Line 'DONE' 'true'
