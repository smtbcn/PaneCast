# PaneCast — Windows'tan alıcıya kontrol kanalı yoklaması (Faz 1'in ağ ön koşulu)
#
# Amaç: Windows tarafı TV'nin TCP 7601'ine gerçekten erişebiliyor mu ve `hello` çerçevesi
# beklenen yanıtı veriyor mu — C++ ControlClient yazmadan önce bilginin kendisini ölç.
# Kişisel değer taşımaz: TV adresi parametre olarak verilir (Mac tarafı env.local.sh'ten okur).
#
# Kullanım: net-probe.ps1 -TvIp 192.0.2.10 [-DeviceId <16 karakter base64url>]
param(
    [Parameter(Mandatory = $true)][string]$TvIp,
    [string]$DeviceId = ''
)

function Ask([string]$label, [string]$payload) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $c.Connect($TvIp, 7601)
        $s = $c.GetStream()
        $w = New-Object System.IO.StreamWriter($s)
        $w.NewLine = "`n"
        $w.Write($payload + "`n")
        $w.Flush()
        $r = New-Object System.IO.StreamReader($s)
        $c.ReceiveTimeout = 8000
        $line = $r.ReadLine()
        Write-Output ($label + '=' + $line)
    } catch {
        Write-Output ($label + '=HATA ' + $_.Exception.Message)
    } finally {
        $c.Close()
    }
}

# 1) Eski yayıncı gibi: idsiz hello → challenge ya da pair_required beklenir.
Ask 'IDSIZ' ('{"t":"hello","name":"pane-win-probe","ver":2}')

# 2) Yeni yayıncı gibi: device_id ile hello.
if ($DeviceId -ne '') {
    Ask 'KIMLIKLI' ('{"t":"hello","name":"pane-win-probe","ver":2,"device_id":"' + $DeviceId + '"}')
} else {
    Write-Output 'KIMLIKLI=parametre verilmedi'
}

# 3) Bozuk JSON: alıcı `denied/bad_json` yazıp kapatmalı (§3, satır tavanı/JSON kuralı).
Ask 'BOZUK' '{t:hello'

# 4) Ping: doğrulamasız canlılık, durum değiştirmez.
Ask 'PING' '{"t":"ping","now":1}'
