# ============================================================================
#  NetSource Policy  v2.1.0  -  portable GUI
#  Decide which connection supplies the Internet and set network priorities.
#  Open source (MIT).  (c) 2026 M. Basheer (DigiSphereX)
# ============================================================================

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$AppRoot      = Split-Path -Parent $PSScriptRoot
$Engine       = Join-Path $AppRoot 'src\engine.ps1'
$CfgPath      = Join-Path $AppRoot 'config\config.json'
$LogFile      = Join-Path $AppRoot 'data\logs\netpolicy.log'
$Version      = '2.1.0'

$script:Cfg = $null
$script:Busy = $false

function Normalize-Cfg([object]$raw) {
    if (-not $raw) {
        $raw = [pscustomobject]@{ ssidPrefix = 'My Hotspot*'; wifiInterface = 'Wi-Fi'; ethernetInterface = 'Ethernet'; lanSubnet = '192.168.0.0/24'; autoFallback = $true; pollSeconds = 10; wifiMetricPrefer = 1; wifiMetricDefault = 50; ethernetMetric = 5; lanEnabled = $true }
    }
    $cfg = $null
    if (-not $raw.rules) {
        $legacy = $raw
        $known = 'ssidPrefix', 'wifiInterface', 'ethernetInterface', 'lanSubnet', 'autoFallback', 'pollSeconds', 'wifiMetricPrefer', 'wifiMetricDefault', 'ethernetMetric', 'lanEnabled'
        $match = @($legacy.PSObject.Properties.Name) | Where-Object { $_ -in $known }
        if ($match.Count -eq 0) { throw 'The file does not look like NetSource Policy settings.' }
        $en = $(if ($legacy.ssidPrefix -and $legacy.ssidPrefix -ne '<<none>>') { $true } else { $false })
        $cfg = [pscustomobject]@{
            rules = @([pscustomobject]@{
                enabled = $en
                interface = $(if ($legacy.wifiInterface) { $legacy.wifiInterface } else { 'Wi-Fi' })
                ssidPrefix = $(if ($legacy.ssidPrefix) { $legacy.ssidPrefix } else { '' })
                metricPrefer = $(if ($legacy.wifiMetricPrefer) { [int]$legacy.wifiMetricPrefer } else { 1 })
                metricDefault = $(if ($legacy.wifiMetricDefault) { [int]$legacy.wifiMetricDefault } else { 50 })
            })
            ethernetInterface = $(if ($legacy.ethernetInterface) { $legacy.ethernetInterface } else { 'Ethernet' })
            lanSubnet = $(if ($legacy.lanSubnet) { $legacy.lanSubnet } else { '192.168.0.0/24' })
            lanEnabled = $(if ($null -ne $legacy.lanEnabled) { [bool]$legacy.lanEnabled } else { $true })
            autoFallback = $(if ($null -ne $legacy.autoFallback) { [bool]$legacy.autoFallback } else { $true })
            pollSeconds = $(if ($legacy.pollSeconds) { [int]$legacy.pollSeconds } else { 10 })
            ethernetMetric = $(if ($legacy.ethernetMetric) { [int]$legacy.ethernetMetric } else { 5 })
        }
    } else {
        $cfg = $raw
        $list = New-Object System.Collections.ArrayList
        foreach ($r in @($cfg.rules)) {
            $list.Add([pscustomobject]@{
                enabled = $(if ($null -ne $r.enabled) { [bool]$r.enabled } else { $true })
                interface = $(if ($r.interface) { [string]$r.interface } else { 'Wi-Fi' })
                ssidPrefix = $(if ($null -ne $r.ssidPrefix) { [string]$r.ssidPrefix } else { '' })
                metricPrefer = $(if ($null -ne $r.metricPrefer) { [int]$r.metricPrefer } else { 1 })
                metricDefault = $(if ($null -ne $r.metricDefault) { [int]$r.metricDefault } else { 50 })
            }) | Out-Null
        }
        $cfg.rules = @($list)
        if (-not $cfg.ethernetInterface) { $cfg | Add-Member -NotePropertyName ethernetInterface -NotePropertyValue 'Ethernet' -Force }
        if (-not $cfg.lanSubnet) { $cfg | Add-Member -NotePropertyName lanSubnet -NotePropertyValue '192.168.0.0/24' -Force }
        if ($null -eq $cfg.lanEnabled) { $cfg | Add-Member -NotePropertyName lanEnabled -NotePropertyValue $true -Force }
        if ($null -eq $cfg.autoFallback) { $cfg | Add-Member -NotePropertyName autoFallback -NotePropertyValue $true -Force }
        if (-not $cfg.pollSeconds) { $cfg | Add-Member -NotePropertyName pollSeconds -NotePropertyValue 10 -Force }
        if (-not $cfg.ethernetMetric) { $cfg | Add-Member -NotePropertyName ethernetMetric -NotePropertyValue 5 -Force }
    }
    return $cfg
}

function Load-Cfg {
    if (Test-Path $CfgPath) {
        $script:Cfg = Normalize-Cfg (Get-Content $CfgPath -Raw | ConvertFrom-Json)
    } else {
        $script:Cfg = Normalize-Cfg $null
        Save-Cfg
    }
}

function Save-Cfg {
    $script:Cfg | ConvertTo-Json -Depth 4 | Set-Content -Path $CfgPath -Encoding UTF8
}

function Get-EngineStatus {
    $out = & $Engine -Action Status 2>&1 | ForEach-Object { "$_" }
    return @($out)
}

function Run-Elevated([string]$action) {
    $tmpOut = Join-Path $env:TEMP ("nsp_{0}_{1}.txt" -f $action, $PID)
    $wrapper = Join-Path $AppRoot '.run_elevated.ps1'
    Remove-Item $tmpOut -ErrorAction SilentlyContinue
    Set-Content -Path $wrapper -Value ("& '{0}' -Action '{1}' *> '{2}'; exit `$LASTEXITCODE" -f $Engine, $action, $tmpOut) -Encoding ASCII
    try {
        Start-Process powershell -Verb RunAs -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper -Wait | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("The action was cancelled or elevation failed.`n`n$($_.Exception.Message)", 'NetSource Policy', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return ''
    }
    if (Test-Path $tmpOut) { Get-Content $tmpOut -Raw } else { '' }
}

# ---------------- layout helpers ----------------
function New-Lbl([string]$t, [int]$w, [int]$h, [bool]$bold, [int]$size) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $t; $l.AutoSize = $false; $l.Size = New-Object System.Drawing.Size($w, $h)
    if ($bold) { $l.Font = New-Object System.Drawing.Font('Segoe UI', $size, [System.Drawing.FontStyle]::Bold) }
    else { $l.Font = New-Object System.Drawing.Font('Segoe UI', $size) }
    return $l
}

# ---------------- form ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'NetSource Policy  -  Internet Source & Network Priority Control'
$form.Size = New-Object System.Drawing.Size(880, 690)
$form.MinimumSize = New-Object System.Drawing.Size(760, 600)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$status = New-Object System.Windows.Forms.StatusStrip
$lblStatus = New-Object System.Windows.Forms.ToolStripStatusLabel
$lblStatus.Text = 'Ready'
$lblStatus.AutoSize = $true
$lblLicense = New-Object System.Windows.Forms.ToolStripStatusLabel
$lblLicense.Text = "open source (MIT)  (c) 2026 DigiSphereX"
$lblLicense.Spring = $true
$lblLicense.TextAlign = 'MiddleRight'
$status.Items.Add($lblStatus) | Out-Null
$status.Items.Add($lblLicense) | Out-Null
$form.Controls.Add($status)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$form.Controls.Add($tabs)
$tabs.BringToFront()

# ===== Dashboard =====
$tabDash = New-Object System.Windows.Forms.TabPage
$tabDash.Text = 'Dashboard'
$tabs.TabPages.Add($tabDash)

$dash = New-Object System.Windows.Forms.TableLayoutPanel
$dash.Dock = 'Fill'; $dash.Padding = New-Object System.Windows.Forms.Padding(12)
$dash.ColumnCount = 1; $dash.RowCount = 5
$tabDash.Controls.Add($dash)

$gAdapters = New-Object System.Windows.Forms.GroupBox
$gAdapters.Text = ' Network adapters '
$gAdapters.Dock = 'Fill'
$dash.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 45)))
$dash.Controls.Add($gAdapters, 0, 0)

$lv = New-Object System.Windows.Forms.ListView
$lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.GridLines = $true
$lv.Dock = 'Fill'
$lv.Columns.Add('Interface', 140) | Out-Null
$lv.Columns.Add('Link', 110) | Out-Null
$lv.Columns.Add('Internet', 90) | Out-Null
$lv.Columns.Add('IPv4', 130) | Out-Null
$lv.Columns.Add('Metric', 70) | Out-Null
$lv.Columns.Add('SSID / Network', 180) | Out-Null
$gAdapters.Controls.Add($lv)

$gInfo = New-Object System.Windows.Forms.GroupBox
$gInfo.Text = ' Routing control '
$gInfo.Dock = 'Fill'
$dash.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 35)))
$dash.Controls.Add($gInfo, 0, 1)

$infoFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$infoFlow.Dock = 'Fill'; $infoFlow.Padding = New-Object System.Windows.Forms.Padding(10,6,10,6)
$gInfo.Controls.Add($infoFlow)

$lblEngine = New-Lbl 'Engine: (loading...)' 780 26 $true 11
$lblEngine.ForeColor = [System.Drawing.Color]::DimGray
$infoFlow.Controls.Add($lblEngine)

$lblState = New-Lbl 'Rule in force: (loading...)' 780 24 $false 10
$infoFlow.Controls.Add($lblState)

$lblInternet = New-Lbl 'Internet now goes through: (loading...)' 780 24 $false 10
$infoFlow.Controls.Add($lblInternet)

$lblPersist = New-Lbl 'Persistent routes: (loading...)' 780 24 $false 10
$infoFlow.Controls.Add($lblPersist)

$pnlActions = New-Object System.Windows.Forms.Panel
$pnlActions.Dock = 'Fill'
$dash.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 10)))
$dash.Controls.Add($pnlActions, 0, 2)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = '  Refresh now'
$btnRefresh.AutoSize = $true
$btnRefresh.Anchor = 'Top,Left'
$btnRefresh.Location = New-Object System.Drawing.Point(2, 4)
$pnlActions.Controls.Add($btnRefresh)

$dash.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 10)))
$tipBox = New-Lbl 'Rules are applied instantly through WMI event consumers - no scheduled tasks, no services. You can move this whole folder anywhere; any change is re-applied on the next network event.' 780 40 $false 9
$tipBox.ForeColor = [System.Drawing.Color]::DimGray
$dash.Controls.Add($tipBox, 0, 3)

# ===== Rules =====
$tabRules = New-Object System.Windows.Forms.TabPage
$tabRules.Text = 'Rules & Priority'
$tabs.TabPages.Add($tabRules)

$pan = New-Object System.Windows.Forms.Panel
$pan.Dock = 'Fill'; $pan.AutoScroll = $true
$tabRules.Controls.Add($pan)

$stack = New-Object System.Windows.Forms.FlowLayoutPanel
$stack.Dock = 'Top'; $stack.AutoSize = $true; $stack.Padding = New-Object System.Windows.Forms.Padding(14,10,14,10)
$pan.Controls.Add($stack)

# Internet source rules group - fixed, Dock-based layout to stay stable
$gNet = New-Object System.Windows.Forms.GroupBox
$gNet.Text = ' Internet source rules '
$gNet.Dock = 'Top'
$gNet.Height = 338
$gNet.Padding = New-Object System.Windows.Forms.Padding(8)

$lblRulesHint = New-Lbl 'When the connected network name starts with a rule prefix, the Internet is routed through that interface first. The first matching rule wins - add as many as you need. ( * = any characters )' 810 32 $false 8
$lblRulesHint.Dock = 'Top'
$lblRulesHint.ForeColor = [System.Drawing.Color]::DimGray

$rowRuleBtns = New-Object System.Windows.Forms.FlowLayoutPanel
$rowRuleBtns.Dock = 'Bottom'
$rowRuleBtns.Height = 40
$btnAddRule = New-Object System.Windows.Forms.Button
$btnAddRule.Text = '  + Add rule  '
$btnAddRule.FlatStyle = 'Flat'
$btnAddRule.BackColor = [System.Drawing.Color]::FromArgb(52, 152, 219)
$btnAddRule.ForeColor = [System.Drawing.Color]::White
$btnAddRule.Padding = New-Object System.Windows.Forms.Padding(8)
$btnAddRule.AutoSize = $true
$btnDelRule = New-Object System.Windows.Forms.Button
$btnDelRule.Text = '  Remove selected rule  '
$btnDelRule.FlatStyle = 'Flat'
$btnDelRule.BackColor = [System.Drawing.Color]::FromArgb(231, 76, 60)
$btnDelRule.ForeColor = [System.Drawing.Color]::White
$btnDelRule.Padding = New-Object System.Windows.Forms.Padding(8)
$btnDelRule.AutoSize = $true
$btnDelRule.Margin = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
$rowRuleBtns.Controls.Add($btnAddRule)
$rowRuleBtns.Controls.Add($btnDelRule)

$script:AdapterNames = @(Get-NetAdapter -ErrorAction SilentlyContinue | Sort-Object ifIndex | ForEach-Object { $_.Name })
if ($script:AdapterNames.Count -eq 0) { $script:AdapterNames = @('Wi-Fi', 'Ethernet') }

$script:GvRules = New-Object System.Windows.Forms.DataGridView
$script:GvRules.Dock = 'Fill'
$script:GvRules.AllowUserToAddRows = $false
$script:GvRules.AllowUserToDeleteRows = $false
$script:GvRules.RowHeadersVisible = $false
$script:GvRules.SelectionMode = 'FullRowSelect'
$script:GvRules.MultiSelect = $false
$script:GvRules.AutoSizeColumnsMode = 'Fill'
$script:GvRules.BackgroundColor = [System.Drawing.Color]::White
$script:GvRules.BorderStyle = 'FixedSingle'
$script:GvRules.RowTemplate.Height = 26

$colOn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colOn.HeaderText = 'On'; $colOn.FillWeight = 10; $colOn.MinimumWidth = 36
$colPrefix = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colPrefix.HeaderText = 'Network name starts with ( * = any)'; $colPrefix.FillWeight = 48
$colIface = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
$colIface.HeaderText = 'Route the Internet via'; $colIface.FillWeight = 26
$colIface.Items.AddRange([object[]]$script:AdapterNames)
$colPref = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colPref.HeaderText = 'Prefer metric'; $colPref.FillWeight = 11
$colDef = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colDef.HeaderText = 'Other metric'; $colDef.FillWeight = 11
$script:GvRules.Columns.Add($colOn) | Out-Null
$script:GvRules.Columns.Add($colPrefix) | Out-Null
$script:GvRules.Columns.Add($colIface) | Out-Null
$script:GvRules.Columns.Add($colPref) | Out-Null
$script:GvRules.Columns.Add($colDef) | Out-Null
# dock order matters: Fill first, then edges, so nothing is covered
$gNet.Controls.Add($script:GvRules)
$gNet.Controls.Add($lblRulesHint)
$gNet.Controls.Add($rowRuleBtns)

# place the rules group on top, settings groups below
$pan.Controls.Add($gNet)

# LAN group
$gLan = New-Object System.Windows.Forms.GroupBox
$gLan.Text = ' Home LAN '
$gLan.AutoSize = $true
$gLanLayout = New-Object System.Windows.Forms.FlowLayoutPanel
$gLanLayout.Dock = 'Top'; $gLanLayout.AutoSize = $true; $gLanLayout.Padding = New-Object System.Windows.Forms.Padding(10)
$gLan.Controls.Add($gLanLayout)
$stack.Controls.Add($gLan)

$chkLan = New-Object System.Windows.Forms.CheckBox
$chkLan.Text = 'Always keep the home-LAN traffic on the Ethernet cable.  Subnet (CIDR):'
$chkLan.AutoSize = $true
$gLanLayout.Controls.Add($chkLan)

$rowLan = New-Object System.Windows.Forms.FlowLayoutPanel
$rowLan.AutoSize = $true
$txtLan = New-Object System.Windows.Forms.TextBox
$txtLan.Width = 150
$lblLanHint = New-Lbl '   e.g. 192.168.0.0/24 - keep 0 bits /24 for class C' 330 24 $false 8
$lblLanHint.ForeColor = [System.Drawing.Color]::DimGray
$rowLan.Controls.Add($txtLan); $rowLan.Controls.Add($lblLanHint)
$gLanLayout.Controls.Add($rowLan)

# Reliability group
$gSafe = New-Object System.Windows.Forms.GroupBox
$gSafe.Text = ' Reliability '
$gSafe.AutoSize = $true
$gSafeLayout = New-Object System.Windows.Forms.FlowLayoutPanel
$gSafeLayout.Dock = 'Top'; $gSafeLayout.AutoSize = $true; $gSafeLayout.Padding = New-Object System.Windows.Forms.Padding(10)
$gSafe.Controls.Add($gSafeLayout)
$stack.Controls.Add($gSafe)

$chkFallback = New-Object System.Windows.Forms.CheckBox
$chkFallback.Text = 'If the hotspot is connected but has no Internet (mobile data off), automatically move the Internet to the cable; switch back when it returns.'
$chkFallback.AutoSize = $true
$gSafeLayout.Controls.Add($chkFallback)

$rowLog = New-Object System.Windows.Forms.FlowLayoutPanel
$rowLog.AutoSize = $true
$lblPoll = New-Lbl 'Background re-check every (seconds):' 240 26 $false 9
$numPoll = New-Object System.Windows.Forms.NumericUpDown
$numPoll.Minimum = 5; $numPoll.Maximum = 60; $numPoll.Width = 70
$rowLog.Controls.Add($lblPoll); $rowLog.Controls.Add($numPoll)
$gSafeLayout.Controls.Add($rowLog)

# Priority group
$gMet = New-Object System.Windows.Forms.GroupBox
$gMet.Text = ' Interface priority (route arithmetic: interface metric + route metric, lower wins) '
$gMet.AutoSize = $true
$gMetLayout = New-Object System.Windows.Forms.FlowLayoutPanel
$gMetLayout.Dock = 'Top'; $gMetLayout.AutoSize = $true; $gMetLayout.Padding = New-Object System.Windows.Forms.Padding(10)
$gMet.Controls.Add($gMetLayout)
$stack.Controls.Add($gMet)

$rowM3 = New-Object System.Windows.Forms.FlowLayoutPanel
$rowM3.AutoSize = $true
$rowM3.Controls.Add((New-Lbl 'Ethernet metric (home LAN always uses this adapter, regardless of the Internet source):' 620 26 $false 9))
$numEm = New-Object System.Windows.Forms.NumericUpDown
$numEm.Minimum = 1; $numEm.Maximum = 999; $numEm.Width = 70
$rowM3.Controls.Add($numEm)
$gMetLayout.Controls.Add($rowM3)

$lblNote = New-Lbl 'Note: a hotspot gateway usually advertises a high route metric (around 50). While a hotspot rule matches, the engine adds a persistent default route (metric 1) through that gateway, so its total (~2) stays below Ethernet (~8). That is what makes the icon and the real traffic agree.' 820 44 $false 9
$lblNote.ForeColor = [System.Drawing.Color]::Gray
$stack.Controls.Add($lblNote)

$rowBtns = New-Object System.Windows.Forms.FlowLayoutPanel
$rowBtns.AutoSize = $true; $rowBtns.Padding = New-Object System.Windows.Forms.Padding(0,16,0,0)
$btnApply = New-Object System.Windows.Forms.Button
$btnApply.Text = '  Apply & Install  '
$btnApply.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$btnApply.BackColor = [System.Drawing.Color]::FromArgb(22, 160, 133)
$btnApply.ForeColor = [System.Drawing.Color]::White
$btnApply.Padding = New-Object System.Windows.Forms.Padding(10)
$btnApply.Size = New-Object System.Drawing.Size(180, 40)
$btnApply.FlatStyle = 'Flat'
$btnUninstall = New-Object System.Windows.Forms.Button
$btnUninstall.Text = ' Uninstall / Restore defaults '
$btnUninstall.BackColor = [System.Drawing.Color]::FromArgb(192, 57, 43)
$btnUninstall.ForeColor = [System.Drawing.Color]::White
$btnUninstall.Padding = New-Object System.Windows.Forms.Padding(10)
$btnUninstall.Size = New-Object System.Drawing.Size(200, 40)
$btnUninstall.FlatStyle = 'Flat'
$btnUninstall.Margin = New-Object System.Windows.Forms.Padding(12,0,0,0)
$rowBtns.Controls.Add($btnApply); $rowBtns.Controls.Add($btnUninstall)

$btnExp = New-Object System.Windows.Forms.Button
$btnExp.Text = '  Export settings...  '
$btnExp.BackColor = [System.Drawing.Color]::FromArgb(52, 152, 219)
$btnExp.ForeColor = [System.Drawing.Color]::White
$btnExp.Padding = New-Object System.Windows.Forms.Padding(8)
$btnExp.AutoSize = $true
$btnExp.FlatStyle = 'Flat'
$btnExp.Margin = New-Object System.Windows.Forms.Padding(12,0,0,0)
$btnImp = New-Object System.Windows.Forms.Button
$btnImp.Text = '  Import settings...  '
$btnImp.BackColor = [System.Drawing.Color]::FromArgb(149, 165, 166)
$btnImp.ForeColor = [System.Drawing.Color]::White
$btnImp.Padding = New-Object System.Windows.Forms.Padding(8)
$btnImp.AutoSize = $true
$btnImp.FlatStyle = 'Flat'
$btnImp.Margin = New-Object System.Windows.Forms.Padding(8,0,0,0)
$rowBtns.Controls.Add($btnExp); $rowBtns.Controls.Add($btnImp)
$stack.Controls.Add($rowBtns)

# ===== Log =====
$tabLog = New-Object System.Windows.Forms.TabPage
$tabLog.Text = 'Engine log'
$tabs.TabPages.Add($tabLog)

$log = New-Object System.Windows.Forms.TextBox
$log.Multiline = $true; $log.ReadOnly = $true
$log.ScrollBars = 'Vertical'; $log.Dock = 'Fill'
$log.Font = New-Object System.Drawing.Font('Consolas', 9)
$tabLog.Controls.Add($log)

$btnLog = New-Object System.Windows.Forms.Button
$btnLog.Dock = 'Bottom'; $btnLog.Height = 30; $btnLog.Text = 'Reload log'
$tabLog.Controls.Add($btnLog)

# ===== About =====
$tabAbout = New-Object System.Windows.Forms.TabPage
$tabAbout.Text = 'About'
$tabs.TabPages.Add($tabAbout)

$ab = New-Object System.Windows.Forms.FlowLayoutPanel
$ab.Dock = 'Fill'; $ab.Padding = New-Object System.Windows.Forms.Padding(20); $ab.AutoScroll = $true
$tabAbout.Controls.Add($ab)

$ab.Controls.Add((New-Lbl 'NetSource Policy' 520 32 $true 20))
$ab.Controls.Add((New-Lbl "Version $Version" 520 22 $false 11))
$ab.Controls.Add((New-Lbl '' 520 6 $false 9))
$ab.Controls.Add((New-Lbl 'A portable, open-source tool to choose which connection supplies the Internet (a phone hotspot, any Wi-Fi, or the Ethernet cable) and to keep important traffic - like your home LAN - on the right adapter automatically.' 780 46 $false 10))
$ab.Controls.Add((New-Lbl '' 520 6 $false 9))
$rows = @(
  'How it works',
  ' - engine.ps1 computes the routing decision and applies it via interface metrics + persistent routes.',
  ' - NPS_EventFilter detects network changes instantly (SSID switches, cable unplugged...).',
  ' - NPS_PollFilter silently re-checks Internet availability, so turning your phone data off/on',
  '   moves the Internet to the cable and back automatically.',
  ' - The engine NEVER cuts your Internet: it only pins a source that is proven to work,',
  '   keeps the cable route untouched, and self-restores if anything goes wrong.',
  ' - WMI consumers registered with #PRAGMA AUTORECOVER survive reboots. No scheduled tasks.',
  '',
  'Files (portable)',
  ' - NetSourcePolicy.ps1  ......... this GUI',
  ' - engine.ps1  ................. routing engine (Apply / Install / Uninstall / Status)',
  ' - config\config.json  ......... your rules',
  ' - templates\  ................. WMI subscription template (installed on Apply)',
  ' - data\logs\netpolicy.log  ..... change history',
  '',
  'License: MIT - see LICENSE.  (c) 2026 M. Basheer (DigiSphereX)'
)
foreach ($line in $rows) {
    $pad = $(if ($line.Length -gt 2) { 20 } else { 4 })
    $l = New-Lbl $line 800 $pad ($line -notlike '* - *' -and $line -ne 'How it works' -and $line -ne 'Files (portable)') 9
    if ($line.Length -gt 2 -and $line -notlike ' - *' -and $line -ne 'How it works' -and $line -ne 'Files (portable)') { $l.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold) }
    $ab.Controls.Add($l)
}

# ======================= behaviors =======================
function Build-Rules {
    $list = New-Object System.Collections.ArrayList
    foreach ($row in $script:GvRules.Rows) {
        $en = $false; $prefix = ''; $iface = $script:AdapterNames[0]; $pref = 1; $def = 50
        try { if ($null -ne $row.Cells[0].Value) { $en = [bool]$row.Cells[0].Value } } catch {}
        try { $prefix = ([string]$row.Cells[1].Value).Trim() } catch {}
        try { if ($row.Cells[2].Value) { $iface = [string]$row.Cells[2].Value } } catch {}
        try { $pref = [Math]::Max(1, [int]$row.Cells[3].Value) } catch {}
        try { $def = [Math]::Max(1, [int]$row.Cells[4].Value) } catch {}
        $list.Add([pscustomobject]@{ enabled = $en; interface = $iface; ssidPrefix = $prefix; metricPrefer = $pref; metricDefault = $def }) | Out-Null
    }
    return $list
}

function Set-WidgetsFromCfg {
    $script:GvRules.Rows.Clear()
    if (-not $script:Cfg.rules -or @($script:Cfg.rules).Count -eq 0) {
        $script:Cfg.rules = @([pscustomobject]@{ enabled = $true; interface = $script:AdapterNames[0]; ssidPrefix = ''; metricPrefer = 1; metricDefault = 50 })
    }
    foreach ($r in $script:Cfg.rules) {
        $idx = $script:GvRules.Rows.Add()
        $row = $script:GvRules.Rows[$idx]
        $row.Cells[0].Value = [bool]$r.enabled
        $row.Cells[1].Value = [string]$r.ssidPrefix
        $selIface = [string]$r.interface
        try {
            if ($script:GvRules.Columns[2].Items.Contains($selIface)) { $row.Cells[2].Value = $selIface }
            else { $row.Cells[2].Value = $script:GvRules.Columns[2].Items[0] }
        } catch {
            try { $row.Cells[2].Value = $script:GvRules.Columns[2].Items[0] } catch {}
        }
        $row.Cells[3].Value = [int]$r.metricPrefer
        $row.Cells[4].Value = [int]$r.metricDefault
    }
    $chkLan.Checked = [bool]$script:Cfg.lanEnabled
    $txtLan.Text = $script:Cfg.lanSubnet
    $chkFallback.Checked = [bool]$script:Cfg.autoFallback
    $numPoll.Value = [int]$script:Cfg.pollSeconds
    $numEm.Value = [int]$script:Cfg.ethernetMetric
}

function Refresh-Dashboard {
    if ($script:Busy) { return }
    $script:Busy = $true
    try {
        $lv.Items.Clear()
        $lines = Get-EngineStatus
        foreach ($l in $lines) {
            if ($l -like 'ADAPTER=*') {
                $p = $l.Substring(8).Split('|')
                $it = New-Object System.Windows.Forms.ListViewItem($p[0])
                $it.SubItems.Add($p[1]); $it.SubItems.Add($p[2]); $it.SubItems.Add($p[3]); $it.SubItems.Add($p[4]); $it.SubItems.Add($p[5])
                $lv.Items.Add($it) | Out-Null
            }
            elseif ($l -like 'INTERNET=*') { $lblInternet.Text = 'Internet now goes through:  ' + $l.Substring(9) }
            elseif ($l -like 'STATE=*') { $lblState.Text = 'Rule in force:  ' + $l.Substring(6) }
            elseif ($l -like 'PERSISTENT=*') { $lblPersist.Text = 'Persistent routes:  ' + $l.Substring(11) }
            elseif ($l -like 'INSTALLED=*') {
                $v = $l.Substring(10)
                if ($v -eq 'True') { $lblEngine.Text = 'Engine: INSTALLED - WMI rules active'; $lblEngine.ForeColor = [System.Drawing.Color]::SeaGreen }
                elseif ($v -eq 'unknown') { $lblEngine.Text = 'Engine: installed (confirm as administrator)'; $lblEngine.ForeColor = [System.Drawing.Color]::DarkGoldenrod }
                else { $lblEngine.Text = 'Engine: NOT installed - press Apply & Install'; $lblEngine.ForeColor = [System.Drawing.Color]::Firebrick }
            }
        }
    } catch {
        $lblStatus.Text = "Status refresh failed: $($_.Exception.Message)"
    } finally {
        $script:Busy = $false
    }
}

function Refresh-Log {
    if (Test-Path $LogFile) { $log.Text = Get-Content $LogFile -Tail 400 -ErrorAction SilentlyContinue | Out-String }
    else { $log.Text = 'The engine log does not exist yet - press Apply & Install.' }
}

function Validate-Rules {
    if ($chkLan.Checked -and $txtLan.Text -notmatch '^\d+\.\d+\.\d+\.\d+/(\d+)$') {
        return 'The LAN subnet must look like 192.168.0.0/24.'
    }
    if ($script:GvRules.Rows.Count -eq 0) {
        return 'Add at least one Internet source rule.'
    }
    foreach ($row in $script:GvRules.Rows) {
        $en = $false
        $prefix = ''
        try { if ($null -ne $row.Cells[0].Value) { $en = [bool]$row.Cells[0].Value } } catch {}
        try { $prefix = ([string]$row.Cells[1].Value).Trim() } catch {}
        if ($en -and [string]::IsNullOrWhiteSpace($prefix)) {
            return 'Enter a network-name prefix (e.g. My Hotspot*) for every enabled rule, or uncheck the rule.'
        }
    }
    return $null
}

$btnAddRule.Add_Click({
    try {
        $idx = $script:GvRules.Rows.Add()
        $row = $script:GvRules.Rows[$idx]
        $row.Cells[0].Value = $false
        $row.Cells[1].Value = ''
        try { $row.Cells[2].Value = $script:GvRules.Columns[2].Items[0] } catch {}
        $row.Cells[3].Value = 1
        $row.Cells[4].Value = 50
        ("ADD_OK rows=" + $script:GvRules.Rows.Count) | Set-Content "$env:TEMP\nps_gui_trace.txt"
    } catch {
        ("ADD_ERROR: " + $_.Exception.ToString()) | Set-Content "$env:TEMP\nps_gui_trace.txt"
    }
})

$btnDelRule.Add_Click({
    if ($script:GvRules.SelectedRows.Count -eq 0) { return }
    $rowIdx = $script:GvRules.SelectedRows[0].Index
    $script:GvRules.Rows.RemoveAt($rowIdx)
})

$btnRefresh.Add_Click({ Refresh-Dashboard })
$btnLog.Add_Click({ Refresh-Log })

$btnApply.Add_Click({
    $err = Validate-Rules
    if ($err) { [System.Windows.Forms.MessageBox]::Show($err, 'NetSource Policy', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null; return }
    $script:Cfg.rules = @(Build-Rules)
    $script:Cfg.lanSubnet = $(if ($chkLan.Checked) { $txtLan.Text.Trim() } else { '' })
    $script:Cfg.lanEnabled = [bool]$chkLan.Checked
    $script:Cfg.autoFallback = [bool]$chkFallback.Checked
    $script:Cfg.pollSeconds = [int]$numPoll.Value
    $script:Cfg.ethernetMetric = [int]$numEm.Value
    foreach ($k in @('ssidPrefix', 'wifiInterface', 'wifiMetricPrefer', 'wifiMetricDefault')) {
        if ($script:Cfg.PSObject.Properties[$k]) { $script:Cfg.PSObject.Properties.Remove($k) }
    }
    Save-Cfg
    $lblStatus.Text = 'Applying rules (elevated) - follow the UAC prompt...'
    $out = Run-Elevated 'Install'
    $lblStatus.Text = 'Rules applied.'
    Refresh-Dashboard; Refresh-Log
    if ($out) { $log.Text = ($log.Text + "`r`n--- last apply ---`r`n" + $out) }
})

$btnUninstall.Add_Click({
    $q = [System.Windows.Forms.MessageBox]::Show('Remove all NetSource Policy rules (WMI consumers, persistent routes and priority metrics) and restore Windows defaults?', 'NetSource Policy', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($q -ne 'Yes') { return }
    $lblStatus.Text = 'Uninstalling (elevated) - follow the UAC prompt...'
    $out = Run-Elevated 'Uninstall'
    $lblStatus.Text = 'Uninstalled - network settings restored to defaults.'
    Refresh-Dashboard; Refresh-Log
    if ($out) { $log.Text = ($log.Text + "`r`n--- last uninstall ---`r`n" + $out) }
})

$btnExp.Add_Click({
    $fd = New-Object System.Windows.Forms.SaveFileDialog
    $fd.Title = 'Export NetSource Policy settings'
    $fd.Filter = 'JSON settings (*.json)|*.json'
    $fd.FileName = 'netpolicy-settings.json'
    $fd.InitialDirectory = $AppRoot
    $fd.OverwritePrompt = $true
    if ($fd.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    try {
        $script:Cfg | ConvertTo-Json -Depth 4 | Set-Content -Path $fd.FileName -Encoding UTF8
        $lblStatus.Text = "Settings exported to $($fd.FileName)"
        [System.Windows.Forms.MessageBox]::Show("Settings exported to:`n$($fd.FileName)", 'NetSource Policy - Export', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } catch {
        $lblStatus.Text = 'Export failed.'
        [System.Windows.Forms.MessageBox]::Show("Export failed: $($_.Exception.Message)", 'NetSource Policy - Export', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

$btnImp.Add_Click({
    $od = New-Object System.Windows.Forms.OpenFileDialog
    $od.Title = 'Import NetSource Policy settings'
    $od.Filter = 'JSON settings (*.json)|*.json'
    $od.InitialDirectory = $AppRoot
    if ($od.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    try {
        $raw = Get-Content $od.FileName -Raw | ConvertFrom-Json
        $script:Cfg = Normalize-Cfg $raw
        Set-WidgetsFromCfg
        Save-Cfg
        $lblStatus.Text = "Settings imported from $($od.FileName) - press Apply & Install to put them in force."
        [System.Windows.Forms.MessageBox]::Show("Settings imported from:`n$($od.FileName)`n`nPress 'Apply & Install' (UAC) to put them in force.", 'NetSource Policy - Import', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } catch {
        $lblStatus.Text = 'Import failed - the file is not a valid settings file.'
        [System.Windows.Forms.MessageBox]::Show("Import failed - the file is not a valid NetSource Policy settings file.`n`n$($_.Exception.Message)", 'NetSource Policy - Import', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

# auto-refresh dashboard every 5 s (paused while a dialog is open is not required)
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ Refresh-Dashboard })
$timer.Start()

$form.Add_Shown({
    Load-Cfg
    Set-WidgetsFromCfg
    Refresh-Dashboard
    Refresh-Log
    $form.Activate()
})

$tabs.SelectedIndex = 0
[System.Windows.Forms.Application]::Run($form)