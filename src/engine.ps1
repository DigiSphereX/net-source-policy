# NetSource Policy - portable routing engine
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
$MinPollSeconds = 6

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
        if (Test-Connection -ComputerName '8.8.8.8' -Count 1 -Quiet -ErrorAction SilentlyContinue) { return $true }
        try { if ([System.Net.Dns]::GetHostAddresses('www.github.com')) { return $true } } catch {}
        return $false
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
        Get-NetRoute -PolicyStore 'PersistentStore' -AddressFamily IPv4 |
            Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' } |
            Remove-NetRoute -PolicyStore 'PersistentStore' -Confirm:$false -ErrorAction SilentlyContinue
        $lp = route print -4 2>$null
        foreach ($row in $lp) {
            if ($row -match '^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+(\d+\.\d+\.\d+\.\d+)\s+\d+$') {
                route -p delete 0.0.0.0 mask 0.0.0.0 $Matches[1] 2>$null | Out-Null
            }
        }
    }

    function State-Sane {
        if ($newState -like '*|*') {
            $parts = $newState.Split('|')
            if ($parts.Count -ne 2 -or -not $parts[0] -or -not $parts[1]) { return $false }
            $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceAlias $parts[0] -ErrorAction SilentlyContinue |
                Where-Object { $_.RouteMetric -eq 1 -and $_.NextHop -eq $parts[1] }
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
        return ($p.Count -eq 0 -and $em -eq $EthMetric)
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
            $prof = Get-NetConnectionProfile -InterfaceAlias $r.interface -ErrorAction SilentlyContinue
            if (-not $prof) { continue }
            if ($prof.Name -like $r.ssidPrefix) { $rule = $r; $prefer = $ad; break }
        }

        $ssid = ''
        $wifiInternet = $false
        if ($prefer) {
            $prof = Get-NetConnectionProfile -InterfaceAlias $prefer.Name
            if ($prof) {
                $ssid = $prof.Name
                $wifiInternet = ($prof.IPv4Connectivity -eq 'Internet')
                if ($Cfg.autoFallback -and $prefer.Name -ne $EthName -and -not $wifiInternet) { $prefer = $null; $rule = $null }
            }
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

        # GATE: only pin the Internet through the preferred adapter when it is PROVEN usable right now
        # (profile says Internet AND its gateway answers). Otherwise never touch routing and let
        # Windows keep using the working adapter - the Internet must never be black-holed.
        $approved = $prefer -and $prefer.Name -eq $EthName
        if (-not $approved -and $prefer -and $newState -like '*|*') {
            $gw = ($newState -split '\|')[1]
            $src = Get-SourceIp $prefer.Name
            $gwReachable = $false
            if ($gw -and $src) {
                $gwReachable = [bool](Test-Connection -ComputerName $gw -Source $src -Count 1 -Quiet -ErrorAction SilentlyContinue)
            }
            if ($wifiInternet -and $gwReachable) { $approved = $true }
            else {
                Write-Log ("GATE blocked pin: iface={0} gw={1} src={2} profile=Internet={3} gwReachable={4}" -f $prefer.Name, $gw, $src, $wifiInternet, $gwReachable)
                $prefer = $null; $rule = $null; $newState = 'eth'
            }
        }

        $prevState = ''
        if (Test-Path $StateFile) { $prevState = (Get-Content $StateFile -Raw).Trim() }
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

        if ($LanEnabled) {
            $eth = Get-NetIPAddress -InterfaceAlias $EthName -AddressFamily IPv4 |
                Where-Object { $_.AddressState -eq 'Preferred' } | Select-Object -First 1
            if ($eth) {
                $have = Get-NetRoute -DestinationPrefix $LanSubnet -RouteMetric 1 -InterfaceIndex $eth.InterfaceIndex -ErrorAction SilentlyContinue
                if (-not $have) {
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
                    if ($net) { route -p add $net mask $mask $eth.IPAddress metric 1 | Out-Null }
                }
            }
        } else {
            Get-NetRoute -PolicyStore 'PersistentStore' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.DestinationPrefix -eq $LanSubnet } |
                Remove-NetRoute -PolicyStore 'PersistentStore' -Confirm:$false -ErrorAction SilentlyContinue
        }

        Set-Content -Path $StateFile -Value $newState
        Write-Log ("CHANGED ssid={0} wifiInternet={1} approvedPin={2} route={3}" -f $ssid, $wifiInternet, $approved, $newState)

        # POST-CHECK: after any routing change, verify the Internet still works; if it does not,
        # undo everything so Windows automatic routing takes over (must never stay cut).
        Start-Sleep -Milliseconds 900
        if (-not (Probe-Internet)) {
            Restore-Internet
            Start-Sleep -Milliseconds 900
            Write-Log ("POST-CHECK: Internet unreachable after routing change - restored automatic routing, now internetOk={0}" -f (Probe-Internet))
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
            $eth = Get-NetIPAddress -InterfaceAlias $EthName -AddressFamily IPv4 |
                Where-Object { $_.AddressState -eq 'Preferred' } | Select-Object -First 1
            if ($eth) {
                Get-NetRoute -PolicyStore 'PersistentStore' -AddressFamily IPv4 |
                    Where-Object { $_.DestinationPrefix -eq $LanSubnet } |
                    Remove-NetRoute -PolicyStore 'PersistentStore' -Confirm:$false -ErrorAction SilentlyContinue
            }
            Reset-Metrics
            if (Test-Path $StateFile) { Remove-Item $StateFile -Force }
            if (Test-Path (Join-Path $LogDir 'lastpoll.txt')) { Remove-Item (Join-Path $LogDir 'lastpoll.txt') -Force }
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