# NetSource Policy - portable routing engine (v2.1.5)
# Actions: Apply | Install | Uninstall | Status    (optional -Poll = background re-check)
# The engine reads config\config.json and applies interface metrics + persistent routes
# so that the chosen Internet source and the home-LAN priority match the user's rules.

param(
    [ValidateSet('Apply', 'Install', 'Uninstall', 'Status')]
    [string]$Action = 'Apply',
    [switch]$Poll
)

$ErrorActionPreference = 'SilentlyContinue'

$AppRoot  = Split-Path -Parent $PSScriptRoot
$CfgPath  = Join-Path $AppRoot 'config\config.json'
$MofTmpl  = Join-Path $AppRoot 'templates\NetSourcePolicy.mof.template'
$MofOut   = Join-Path $AppRoot '.generated\NetSourcePolicy.mof'
$DataDir  = Join-Path $AppRoot 'data'
$LogDir   = Join-Path $DataDir 'logs'
$LogFile  = Join-Path $LogDir 'netpolicy.log'
$StateFile = Join-Path $DataDir 'state.txt'
$BlockFile = Join-Path $DataDir 'route-blocks.txt'
$ProbeCache = Join-Path $DataDir 'probe-cache.txt'
$MinPollSeconds = 6
$CooldownMin = 3

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path $MofOut) -Force | Out-Null

function Write-Log([string]$m) {
    ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) | Out-File -Append $LogFile
}

function Is-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-Cfg {
    if (-not (Test-Path $CfgPath)) { throw "config.json missing at $CfgPath" }
    Get-Content $CfgPath -Raw | ConvertFrom-Json
}

$lock = [System.Threading.Mutex]::new($false, 'Local\NetSourcePolicyLock')
$owned = $false
try { $owned = $lock.WaitOne(0) } catch {}
if (-not $owned) {
    if ($Action -eq 'Status') { try { Read-Cfg } catch {} }
    if ($Poll) { Write-Log 'poll skipped: engine busy (route lock held by another run)' }
    exit
}
try {
    $Cfg = Read-Cfg
    $EthName = $(if ($Cfg.ethernetInterface) { [string]$Cfg.ethernetInterface } else { 'Ethernet' })
    $LanSubnet = $(if ($Cfg.lanSubnet) { [string]$Cfg.lanSubnet } else { '192.168.0.0/24' })
    $LanEnabled = $(if ($null -ne $Cfg.lanEnabled) { [bool]$Cfg.lanEnabled } else { ([bool]$Cfg.lanSubnet) })
    $EthMetric = $(if ($Cfg.ethernetMetric) { [int]$Cfg.ethernetMetric } else { 5 })
    $Rules = @()
    if ($Cfg.rules) {
        foreach ($r in $Cfg.rules) {
            $Rules += [pscustomobject]@{
                enabled = [bool]$r.enabled
                interface = [string]$r.interface
                ssidPrefix = [string]$r.ssidPrefix
                metricPrefer = [int]$r.metricPrefer
                metricDefault = [int]$r.metricDefault
            }
        }
    } else {
        $ifc = $(if ($Cfg.wifiInterface) { [string]$Cfg.wifiInterface } else { 'Wi-Fi' })
        $pref = $(if ($Cfg.ssidPrefix) { [string]$Cfg.ssidPrefix } else { '<<none>>' })
        $en = $(if ($pref -ne '<<none>>' -and $pref -ne '') { $true } else { $false })
        $mp = $(if ($Cfg.wifiMetricPrefer) { [int]$Cfg.wifiMetricPrefer } else { 1 })
        $md = $(if ($Cfg.wifiMetricDefault) { [int]$Cfg.wifiMetricDefault } else { 50 })
        $Rules += [pscustomobject]@{
            enabled = $en; interface = $ifc; ssidPrefix = $pref; metricPrefer = $mp; metricDefault = $md
        }
    }

    function Reset-Metrics {
        foreach ($r in $Rules) { Set-NetIPInterface -InterfaceAlias $r.interface -InterfaceMetric $r.metricDefault }
        Set-NetIPInterface -InterfaceAlias $EthName -InterfaceMetric $EthMetric
    }

function Probe-Internet {
        # Real connectivity ONLY: ICMP + raw TCP. No DNS-name lookups - AdGuard / a
        # VPN can answer DNS locally while the WAN is dead, which would falsely
        # "prove" Internet and leave a dead pin in force.
        if (Test-Connection -ComputerName '8.8.8.8' -Count 1 -Quiet -ErrorAction SilentlyContinue) { return $true }
        if (Test-Connection -ComputerName '1.1.1.1' -Count 1 -Quiet -ErrorAction SilentlyContinue) { return $true }
        foreach ($ep in @(@('1.1.1.1', 443), @('8.8.8.8', 53))) {
            $c = New-Object System.Net.Sockets.TcpClient
            try {
                $ar = $c.BeginConnect($ep[0], $ep[1], $null, $null)
                if ($ar.AsyncWaitHandle.WaitOne(2000) -and $c.Connected) { return $true }
            } catch {} finally { $c.Close() }
        }
        return $false
    }

# True end-to-end probe THROUGH a specific interface. This actually decides 'does the
    # phone really give Internet right now' instead of trusting Windows' claim that the SSID
    # is 'Internet' (which a hotspot reports even when it has no data).
    function Probe-Via-Source([string]$src, [string]$gw, [int]$ifIndex) {
        # The probe must not leave a trace and must not disturb other traffic: we add a
        # TARGETED temporary route for the probe destination via the chosen interface,
        # test TCP connectivity with a short-timeout socket, then delete the route.
if (-not $src -or -not $gw -or -not $ifIndex) { return $false }
        # Clear any leaked temporary probe route from a previous (interrupted) run, then install.
        cmd.exe /c "route delete 8.8.8.0 mask 255.255.255.0" | Out-Null
        cmd.exe /c "route add 8.8.8.0 mask 255.255.255.0 $gw metric 1 if $ifIndex" | Out-Null
        try {
foreach ($ep in @(@('8.8.8.8', 53), @('1.1.1.1', 443))) {
                $c = New-Object System.Net.Sockets.TcpClient
                try {
                    $ar = $c.BeginConnect($ep[0], $ep[1], $null, $null)
                    if ($ar.AsyncWaitHandle.WaitOne(1500) -and $c.Connected) { return $true }
                } catch {} finally { $c.Close() }
            }
            return $false
        } finally {
            cmd.exe /c "route delete 8.8.8.0 mask 255.255.255.0 $gw" | Out-Null
        }
    }

    # SSID of a Wi-Fi interface. Get-NetConnectionProfile works for both the interactive
    # user and the SYSTEM account under which the WMI polls run (verified). netsh wlan
    # requires location permission + elevation, so it is only a fallback.
function Get-InterfaceSsid([string]$alias) {
        for ($i = 0; $i -lt 3; $i++) {
            try {
                $p = Get-NetConnectionProfile -InterfaceAlias $alias -ErrorAction SilentlyContinue
                if ($p -and $p.Name) { return $p.Name }
            } catch {}
            Start-Sleep -Milliseconds 300
        }
        try {
            foreach ($line in (netsh wlan show interfaces 2>$null)) {
                if ($line -match '^\s*SSID\s*:\s*(.+?)\s*$') { return $Matches[1].Trim() }
            }
        } catch {}
        return ''
    }

    # Cooldown: after a gateway was pinned and proven dead, do not re-pin it for a few minutes,
    # so the engine does not flap between adapters while a hotspot is unstable.
    function Get-Blocks {
        $map = @{}
        if (Test-Path $BlockFile) {
            foreach ($line in (Get-Content $BlockFile -ErrorAction SilentlyContinue)) {
                $p = $line.Split('|')
                if ($p.Count -eq 2) {
                    $u = $null
                    if ([datetime]::TryParse($p[1], [ref]$u)) { $map[$p[0]] = $u }
                }
            }
        }
        return $map
    }

    function Block-Cooldown([string]$gw) {
        $m = Get-Blocks
        return ($m.ContainsKey($gw) -and $m[$gw] -gt (Get-Date))
    }

    function Set-Cooldown([string]$gw) {
        $until = (Get-Date).AddMinutes($CooldownMin).ToString('o')
        $lines = @((Get-Blocks).GetEnumerator() | ForEach-Object { '{0}|{1}' -f $_.Key, $_.Value.ToString('o') })
        $lines += ('{0}|{1}' -f $gw, $until)
Set-Content -Path $BlockFile -Value $lines -ErrorAction SilentlyContinue
    }

    function Get-ProbeFresh([string]$gw, [int]$maxAgeSec) {
        if (-not (Test-Path $ProbeCache)) { return $false }
        $now = [datetime]::UtcNow.Ticks
        $limit = [int64]($maxAgeSec * 10000000)
        foreach ($line in (Get-Content $ProbeCache -ErrorAction SilentlyContinue)) {
            $p = $line.Split('|')
            if ($p.Count -eq 2 -and $p[0] -eq $gw) {
                $ticks = [int64]0
                if ([int64]::TryParse($p[1], [ref]$ticks)) {
                    return (($now - $ticks) -lt $limit)
                }
            }
        }
        return $false
    }

    function Set-ProbeNow([string]$gw) {
        $keep = @()
        if (Test-Path $ProbeCache) {
            foreach ($line in (Get-Content $ProbeCache -ErrorAction SilentlyContinue)) {
                if ($line -and $line -notlike "$gw|*") { $keep += $line }
            }
        }
        Set-Content -Path $ProbeCache -Value $keep -ErrorAction SilentlyContinue
        Add-Content -Path $ProbeCache -Value ('{0}|{1}' -f $gw, [datetime]::UtcNow.Ticks) -ErrorAction SilentlyContinue
    }

    function Get-SourceIp([string]$alias) {
        (Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.AddressState -eq 'Preferred' } | Select-Object -First 1).IPAddress
    }

    function Restore-Internet {
        Remove-PersistentDefaults
        Reset-Metrics
        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
        Write-Log 'EMERGENCY internet restore - pinned routes cleared, Windows back to automatic routing'
    }

function Remove-PersistentDefaults {
        # Only remove DEFAULT routes that WE manage: the gateways of our rule/eth
        # interfaces plus the currently pinned gateway. Never touch persistent
        # routes owned by other software (AdGuard VPN, WireGuard, ...) - deleting
        # theirs used to break their connectivity the moment this engine ran.
        $mine = @{}
        foreach ($r in $Rules) {
            $w = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceAlias $r.interface -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
            if ($w -and $w.NextHop) { $mine[$w.NextHop] = $true }
        }
        $we = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceAlias $EthName -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
        if ($we -and $we.NextHop) { $mine[$we.NextHop] = $true }
        if (Test-Path $StateFile) {
            $sv = (Get-Content $StateFile -Raw).Trim()
            if ($sv -like '*|*') { $mine[($sv -split '\|')[1]] = $true }
        }
        Get-NetRoute -PolicyStore 'PersistentStore' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -and $mine.ContainsKey($_.NextHop) } |
            Remove-NetRoute -PolicyStore 'PersistentStore' -Confirm:$false -ErrorAction SilentlyContinue
        $lp = route print -4 2>$null
        foreach ($row in $lp) {
            if ($row -match '^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+(\d+\.\d+\.\d+\.\d+)\s+\d+$') {
                if ($mine.ContainsKey($Matches[1])) {
                    route -p delete 0.0.0.0 mask 0.0.0.0 $Matches[1] 2>$null | Out-Null
                }
            }
        }
    }

    function Get-LanNetMask {
        $net = $null
        $mask = '255.255.255.0'
        if ($LanSubnet -match '^(\d+\.\d+\.\d+\.\d+)/(\d+)$') {
            $net = $Matches[1]
            $bits = [int]$Matches[2]
            if ($bits -ge 1 -and $bits -le 32) {
                $mv = [uint32]::MaxValue -shl (32 - $bits)
                $mask = '{0}.{1}.{2}.{3}' -f (($mv -shr 24) -band 0xFF), (($mv -shr 16) -band 0xFF), (($mv -shr 8) -band 0xFF), ($mv -band 0xFF)
            }
        }
        return @{ net = $net; mask = $mask }
    }

    # Remove one persistent LAN route pin. Remove-NetRoute may throw 'InterfaceIndex 0'
    # (a known cmdlet limitation for gateway persistent routes); the cmd route fallback
    # always works, exactly like the v1 default-route ghost fix.
    function Remove-LanPin([string]$nextHop) {
        $nm = Get-LanNetMask
        if (-not $nm.net -or -not $nextHop) { return }
        try {
            Get-NetRoute -PolicyStore 'PersistentStore' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.DestinationPrefix -eq $LanSubnet -and $_.NextHop -eq $nextHop } |
                Remove-NetRoute -PolicyStore 'PersistentStore' -Confirm:$false -ErrorAction Stop
        } catch {}
        cmd.exe /c "route -p delete $($nm.net) mask $($nm.mask) $nextHop" | Out-Null
    }

    function Remove-PersistentLan {
        $nm = Get-LanNetMask
        $pins = @(Get-NetRoute -PolicyStore 'PersistentStore' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.DestinationPrefix -eq $LanSubnet })
        foreach ($p in $pins) {
            if ($p.NextHop -and $nm.net) {
                try {
                    Remove-NetRoute -PolicyStore 'PersistentStore' -DestinationPrefix $p.DestinationPrefix -NextHop $p.NextHop -Confirm:$false -ErrorAction Stop
                } catch {}
                cmd.exe /c "route -p delete $($nm.net) mask $($nm.mask) $($p.NextHop)" | Out-Null
            }
        }
        if ($nm.net) {
            $lp = route print -4 2>$null
            foreach ($row in $lp) {
                if ($row -match ("^\s*" + [regex]::Escape($nm.net) + "\s+" + $nm.mask + "\s+(\d+\.\d+\.\d+\.\d+)\s+\d+$")) {
                    route -p delete $nm.net mask $nm.mask $Matches[1] 2>$null | Out-Null
                }
            }
        }
    }

    function State-Sane {
        if ($newState -like '*|*') {
            $parts = $newState.Split('|')
            if ($parts.Count -ne 2 -or -not $parts[0] -or -not $parts[1]) { return $false }
$r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceAlias $parts[0] -ErrorAction SilentlyContinue |
                Where-Object { $_.RouteMetric -le 3 -and $_.NextHop -eq $parts[1] }
            return [bool]$r
        }
        $p = @(Get-NetRoute -PolicyStore 'PersistentStore' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' })
        foreach ($r in $Rules) {
            if (-not $r.enabled -or $r.interface -eq $EthName) { continue }
            $m = (Get-NetIPInterface -InterfaceAlias $r.interface -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).InterfaceMetric
            if ($m -and $m -ne $r.metricDefault) { return $false }
        }
        $em = (Get-NetIPInterface -InterfaceAlias $EthName -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).InterfaceMetric
        return ($p.Count -eq 0 -and ($null -eq $em -or $em -eq $EthMetric))
    }

function Apply-Decision {
        # SELF-HEAL: if a pinned default route is installed but the Internet is unreachable,
        # remove our pins immediately so Windows falls back to the best adapter (usually Ethernet).
        $pinned = @(Get-NetRoute -PolicyStore 'PersistentStore' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' })
        if ($pinned.Count -gt 0 -and -not (Probe-Internet)) {
            Restore-Internet
        }

        $prefer = $null
        $rule = $null
        foreach ($r in $Rules) {
            if (-not $r.enabled) { continue }
            $ad = Get-NetAdapter -Name $r.interface -ErrorAction SilentlyContinue
            if (-not $ad -or $ad.Status -ne 'Up') { continue }
            if ($r.ssidPrefix) {
                $ssidNow = Get-InterfaceSsid $r.interface
                if ($ssidNow -like $r.ssidPrefix) { $rule = $r; $prefer = $ad; break }
            } else {
                $rule = $r; $prefer = $ad; break
            }
        }

        $ssid = ''
        $wifiInternet = $false
        if ($prefer) {
            $ssid = Get-InterfaceSsid $prefer.Name
            try {
                $prof = Get-NetConnectionProfile -InterfaceAlias $prefer.Name -ErrorAction SilentlyContinue
                if ($prof) { $wifiInternet = ($prof.IPv4Connectivity -eq 'Internet') }
            } catch {}
}

        $newState = 'eth'
        if ($prefer -and $prefer.Name -ne $EthName) {
            $gw = $null
            $wroute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceAlias $prefer.Name -ErrorAction SilentlyContinue |
                Sort-Object RouteMetric | Select-Object -First 1
            if ($wroute -and $wroute.NextHop) { $gw = $wroute.NextHop }
            else {
                $ipc = Get-NetIPConfiguration -InterfaceAlias $prefer.Name
                if ($ipc.IPv4DefaultGateway) { $gw = ($ipc.IPv4DefaultGateway | Select-Object -First 1).NextHop }
            }
if ($gw) { $newState = '{0}|{1}' -f $prefer.Name, $gw } else { $newState = 'pending' }
        }

$prevState = ''
        if (Test-Path $StateFile) { $prevState = (Get-Content $StateFile -Raw).Trim() }

        # GATE: only pin the Internet through the preferred adapter when it is PROVEN usable
        # right now, end-to-end THROUGH that interface (not just by Windows' claim and not just
        # by "the gateway answers", which a hotspot always does even with no data).
        # A failed gateway is also kept on cooldown, so we never flap back to it.
        # A gateway proven end-to-end within the last few seconds AND with an unchanged decision
        # is re-used WITHOUT touching the routing table: the per-poll add/delete of the temporary
        # probe route churned the routing table constantly (and, with AdGuard / VPN software
        # monitoring interfaces, triggered momentary drops).  Throttling that churn removes it.
$approved = $prefer -and $prefer.Name -eq $EthName
        if (-not $approved -and $prefer -and $newState -like '*|*') {
            $gw = ($newState -split '\|')[1]
            $src = Get-SourceIp $prefer.Name
            $skipProbe = ($prevState -eq $newState) -and (Get-ProbeFresh $gw 15)
            $liveE2E = $true
            if (-not $skipProbe) {
                $liveE2E = Probe-Via-Source $src $gw $prefer.ifIndex
                Set-ProbeNow $gw
            }
            $blocked = Block-Cooldown $gw
            if ($liveE2E -and -not $blocked) {
                $approved = $true
                if (-not $skipProbe) { Write-Log ("GATE approved pin: iface={0} gw={1} src={2} profile=Internet={3} liveProbe={4}" -f $prefer.Name, $gw, $src, $wifiInternet, $liveE2E) }
            } else {
                Write-Log ("GATE blocked pin: iface={0} gw={1} src={2} profile=Internet={3} liveProbe={4} cooldown={5} - keeping current source" -f $prefer.Name, $gw, $src, $wifiInternet, $liveE2E, $blocked)
                $prefer = $null; $rule = $null; $newState = 'eth'
            }
        }

        # Detection-hiccup guard: if the phone rule did not match ONLY because the SSID could not
        # be read right now, but this adapter is Up, still carries the pinned default route and
        # passes an end-to-end probe through it, keep the current decision instead of yanking the
        # Internet back to the cable (a momentary empty SSID read must never cut your connection).
        if ($prefer -eq $null -and $prevState -like '*|*') {
            $pv = $prevState.Split('|')
            $pvAd = Get-NetAdapter -Name $pv[0] -ErrorAction SilentlyContinue
            $pvRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceAlias $pv[0] -NextHop $pv[1] -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($pvAd -and $pvAd.Status -eq 'Up' -and $pvRoute -and (Probe-Via-Source (Get-SourceIp $pv[0]) $pv[1] $pvAd.ifIndex)) {
                Write-Log ("GATE keep: pin {0} still alive (SSID read unavailable) - source unchanged" -f $prevState)
                return
            }
        }

        # LAN maintenance runs on EVERY poll (also when nothing else changed): re-pin the LAN
        # route to the cable's current IP, or shed it when the cable is not connected.
        if ($LanEnabled) {
            $eth = Get-NetIPAddress -InterfaceAlias $EthName -AddressFamily IPv4 |
                Where-Object { $_.AddressState -eq 'Preferred' } | Select-Object -First 1
            if ($eth) {
                $nm = Get-LanNetMask
                $lanPins = @(Get-NetRoute -PolicyStore 'PersistentStore' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.DestinationPrefix -eq $LanSubnet })
                foreach ($p in $lanPins) {
                    if ($p.InterfaceIndex -ne $eth.InterfaceIndex -or $p.NextHop -ne $eth.IPAddress) {
                        Remove-LanPin $p.NextHop
                    }
                }
$have = Get-NetRoute -PolicyStore 'PersistentStore' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.DestinationPrefix -eq $LanSubnet -and $_.InterfaceIndex -eq $eth.InterfaceIndex }
                if (-not $have -and $nm.net) { route -p add $nm.net mask $nm.mask $eth.IPAddress metric 1 | Out-Null }
            } else {
                Remove-PersistentLan
            }
        } else {
            Remove-PersistentLan
        }

        if ($prevState -eq $newState -and (State-Sane)) { return }

        foreach ($r in $Rules) {
            if (-not $r.enabled) { continue }
            $setTo = $r.metricDefault
            if ($prefer -and $r.interface -eq $prefer.Name) { $setTo = $r.metricPrefer }
            Set-NetIPInterface -InterfaceAlias $r.interface -InterfaceMetric $setTo
        }
        if (-not ($prefer -and $prefer.Name -eq $EthName)) {
            Set-NetIPInterface -InterfaceAlias $EthName -InterfaceMetric $EthMetric
        }

        Remove-PersistentDefaults

        if ($approved -and $newState -like '*|*') {
            $gw = ($newState -split '\|')[1]
            if ($gw) {
                cmd.exe /c "route -p delete 0.0.0.0 mask 0.0.0.0 $gw" | Out-Null
                cmd.exe /c "route -p add 0.0.0.0 mask 0.0.0.0 $gw metric 1 if $($prefer.ifIndex)" | Out-Null
            }
        }

        Set-Content -Path $StateFile -Value $newState
        Write-Log ("CHANGED ssid={0} wifiInternet={1} approvedPin={2} route={3}" -f $ssid, $wifiInternet, $approved, $newState)

# POST-CHECK: after any routing change, verify the Internet still works; if it does not,
        # undo everything so Windows automatic routing takes over (must never stay cut),
        # and put the failed gateway on cooldown so we do not re-pin it next poll.
        # A single slow packet (phone NAT still recovering, AdGuard/VPN filtering a moment) must
        # NOT trigger the emergency restore - that restore itself is what cuts the line. Retry
        # before concluding the route change actually broke the Internet.
        Start-Sleep -Milliseconds 900
        if (-not (Probe-Internet)) {
            $ok = $false
            for ($i = 0; $i -lt 3; $i++) {
                Start-Sleep -Milliseconds 1200
                if (Probe-Internet) { $ok = $true; break }
            }
            if ($ok) {
                Write-Log 'POST-CHECK: first probe hiccup only, Internet confirmed working after retry - nothing changed'
            } else {
                if ($approved -and $newState -like '*|*') { Set-Cooldown (($newState -split '\|')[1]) }
                Restore-Internet
                Start-Sleep -Milliseconds 900
                Write-Log ("POST-CHECK: Internet unreachable after routing change - restored automatic routing, now internetOk={0}" -f (Probe-Internet))
            }
        }
    }

    function Remove-WmiInstances {
        Get-CimInstance -Namespace root\subscription -ClassName __EventFilter |
            Where-Object { $_.Name -like 'NPS_*' -or $_.Name -like 'NetPolicy*' } | Remove-CimInstance
        Get-CimInstance -Namespace root\subscription -ClassName CommandLineEventConsumer |
            Where-Object { $_.Name -like 'NPS_*' -or $_.Name -like 'NetPolicy*' } | Remove-CimInstance
        Get-CimInstance -Namespace root\subscription -ClassName __FilterToConsumerBinding |
            Where-Object { $_.Filter -like '*NPS_*' -or $_.Consumer -like '*NPS_*' -or $_.Filter -like '*NetPolicy*' -or $_.Consumer -like '*NetPolicy*' } | Remove-CimInstance
    }

switch ($Action) {
        'Apply' {
            if ($Poll) {
                $stampPath = Join-Path $LogDir 'lastpoll.txt'
                if (Test-Path $stampPath) {
                    $age = (Get-Date) - (Get-Item $stampPath).LastWriteTime
                    if ($age.TotalSeconds -lt $MinPollSeconds) { return }
                }
                (Get-Date) | Out-File $stampPath
            }
            Apply-Decision
        }
        'Install' {
            if (-not (Is-Admin)) { Start-Process powershell -Verb RunAs -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Action','Install'; return }
            Remove-WmiInstances
            $tmpl = Get-Content $MofTmpl -Raw
            $tmpl = $tmpl.Replace('{{SCRIPT}}', (Join-Path $AppRoot 'src\engine.ps1').Replace('\', '\\'))
            $tmpl = $tmpl.Replace('{{POLL_SECONDS}}', ([int]$Cfg.pollSeconds).ToString())
            Set-Content -Path $MofOut -Value $tmpl -Encoding ASCII
            & mofcomp $MofOut 2>&1 | Out-Null
            Apply-Decision
            Write-Log 'INSTALLED NetSource Policy engine (WMI consumers active)'
        }
        'Uninstall' {
            if (-not (Is-Admin)) { Start-Process powershell -Verb RunAs -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Action','Uninstall'; return }
            Remove-WmiInstances
            Remove-PersistentDefaults
            Remove-PersistentLan
            Reset-Metrics
            if (Test-Path $StateFile) { Remove-Item $StateFile -Force }
            if (Test-Path (Join-Path $LogDir 'lastpoll.txt')) { Remove-Item (Join-Path $LogDir 'lastpoll.txt') -Force }
            if (Test-Path $BlockFile) { Remove-Item $BlockFile -Force }
            Write-Log 'UNINSTALLED NetSource Policy engine'
        }
        'Status' {
            "STATE=" + $(if (Test-Path $StateFile) { (Get-Content $StateFile -Raw).Trim() } else { 'none' })
            "INSTALLED=" + $(try { [bool](Get-CimInstance -Namespace root\subscription -ClassName __EventFilter -Filter "Name='NPS_EventFilter'" -ErrorAction Stop) } catch { 'unknown' })
            "RULES=" + $(($Rules | Where-Object { $_.enabled } | ForEach-Object { $_.interface + ' ~ ' + $_.ssidPrefix }) -join '; ')
            $ads = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Sort-Object ifIndex
            foreach ($a in $ads) {
                $prof = Get-NetConnectionProfile -InterfaceAlias $a.Name -ErrorAction SilentlyContinue
                $conn = if ($prof) { $prof.IPv4Connectivity } else { 'no-profile' }
                $ip = (Get-NetIPAddress -InterfaceAlias $a.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.AddressState -eq 'Preferred' } | Select-Object -First 1).IPAddress
                $ifm = (Get-NetIPInterface -InterfaceAlias $a.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).InterfaceMetric
                $ssid = if ($a.InterfaceDescription -like '*Wireless*') { $prof.Name } else { '' }
                "ADAPTER={0}|{1}|{2}|{3}|metric={4}|{5}" -f $a.Name, $a.LinkSpeed, $conn, $ip, $ifm, $ssid
            }
            $best = Find-NetRoute -RemoteIPAddress '8.8.8.8' -ErrorAction SilentlyContinue | Select-Object -First 1
            "INTERNET=" + $(if ($best) { "$($best.InterfaceAlias)|$($best.IPAddress)" } else { 'none' })
            $r = Get-NetRoute -PolicyStore 'PersistentStore' -AddressFamily IPv4 -ErrorAction SilentlyContinue
            "PERSISTENT=" + $(($r | ForEach-Object { $_.DestinationPrefix + ' via ' + $_.NextHop + ' m' + $_.RouteMetric }) -join '; ')
            "LOGFILE=$LogFile"
        }
    }
}
finally {
    if ($owned) { try { $lock.ReleaseMutex() } catch {} }
    $lock.Dispose()
}


