# Kinesis cafe network test. Read-only: opens outbound connections, changes nothing.
# Answers what the Spark node needs from a venue's network:
#   - outbound TCP 443 (engine, telemetry, downloads)
#   - outbound UDP on high ports (WireGuard between nodes of a pool)
#   - the NAT's mapping behaviour: if the outside port changes per destination ("symmetric"),
#     two nodes behind such NATs cannot reach each other over WireGuard without a relay.
# Run: irm https://raw.githubusercontent.com/kinesis-network/kinesis-dynamo-releases/cafe-probe/cafe/nettest.ps1 | iex

$ErrorActionPreference = 'Continue'

function Test-Tcp([string]$hostName, [int]$port) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $t = $c.ConnectAsync($hostName, $port)
        if ($t.Wait(5000) -and $c.Connected) { 'ok' } else { 'TIMEOUT' }
    } catch { "FAIL $($_.Exception.InnerException.Message)" } finally { $c.Dispose() }
}

# One STUN binding request (RFC 5389) from the given socket; returns "ip:port" as the server saw it.
function Get-StunMapping([System.Net.Sockets.UdpClient]$udp, [string]$hostName, [int]$port) {
    try {
        $ip = [System.Net.Dns]::GetHostAddresses($hostName) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
        if (-not $ip) { return 'NO-DNS' }
        $ep = New-Object System.Net.IPEndPoint($ip, $port)
        $tid = New-Object byte[] 12; (New-Object Random).NextBytes($tid)
        $req = [byte[]](0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42) + $tid
        for ($try = 0; $try -lt 3; $try++) {
            [void]$udp.Send($req, $req.Length, $ep)
            $task = $udp.ReceiveAsync()
            if (-not $task.Wait(2000)) { continue }
            $b = $task.Result.Buffer
            $i = 20
            while ($i + 4 -le $b.Length) {
                $type = ($b[$i] -shl 8) -bor $b[$i + 1]
                $len = ($b[$i + 2] -shl 8) -bor $b[$i + 3]
                $v = $i + 4
                if ($type -eq 0x0020 -and $b[$v + 1] -eq 1) {
                    $p = ((($b[$v + 2] -shl 8) -bor $b[$v + 3]) -bxor 0x2112)
                    $a = @(($b[$v + 4] -bxor 0x21), ($b[$v + 5] -bxor 0x12), ($b[$v + 6] -bxor 0xA4), ($b[$v + 7] -bxor 0x42)) -join '.'
                    return "${a}:$p"
                }
                if ($type -eq 0x0001 -and $b[$v + 1] -eq 1) {
                    $p = ($b[$v + 2] -shl 8) -bor $b[$v + 3]
                    return "$($b[$v + 4]).$($b[$v + 5]).$($b[$v + 6]).$($b[$v + 7]):$p"
                }
                $i = $v + $len + ((4 - ($len % 4)) % 4)
            }
            return 'NO-MAPPING-IN-REPLY'
        }
        'TIMEOUT'
    } catch { "FAIL $($_.Exception.Message)" }
}

"Kinesis cafe network test  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  host=$env:COMPUTERNAME"
$local = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -ne 'WellKnown' -and $_.IPAddress -notlike '172.*' } | Select-Object -ExpandProperty IPAddress) -join ','
"local_ipv4=$local"
""
"[tcp]"
foreach ($t in @(@('ingest.spark.dynamo.kinesis.network', 443), @('github.com', 443), @('portal.kinesis.network', 443), @('ingest.spark.dynamo.kinesis.network', 80))) {
    "tcp $($t[0]):$($t[1]) $(Test-Tcp $t[0] $t[1])"
}
""
"[udp]"
$dns = try { if (Resolve-DnsName github.com -Server 1.1.1.1 -DnsOnly -Type A -QuickTimeout -ErrorAction Stop) { 'ok' } } catch { "FAIL $($_.Exception.Message)" }
"udp dns 1.1.1.1:53 $dns"

$servers = @(@('stun.l.google.com', 19302), @('stun.cloudflare.com', 3478), @('stun1.l.google.com', 19302))
$udp = New-Object System.Net.Sockets.UdpClient(0)
$localPort = ($udp.Client.LocalEndPoint).Port
$maps = @()
foreach ($s in $servers) {
    $m = Get-StunMapping $udp $s[0] $s[1]
    "udp stun $($s[0]):$($s[1]) from local port $localPort -> seen as $m"
    if ($m -match '^\d+\.\d+\.\d+\.\d+:\d+$') { $maps += $m }
}
$udp.Dispose()
""
"[verdict]"
if ($maps.Count -eq 0) {
    'UDP: BLOCKED - no STUN server answered on UDP 19302 or 3478. WireGuard between nodes will not work from this network.'
} else {
    'UDP: outbound high-port UDP works.'
    $publicIp = ($maps[0] -split ':')[0]
    "public_ipv4=$publicIp"
    if (($maps | ForEach-Object { ($_ -split ':')[1] } | Sort-Object -Unique).Count -eq 1) {
        $samePort = ($maps[0] -split ':')[1] -eq "$localPort"
        "NAT: same outside port for every destination (endpoint-independent mapping)$(if ($samePort) { ', and it kept the local port' }). WireGuard can work with keepalives."
    } else {
        'NAT: SYMMETRIC - the outside port changes per destination. Two nodes behind NATs like this cannot reach each other directly over WireGuard; a relay or a forwarded port is needed.'
    }
}
