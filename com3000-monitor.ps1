<#
  COM3000 Channel Monitor
  -----------------------
  Reads the COM3000 Overview page and sends a phone push notification (via the
  free ntfy app) when a channel's bitrate drops out, using the virtual channel
  and channel name from the page. Also watches the cards and the COM3000 itself.

  Usage (in PowerShell, from the folder this file is in):
    .\com3000-monitor.ps1 -Test        # read the page once, show every channel, send a test alert
    .\com3000-monitor.ps1 -Install     # run every few minutes in the background (Run as Administrator)
    .\com3000-monitor.ps1 -Uninstall   # stop the background monitor (Run as Administrator)
    .\com3000-monitor.ps1 -Pause 30    # no alerts for the next 30 minutes (planned reboot / card reset)
    .\com3000-monitor.ps1 -Resume      # end a pause early
    .\com3000-monitor.ps1 -Status      # show what's being watched right now (no alerts, changes nothing)
    .\com3000-monitor.ps1 -Setup       # ask for location name + COM3000 IP, test, then install
                                       (this is what "Install COM3000 Monitor.bat" runs)
    .\com3000-monitor.ps1 -BackupNow   # save the TuneAll + EPG backup right now (Backup Now.bat)
    .\com3000-monitor.ps1 -SyncDrive   # copy new backups to Google Drive (runs on its own)
    .\com3000-monitor.ps1 -ResetCard   # reset panel: a button per card + whole COM3000 (COM3000 Reset icon)
    .\com3000-monitor.ps1 -Picker      # Channel Check window: step through channels in VLC (Channel Check.bat)
    .\com3000-monitor.ps1 -SendTest    # just send a test notification to the phones
                                       (this is what "Send Test Alert.bat" runs)
#>
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Test,
    [int]$Pause = 0,
    [switch]$Resume,
    [switch]$Status,
    [switch]$Setup,
    [switch]$SendTest,
    [switch]$BackupNow,
    [switch]$SyncDrive,
    [switch]$Picker,
    [switch]$ResetCard,
    [switch]$ClearResets,
    [switch]$MakeEpg,
    [switch]$RefreshEpg,
    [switch]$OpenBlades,
    [switch]$ShowIp,
    [switch]$SetWallpaper
)

# ======================== SETTINGS ========================
# Name of this location - shown at the start of every alert
$SiteName        = 'Location Name Here'

# The COM3000 Overview page (same address you open in Chrome)
$PageUrl         = 'http://192.168.3.18/cgi-bin/webcmd?screen=Overview'

# ntfy topic: install the "ntfy" app on your phone and subscribe to this exact name.
# Anyone who knows the name can see alerts, so keep it hard to guess.
$NtfyTopic       = 'com3000-alerts-x7q4m2'
$NtfyServer      = 'https://ntfy.sh'

# A channel reading below this many Mbps counts as "out"
$MinMbps         = 0.5

# How long something must stay down before you're alerted, in minutes.
# A COM reboot or card reset that comes back within this time won't alert.
$MinutesBeforeAlert = 10
# Only a few channels out (a channel or two dipping low for a while): no phone alert unless at least
# this many are out at once ... or one of them stays out this many minutes (0 = never alert for just a few).
$MinChannelsOut     = 3
$FewChannelsMinutes = 180      # 3 hours - a blacked-out game shouldn't set off every phone
# Rain fade: channels dropping on 3+ cards at once while the cards are fine = weak satellite signal.
# No phone alerts (and no card resets) for that - unless it goes on this many hours (0 = never alert).
$RainFadeHours      = 3
# Self-update: about once an hour, fetch the newest com3000-monitor.ps1 from the dashboard's GitHub page
# and swap it in if it's a NEWER version (checked for errors first; the old copy is kept). 'off' to stop.
$AutoUpdate         = 'on'
$UpdateUrl          = 'https://shanepierce1.github.io/com3000-dashboard/com3000-monitor.ps1'

# How many good checks in a row before something counts as "back" (stops a flickering
# card or a storm from sending out/back/out/back over and over)
$ChecksToRecover = 3

# While something stays down, send a reminder this often, in minutes (0 = no reminders)
$ReminderMinutes = 60

# Channels get just an 'out' and a 'back' alert - no 'still down' reminders (the dashboard shows
# what's still out). Cards offline and the COM3000 not answering still get reminders.
# 'on' = remind about channels too.
$ChannelReminders = 'off'

# How often to check, in minutes (used by -Install)
$IntervalMinutes = 2

# When a channel assignment changes (e.g. 3-0 goes from CNNHD to FNCHD):
#   'phone' = quiet phone notification (no sound) + desktop log
#   'log'   = desktop log only
#   'off'   = don't report changes
$ChannelChanges  = 'phone'

# Every channel on the Overview page is watched automatically.
# List any you DON'T want watched - by virtual channel or name, e.g. @('4-0', 'KABB', '359 FBNHD')
$IgnoreChannels  = @()

# Channels the COM3000 makes from an outside stream (e.g. an HDMI encoder), by their EPG name,
# with the address VLC can play directly. Set by the installer, e.g.
#   @{ 'AspenTrail_Internal_Channel' = 'udp://@239.100.2.226:769' }
$InternalStreams = @{}

# DASHBOARD: send a short status report (cards, channels out, resets) to a separate ntfy
# topic every 15 minutes and whenever something changes. Phones don't subscribe to it -
# the COM3000 Dashboard page reads it. 'on' or 'off'.
$StatusReports = 'on'

# AUTOMATIC CARD RESET: when a card is still there but ALL its channels have no bitrate for this
# many minutes, reset that card (at most once per card per day). 0 = off.
$CardResetMinutes = 0
# The COM3000 command that resets one whole card - the same as the Reset button on a tuner's
# CardEdit page. {ip} = the card's address, {com} = the COM3000 address. If this is set to '',
# resets run in PRACTICE mode: you get a "would reset now" alert instead of a real reset.
$CardResetCommand = 'http://{com}/cgi-bin/webcmd?screen=resetIp&resetIp={ip}'

# WHOLE COM3000 RESET: the COM3000's backend switch (WebStaX) - Maintenance > Restart Device.
# Set by the installer. Address '' = not set up (button off, no automatic resets).
$SystemResetHost     = ''
$SystemResetUser     = ''
$SystemResetSecret   = ''      # the password, encrypted for this PC only (never plain text)
# Reset the whole COM3000 when a card has been MISSING this many minutes (once per day). 0 = off.
$SystemResetMinutes  = 0

# DAILY BACKUP of the TuneAll "Current Tuning Table" and the EPG list.
# One file per site, replaced with the latest copy each day.
# Time of day as 24-hour HH:mm (e.g. '03:00'), or 'off'
$BackupTime      = '03:00'

# DAILY PC REBOOT: restart this PC once a day at this time (24-hour HH:mm, e.g. '04:30'), or 'off'.
$RebootTime      = 'off'
# When this PC loses the internet, try to fix it itself: restart the network connection, then renew
# its address, then restart the PC (at most twice a day).
$NetRepair       = 'on'
# Plain desktop background with the location name, so the desktop icons are easy to see ('blue', 'gray' or 'off')
$Wallpaper       = 'blue'
# Other pages the 'COM3000 Blades' icon opens after the blades, e.g. a streamer: '192.168.3.200' (comma-separated, or blank)
$ExtraTabs       = ''

# DAILY EPG REFRESH: every morning re-submit each blade's EPG page exactly as it is (same list,
# same checkboxes) - like pressing Submit - so AEP boxes reload the guide. 24-hour HH:mm or 'off'.
# Phone alert only if it fails.
$EpgRefreshTime   = 'off'
# Which blades (IP addresses, comma-separated). Blank = every blade that has an EPG list.
$EpgRefreshBlades = ''
# IP address of the EPG page, if it isn't on the COM3000 itself ('' = same as the COM3000)
$EpgIp           = ''
# Google Drive folder. 'auto' = My Drive\COM3000 Backups\<location name>
$DriveFolder     = 'auto'

# CARDS: the tuner cards (slots) and the QAM card are found on the Overview page
# automatically and checked on the network. Set this to $false to turn that off.
$WatchCards      = $true

# Extra devices to check on the network (optional)
# Each line is  'IP address' = 'Name you want in the alert'. Remove the # to turn a line on.
$Cards = [ordered]@{
#   '192.168.3.50' = 'Router'
}

# Only fill these in if the page asks for a login
$Username        = ''
$Password        = ''
# ==========================================================

# This site's answers from "Install COM3000 Monitor" are kept in com3000-settings.ps1
# next to this script, so replacing this script with a newer version keeps them.
$SettingsFile = Join-Path (Split-Path -Parent $PSCommandPath) 'com3000-settings.ps1'
if (Test-Path $SettingsFile) { . $SettingsFile }

# -Status: show everything like -Test, but send nothing and change nothing
$ReadOnly = [bool]$Status
if ($Status) { $Test = $true }

$ChecksToAlert = [Math]::Max(1, [int][Math]::Ceiling($MinutesBeforeAlert / $IntervalMinutes))
$TaskName  = 'COM3000 QAM Monitor'
$RebootTaskName = 'COM3000 Daily PC Reboot'
$ScriptDir = Split-Path -Parent $PSCommandPath
$StateFile = Join-Path $ScriptDir 'monitor-state.json'
$LogFile   = Join-Path $ScriptDir 'monitor.log'
$PauseFile = Join-Path $ScriptDir 'paused-until.txt'
# Version of this file - shown in Status, the 'monitor installed' alert and on the dashboard,
# so you can tell which locations still have an older copy.
$ScriptVersion = '2026-11-13'
$BackupDir       = Join-Path $env:PUBLIC 'Desktop\COM3000 Backups'
$DriveTaskName   = 'COM3000 Backup to Google Drive'
$DriveStatusFile = Join-Path $ScriptDir 'drive-copy-status.txt'
$DriveLauncher   = Join-Path $ScriptDir 'drive-copy.vbs'

# Alerts log on the desktop (Public desktop, so it shows for every user and works
# when the monitor runs in the background). Set $DesktopLog = '' to turn it off.
$DesktopLog = Join-Path $env:PUBLIC ("Desktop\COM3000 Alerts - {0}.txt" -f ($SiteName -replace '[\\/:*?"<>|]', ''))

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$Inv = [Globalization.CultureInfo]::InvariantCulture

function Write-Log([string]$Text) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
    if ($ReadOnly) { return }
    try {
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 1MB)) {
            Move-Item $LogFile "$LogFile.old" -Force
        }
        Add-Content -Path $LogFile -Value $line
    } catch {}
    if ($Test) { Write-Host $line }
}

function Write-DesktopLog([string]$Text) {
    if (-not $DesktopLog -or $ReadOnly) { return }
    try {
        if (-not (Test-Path $DesktopLog)) {
            Set-Content -Path $DesktopLog -Value "COM3000 alerts - $SiteName`r`n(newest at the bottom)`r`n" -Encoding UTF8
        }
        $stamp = Get-Date -Format 'ddd MM/dd/yyyy  h:mm tt'
        $lines = ($Text -split "`n") | ForEach-Object { "      $_" }
        Add-Content -Path $DesktopLog -Value ("{0}`r`n{1}`r`n" -f $stamp, ($lines -join "`r`n")) -Encoding UTF8
    } catch {}
}

# POST to ntfy with firm time limits (connect/answer 20 s, each read/write 20 s)
function Send-Ntfy([string]$Url, [byte[]]$Body, [hashtable]$Headers) {
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = 'POST'; $req.Timeout = 20000; $req.ReadWriteTimeout = 20000; $req.Proxy = $null
    foreach ($k in $Headers.Keys) { $req.Headers[$k] = [string]$Headers[$k] }
    $req.ContentLength = $Body.Length
    $rs = $req.GetRequestStream(); try { $rs.Write($Body, 0, $Body.Length) } finally { $rs.Close() }
    $resp = $req.GetResponse(); $resp.Close()
}

function Send-Alert([string]$Title, [string]$Message, [string]$Priority = 'high', [string]$Tags = 'warning', [switch]$LogOnly, [switch]$NoSite) {
    if ($ReadOnly) { return }
    Write-DesktopLog ("{0}`n{1}" -f $Title.ToUpper(), $Message)
    if ($LogOnly) { Write-Log "LOGGED: $Title | $($Message -replace "`n", ' / ')"; return }
    $fullTitle = if ($NoSite) { $Title } else { "$SiteName - $Title" }
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Message)
        Send-Ntfy "$NtfyServer/$NtfyTopic" $bytes @{ Title = $fullTitle; Priority = $Priority; Tags = $Tags }
        Write-Log "ALERT SENT: $fullTitle | $($Message -replace "`n", ' / ')"
    } catch {
        Write-Log "Could not send alert: $($_.Exception.Message)"
    }
    # a copy for the COM3000 Dashboard's "Recent alerts" (it reads the status topic, never the phone topic)
    if ("$StatusReports" -ne 'off' -and -not $Test -and $Title -notmatch '\btest\b') {
        $about = $SiteName; $what = $Title
        if ($NoSite -and $Title -match '^(.+?) - (.+)$') { $about = $Matches[1]; $what = $Matches[2] }
        $at = (Get-Date).ToString('o')
        # also kept on this PC, so every status report can carry this location's recent alerts
        try {
            $h = [ordered]@{ t = $at; site = $about; title = $what; msg = $(if ($Message.Length -gt 160) { $Message.Substring(0, 157) + '...' } else { $Message }); prio = $Priority }
            Add-Content -Path (Join-Path $ScriptDir 'alert-history.jsonl') -Value ($h | ConvertTo-Json -Compress) -Encoding UTF8
        } catch {}
        try {
            $copy = [ordered]@{ v = 1; kind = 'alert'; site = $about; from = $SiteName; t = $at; title = $what; msg = $Message; prio = $Priority }
            Send-Ntfy "$NtfyServer/$NtfyTopic-status" ([Text.Encoding]::UTF8.GetBytes(($copy | ConvertTo-Json -Compress))) @{ Title = "alert $about"; Priority = 'min'; Tags = 'bell' }
        } catch {}
    }
}

# ---------------------------------------------------------------------------
# The Overview page builds its table with JavaScript from data lists inside the
# page (cardArray, channelArray, epgEntry, slotStatusArray, qamStatusArray).
# These functions read those lists directly.
# ---------------------------------------------------------------------------
function Get-JsArrayText([string]$Html, [string]$Name) {
    $m = [regex]::Match($Html, "(?s)var\s+$Name\s*=\s*\[(.*?)\]\s*;")
    if ($m.Success) { return $m.Groups[1].Value } else { return $null }
}

# Splits one JavaScript row like  1, 2, 'abc', 4.5  into values
function Split-JsRow([string]$Row) {
    $vals = New-Object System.Collections.ArrayList
    foreach ($t in [regex]::Matches($Row, "'((?:[^'\\]|\\.)*)'|([^,\s][^,]*)")) {
        if ($t.Groups[1].Success) { [void]$vals.Add(($t.Groups[1].Value -replace "\\'", "'")) }
        else { [void]$vals.Add($t.Groups[2].Value.Trim()) }
    }
    return ,$vals
}

function Get-JsRows([string]$Text) {
    $rows = New-Object System.Collections.ArrayList
    if (-not $Text) { return ,$rows }
    foreach ($m in [regex]::Matches($Text, '\[([^\[\]]*)\]')) { [void]$rows.Add((Split-JsRow $m.Groups[1].Value)) }
    return ,$rows
}

function Get-ComData([string]$Html) {
    $cardText = Get-JsArrayText $Html 'cardArray'
    if ($null -eq $cardText) { throw 'Page loaded but the channel data (cardArray) was not found.' }
    $cards = Get-JsRows $cardText
    $chanRows = Get-JsRows (Get-JsArrayText $Html 'channelArray')
    $epg = @(); $epgText = Get-JsArrayText $Html 'epgEntry'
    if ($epgText) { $epg = (Split-JsRow $epgText).ToArray() }

    # channel IDs currently in the DIRECTV lineup (what the Channel dropdown can show)
    $lineup = @{}
    $lineupName = @{}
    foreach ($c in $chanRows) {
        if ($c.Count -ge 4) {
            $lineup[$c[3]] = $true
            if ($c[2] -and $c[2] -ne 'None' -and -not $lineupName.ContainsKey($c[3])) { $lineupName[$c[3]] = $c[2] }
        }
    }
    $haveLineup = $chanRows.Count -gt 1

    $list = New-Object System.Collections.ArrayList
    $seenVirt = @{}
    for ($i = 0; $i -lt $cards.Count; $i++) {
        $r = $cards[$i]
        if ($r.Count -lt 16) { continue }
        $virt = if ($i -lt $epg.Count) { "$($epg[$i])".Trim() } else { '' }
        if ($virt -notmatch '^\d+-\d+$') { continue }        # "NA" = unused tuner / SD duplicate

        $major = $r[6]; $name = "$($r[15])".Trim()
        # the COM3000 sometimes leaves the name blank for a moment (guide refresh) - fill it from the lineup
        if (-not $name -and $lineupName.ContainsKey($r[8])) { $name = $lineupName[$r[8]] }
        $chanText = (@($(if ($major -ne '0') { $major }), $name) | Where-Object { $_ }) -join ' '
        $noChan = ($r[8] -eq '0') -or ($haveLineup -and -not $lineup.ContainsKey($r[8]))

        $mbps = 0.0
        [void][double]::TryParse($r[12], [Globalization.NumberStyles]::Float, $Inv, [ref]$mbps)

        $key = "ch:$virt"
        if ($seenVirt.ContainsKey($virt)) { $seenVirt[$virt]++; $key = "ch:$virt#$($seenVirt[$virt])" } else { $seenVirt[$virt] = 1 }

        [void]$list.Add([pscustomobject]@{
            Key = $key; Virt = $virt; Channel = $(if ($noChan) { 'NO CHANNEL SELECTED' } else { $chanText })
            Was = $(if ($noChan) { $chanText } else { '' }); NoChannel = $noChan
            Mbps = $mbps; Rate = ('{0} Mbps' -f $mbps.ToString('0.0', $Inv)); Snr = $r[13]
            Slot = $r[1]; Tuner = $r[2]; Major = "$($r[6])"; Minor = "$($r[7])"
        })
    }

    # tuner cards (slots) with their IP and status, plus the QAM card(s)
    $slots = New-Object System.Collections.ArrayList
    foreach ($s in (Get-JsRows (Get-JsArrayText $Html 'slotStatusArray'))) {
        if ($s.Count -ge 6) { [void]$slots.Add([pscustomobject]@{ Slot = $s[1]; Ip = $s[5]; Err = [int]$s[3] }) }
    }
    $qams = New-Object System.Collections.ArrayList
    foreach ($q in (Get-JsRows (Get-JsArrayText $Html 'qamStatusArray'))) {
        if ($q.Count -ge 2 -and $q[1] -match '^\d+\.\d+\.\d+\.\d+$') { [void]$qams.Add($q[1]) }
    }
    return [pscustomobject]@{ Channels = $list; Slots = $slots; QamIps = $qams; TunerCount = $cards.Count }
}

function Test-Ignored($c) {
    $callsign = ($c.Channel -replace '^\d+\s+', '')
    foreach ($e in $IgnoreChannels) {
        $e = "$e".Trim()
        if (-not $e) { continue }
        if ($e -ieq $c.Virt -or $e -ieq ($c.Virt -replace '-\d+$', '') -or $e -ieq $c.Channel -or $e -ieq $callsign) { return $true }
    }
    return $false
}

function Get-ChannelLabel($c) {
    $where = if ($c.Slot -and $c.Tuner) { " - slot $($c.Slot) tuner $($c.Tuner)" } elseif ($c.Tuner) { " - tuner $($c.Tuner)" } else { '' }
    $snr   = if ($c.Snr -match '^\d') { ", SNR $($c.Snr)" } else { '' }
    return "Ch $($c.Virt)  $($c.Channel)  ($($c.Rate)$snr)$where"
}

function Load-State {
    $s = @{ counts = @{}; alerted = @{}; lastSent = @{}; labels = @{}; names = @{}; devices = @{}; missing = @{}; good = @{}; slotOf = @{}; pending = @{}; nvSince = @{}; resetDay = @{}; resetAt = @{}; gnSince = @{}; sysResetDay = ''; sysResetAt = ''; sysResetSlots = ''; sysSkipDay = ''; pdSince = ''; statusSig = ''; statusAt = ''; quiet = @{}; held = @{}; rainSince = ''; rainLast = ''; rainAlerted = ''; updCheckAt = ''; epgBad = 0; epgBadList = ''; epgCheckAt = ''; epgRefDay = ''; epgRefFails = 0; epgRefNext = ''; epgRefAt = ''; epgRefOk = ''; lastBackup = ''; netDown = ''; netCycle = ''; netCut = ''; netBootOk = ''; netStep = 0; netStepAt = ''; netReboot = ''; netTried = ''; backupFails = 0; backupAlerted = ''; failCount = 0; failAlerted = $false }
    if (Test-Path $StateFile) {
        try {
            $j = Get-Content $StateFile -Raw | ConvertFrom-Json
            foreach ($n in 'counts', 'alerted', 'lastSent', 'labels', 'names', 'devices', 'missing', 'good', 'slotOf', 'pending', 'nvSince', 'resetDay', 'resetAt', 'gnSince', 'quiet', 'held') {
                if ($j.$n) { $j.$n.PSObject.Properties | ForEach-Object { $s[$n][$_.Name] = $(if ($n -eq 'counts' -or $n -eq 'good') { [int]$_.Value } else { [string]$_.Value }) } }
            }
            $s.sysResetDay   = [string]$j.sysResetDay
            $s.sysResetAt    = [string]$j.sysResetAt
            $s.sysResetSlots = [string]$j.sysResetSlots
            $s.sysSkipDay    = [string]$j.sysSkipDay
            $s.pdSince       = [string]$j.pdSince
            $s.statusSig     = [string]$j.statusSig
            $s.statusAt      = [string]$j.statusAt
            $s.lastBackup    = [string]$j.lastBackup
            $s.epgRefDay     = [string]$j.epgRefDay
            $s.epgRefFails   = [int]$j.epgRefFails
            $s.epgRefNext    = [string]$j.epgRefNext
            $s.epgRefAt      = [string]$j.epgRefAt
            $s.epgRefOk      = [string]$j.epgRefOk
            $s.backupFails   = [int]$j.backupFails
            $s.netDown       = [string]$j.netDown
            $s.netCycle      = [string]$j.netCycle
            $s.netBootOk     = [string]$j.netBootOk
            $s.netCut        = [string]$j.netCut
            $s.rainSince     = [string]$j.rainSince
            $s.rainLast      = [string]$j.rainLast
            $s.rainAlerted   = [string]$j.rainAlerted
            $s.epgBad        = [int]$j.epgBad
            $s.updCheckAt    = [string]$j.updCheckAt
            $s.epgBadList    = [string]$j.epgBadList
            $s.epgCheckAt    = [string]$j.epgCheckAt
            $s.netStep       = [int]$j.netStep
            $s.netStepAt     = [string]$j.netStepAt
            $s.netReboot     = [string]$j.netReboot
            $s.netTried      = [string]$j.netTried
            $s.backupAlerted = [string]$j.backupAlerted
            $s.failCount   = [int]$j.failCount
            $s.failAlerted = [bool]$j.failAlerted
        } catch { Write-Log 'State file unreadable, starting fresh.' }
    }
    return $s
}

function Save-State($s) {
    if ($ReadOnly) { return }
    try { $s | ConvertTo-Json -Depth 4 | Set-Content -Path $StateFile -Encoding UTF8 } catch {}
}

# Sends one grouped "still down" reminder for anything that has been out longer than $ReminderMinutes
function Send-Reminders($s, [bool]$IncludeChannels) {
    $now = Get-Date
    foreach ($k in @($s.lastSent.Keys)) {
        $active = if ($k -eq 'page') { $s.failAlerted } else { $s.alerted.ContainsKey($k) }
        if (-not $active) { $s.lastSent.Remove($k) }
    }
    if ($ReminderMinutes -le 0) { return }
    $due = New-Object System.Collections.ArrayList
    $keys = @($s.alerted.Keys); if ($s.failAlerted) { $keys += 'page' }
    # channels: just 'out' and 'back', no reminders (the dashboard shows what's still out)
    if ("$ChannelReminders" -ne 'on') { $IncludeChannels = $false }
    foreach ($k in $keys) {
        if (-not $IncludeChannels -and $k -like 'ch:*') { continue }
        $last = [datetime]::MinValue
        if ($s.lastSent[$k]) { [void][datetime]::TryParse($s.lastSent[$k], $Inv, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$last) }
        if (($now - $last).TotalMinutes -ge ($ReminderMinutes - 0.5)) {
            $label = if ($k -eq 'page') { 'COM3000 page not reachable' } elseif ($s.labels[$k]) { $s.labels[$k] } else { $k }
            $since = if ($k -eq 'page') { '' } else { " (since $($s.alerted[$k]))" }
            [void]$due.Add("$label$since")
            $s.lastSent[$k] = $now.ToString('o')
        }
    }
    if ($due.Count -gt 8) {
        # big outage (storm, dead card): keep the reminder to a short list
        $cardLines = @($due | Where-Object { $_ -notmatch '^Ch ' })
        $chShort   = @($due | Where-Object { $_ -match '^Ch ' } | ForEach-Object { if ($_ -match '^Ch (\S+)\s+(.+?)\s+(\(|-)') { "$($Matches[1]) $($Matches[2])" } else { $_ } } | Sort-Object { [int]($_ -replace '-.*$', '') })
        $due = @($cardLines) + @("$($chShort.Count) channels still out: " + ($chShort -join ', '))
        $t = "$($cardLines.Count + $chShort.Count) things still down"
        Send-Alert $t ($due -join "`n") 'high' 'warning'
        return
    }
    if ($due.Count -gt 0) {
        $t = if ($due.Count -eq 1) { 'still down' } else { "$($due.Count) things still down" }
        Send-Alert $t ($due -join "`n") 'high' 'warning'
    }
}

# Counts a down/up result for one item; returns 'down' when it should alert, 'up' when it recovered
function Update-Item($s, [string]$Key, [bool]$IsDown, [string]$Label) {
    if ($IsDown) {
        $s.good.Remove($Key)
        $s.counts[$Key] = [int]$s.counts[$Key] + 1
        if ($s.counts[$Key] -ge $ChecksToAlert -and -not $s.alerted.ContainsKey($Key)) {
            $s.alerted[$Key]  = (Get-Date -Format 'MM/dd h:mm tt')
            $s.lastSent[$Key] = (Get-Date).ToString('o')
            $s.labels[$Key]   = $Label
            return 'down'
        }
    } else {
        $s.counts[$Key] = 0
        if ($s.alerted.ContainsKey($Key)) {
            $s.good[$Key] = [int]$s.good[$Key] + 1
            if ($s.good[$Key] -ge [Math]::Max(1, $ChecksToRecover)) { $s.good.Remove($Key); return 'up' }
        }
    }
    return ''
}

function Clear-Item($s, [string]$Key) {
    foreach ($n in 'counts', 'alerted', 'lastSent', 'labels', 'good', 'held') { if ($s[$n]) { $s[$n].Remove($Key) } }
}

# Downloads the page. Talks to the COM3000 directly (no proxy), and if the page keeps
# streaming / never finishes, uses whatever arrived instead of hanging.
function Get-PageHtml([string]$Url) {
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Timeout = 30000
    $req.ReadWriteTimeout = 15000
    $req.Proxy = $null
    if ($Username) { $req.Credentials = New-Object System.Net.NetworkCredential($Username, $Password) }
    $resp = $req.GetResponse()
    try {
        $stream   = $resp.GetResponseStream()
        $ms       = New-Object System.IO.MemoryStream
        $buf      = New-Object byte[] 65536
        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $deadline) {
            $n = 0
            try { $n = $stream.Read($buf, 0, $buf.Length) } catch { if ($ms.Length -gt 0) { break } else { throw } }
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
        }
        return [Text.Encoding]::UTF8.GetString($ms.ToArray())
    } finally { $resp.Close() }
}

# A card counts as online if its web page port (80) answers, or it answers a ping
function Test-Card([string]$Ip) {
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $tcp.ConnectAsync($Ip, 80)
        if ($task.Wait(3000) -and $tcp.Connected) { return $true }
    } catch {} finally { $tcp.Dispose() }
    $ping = New-Object System.Net.NetworkInformation.Ping
    for ($i = 0; $i -lt 2; $i++) {
        try { if ($ping.Send($Ip, 2000).Status -eq 'Success') { return $true } } catch {}
    }
    return $false
}

# Puts "COM3000 Alerts ON" / "COM3000 Alerts OFF" shortcuts on the desktop (all users).
# They run this script as administrator and leave the window open so you can see the result.
# EPG safety copies go in ONE desktop folder, one file each, replaced every time:
#   "<site> EPG before submit.txt"          (Make EPG - every blade's list before YES)
#   "<site> EPG before refresh - <IP>.txt"  (daily EPG refresh)
function Get-EpgCopyDir {
    $desk = [Environment]::GetFolderPath('Desktop'); if (-not $desk) { $desk = $ScriptDir }
    $dir = Join-Path $desk 'COM3000 EPG copies'
    try {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        # tidy up what older versions left on the desktop
        $loose = @(Get-ChildItem -Path $desk -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match ' EPG (before refresh|before submit|from Overview|ready to submit)' -or $_.Name -like 'EPG submit test*' })
        $dated = @(@($loose) + @(Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue) | Where-Object { $_ -and $_.Name -match ' EPG before submit \d{4}-\d\d-\d\d' } | Sort-Object LastWriteTime -Descending)
        foreach ($f in $dated) {
            $one = Join-Path $dir ($f.Name -replace ' \d{4}-\d\d-\d\d \d{4}', '')
            try { if (-not (Test-Path $one)) { Move-Item -LiteralPath $f.FullName -Destination $one -ErrorAction Stop } else { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } } catch {}
        }
        foreach ($f in $loose) {
            if (-not (Test-Path -LiteralPath $f.FullName)) { continue }
            try {
                if ($f.Name -match ' EPG (from Overview|ready to submit)' -or $f.Name -like 'EPG submit test*') { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop }
                else { Move-Item -LiteralPath $f.FullName -Destination (Join-Path $dir $f.Name) -Force -ErrorAction Stop }
            } catch {}
        }
        return $dir
    } catch { return $desk }
}

# Desktop background: com3000-wallpaper.jpg with the location name written on it, set for this user
function Set-ComWallpaper([string]$Site) {
    $src = Join-Path $ScriptDir $(if ("$Wallpaper" -eq 'gray') { 'com3000-wallpaper-gray.jpg' } else { 'com3000-wallpaper.jpg' })
    if (-not (Test-Path $src)) { $src = Join-Path $ScriptDir 'com3000-wallpaper.jpg' }
    if (-not (Test-Path $src)) { Write-Host "   (Desktop background skipped - com3000-wallpaper.jpg is not in this folder.)" -ForegroundColor Yellow; return }
    $out = Join-Path $ScriptDir 'com3000-wallpaper-site.jpg'
    try {
        Add-Type -AssemblyName System.Drawing; Add-Type -AssemblyName System.Windows.Forms
        # made at this screen's shape, so nothing gets cut off at the sides
        $scr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $W = [Math]::Max(1024, $scr.Width); $H = [Math]::Max(600, $scr.Height)
        if ($W -lt 1600) { $k = 1920 / $W; $W = [int]($W * $k); $H = [int]($H * $k) }      # keep it sharp
        $img = [System.Drawing.Image]::FromFile($src)
        $bmp = New-Object System.Drawing.Bitmap($W, $H); $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $sc = [Math]::Max($W / $img.Width, $H / $img.Height)      # cover the screen, crop evenly
        $dw = [int]($img.Width * $sc); $dh = [int]($img.Height * $sc)
        $g.DrawImage($img, [int](($W - $dw) / 2), [int](($H - $dh) / 2), $dw, $dh); $img.Dispose()
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $px = [System.Drawing.GraphicsUnit]::Pixel
        $bigSize = [Math]::Round($H * 0.055); $smallSize = [Math]::Round($H * 0.024)
        $big = New-Object System.Drawing.Font('Segoe UI Semibold', [float]$bigSize, [System.Drawing.FontStyle]::Regular, $px)
        $small = New-Object System.Drawing.Font('Segoe UI', [float]$smallSize, [System.Drawing.FontStyle]::Regular, $px)
        # shrink a very long name so it always fits in the left half of the screen
        while ($g.MeasureString($Site, $big).Width -gt $W * 0.5 -and $bigSize -gt 20) { $bigSize -= 2; $big = New-Object System.Drawing.Font('Segoe UI Semibold', [float]$bigSize, [System.Drawing.FontStyle]::Regular, $px) }
        $b1 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 255, 255, 255))
        $b2 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(110, 255, 255, 255))
        # bottom-left, clear of the taskbar and the screen edge
        $x = [int]($W * 0.06); $y = [int]($H * 0.78)
        $g.DrawString($Site, $big, $b1, $x, $y)
        $g.DrawString('COM3000 headend PC', $small, $b2, $x + [int]($bigSize * 0.06), $y + [int]($bigSize * 1.35))
        $g.Dispose()
        $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Jpeg); $bmp.Dispose()
    } catch { Copy-Item $src $out -Force }
    try {
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '10'      # Fill
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value '0'
        # Windows Spotlight would keep replacing it - turn Spotlight off for the desktop
        try { New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\DesktopSpotlight\Settings' -Force -ErrorAction Stop | Out-Null; Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\DesktopSpotlight\Settings' -Name EnabledState -Value 0 -Type DWord } catch {}
        if (-not ('ComWall' -as [type])) {
            Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class ComWall { [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int SystemParametersInfo(int a, int b, string c, int d); }'
        }
        [void][ComWall]::SystemParametersInfo(20, 0, $out, 3)      # SPI_SETDESKWALLPAPER, save + tell Windows
        Write-Host "Desktop background set ($(if ("$Wallpaper" -eq 'gray') { 'gray' } else { 'blue' }), with '$Site')." -ForegroundColor Green
    } catch { Write-Host "   (Couldn't set the desktop background: $($_.Exception.Message))" -ForegroundColor Yellow }
}

function New-DesktopShortcuts {
    $desk = Join-Path $env:PUBLIC 'Desktop'
    $ps   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $shell = New-Object -ComObject WScript.Shell
    Remove-Item (Join-Path $desk 'COM3000 Reset Card.lnk') -ErrorAction SilentlyContinue    # renamed to "COM3000 Reset"
    foreach ($s in @(
        @{ Name = 'COM3000 Alerts ON';  Arg = '-Install';   Icon = 'imageres.dll,101'; Tip = 'Turn the COM3000 monitor on'; Admin = $true },
        @{ Name = 'COM3000 Alerts OFF'; Arg = '-Uninstall'; Icon = 'imageres.dll,100'; Tip = 'Turn the COM3000 monitor off'; Admin = $true },
        @{ Name = 'COM3000 Status';     Arg = '-Status';    Icon = 'imageres.dll,76';  Tip = 'Show what the COM3000 monitor is watching'; Admin = $false },
        @{ Name = 'COM3000 Reset'; Arg = '-ResetCard'; Icon = 'imageres.dll,228'; IconFile = 'com3000-power.ico'; Tip = 'Reset a COM3000 card (or the whole COM3000) and watch it come back'; Admin = $true; Hidden = $true },
        @{ Name = 'COM3000 Settings'; Target = (Join-Path $env:SystemRoot 'System32\notepad.exe'); TargetArgs = "`"$SettingsFile`""; Icon = 'imageres.dll,109'; Tip = 'Edit this site''s monitor settings'; Admin = $true },
        @{ Name = 'COM3000 Channel Check'; Arg = '-Picker'; Icon = 'imageres.dll,18'; IconFile = 'tv.ico'; Tip = 'Step through the channels in VLC'; Admin = $false; Hidden = $true },
        @{ Name = 'COM3000 Make EPG'; Arg = '-MakeEpg'; Icon = 'imageres.dll,2'; IconFile = 'com3000-epg-list.ico'; Tip = 'Build the EPG from the Overview page and fill it in on the blades you pick'; Admin = $false },
        @{ Name = 'COM3000 PC IP'; Arg = '-ShowIp'; Icon = 'imageres.dll,20'; IconFile = 'com3000-ip.ico'; Tip = 'Show (and copy) this PC''s IP address'; Admin = $false; Hidden = $true },
        @{ Name = 'COM3000 Blades'; Arg = '-OpenBlades'; Icon = 'imageres.dll,1'; IconFile = 'com3000-chassis.ico'; Tip = 'Close Chrome and open a tab for every COM3000 blade and WebSTX'; Admin = $false; Hidden = $true }
    )) {
        $path = Join-Path $desk "$($s.Name).lnk"
        $lnk  = $shell.CreateShortcut($path)
        $lnk.TargetPath       = if ($s.Target) { $s.Target } else { $ps }
        $lnk.Arguments        = if ($s.Target) { $s.TargetArgs } elseif ($s.Hidden) { "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" $($s.Arg)" }
                                else { "-NoProfile -ExecutionPolicy Bypass -Command `"& '$PSCommandPath' $($s.Arg); Write-Host ''; Read-Host 'Press Enter to close'`"" }
        if ($s.Hidden) { $lnk.WindowStyle = 7 }
        $lnk.WorkingDirectory = $ScriptDir
        $own = if ($s.IconFile) { Join-Path $ScriptDir $s.IconFile } else { $null }
        $lnk.IconLocation     = if ($own -and (Test-Path $own)) { "$own,0" } else { Join-Path $env:SystemRoot "System32\$($s.Icon)" }
        $lnk.Description      = $s.Tip
        $lnk.Save()
        # (older versions also opened 'COM3000 Blades' at startup - take that out)
        foreach ($sd in @([Environment]::GetFolderPath('CommonStartup'), [Environment]::GetFolderPath('Startup'))) {
            if ($sd) { Remove-Item -LiteralPath (Join-Path $sd "$($s.Name).lnk") -Force -ErrorAction SilentlyContinue }
        }
        if (-not $s.Admin) { continue }
        # tick "Run as administrator" on the shortcut
        $bytes = [IO.File]::ReadAllBytes($path)
        $bytes[0x15] = $bytes[0x15] -bor 0x20
        [IO.File]::WriteAllBytes($path, $bytes)
    }
    Write-Host "Desktop shortcuts ready: 'COM3000 Alerts ON', 'COM3000 Alerts OFF', 'COM3000 Status', 'COM3000 Channel Check', 'COM3000 Make EPG', 'COM3000 Blades', 'COM3000 PC IP', 'COM3000 Reset' and 'COM3000 Settings'."
}

# ---------------------------------------------------------------------------
# DAILY BACKUP: TuneAll "Current Tuning Table" + EPG list -> desktop folder,
# then copied to Google Drive by a small task that runs under your Windows login.
# ---------------------------------------------------------------------------
function Get-CleanError($e) { return ("$($e.Exception.Message)" -replace '^Exception calling "[^"]+" with "\d+" argument\(s\): ', '').Trim('"') }

function Get-ComMainIp { if ($PageUrl -match '^https?://([^/]+)') { return $Matches[1] } else { return '' } }
# The card the COM3000 pages are read from: normally the one in $PageUrl, but if that card is
# offline (e.g. being reset) the pages are read from another card instead.
$script:ComHostNow = ''
function Get-ComIp { if ($script:ComHostNow) { return $script:ComHostNow } else { return (Get-ComMainIp) } }
# main card first, then the other cards the monitor has seen (from monitor-state.json)
function Protect-ResetPassword([string]$Plain) {
    Add-Type -AssemblyName System.Security
    $b = [System.Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($Plain), [Text.Encoding]::UTF8.GetBytes('COM3000-reset'), 'LocalMachine')
    return [Convert]::ToBase64String($b)
}
function Unprotect-ResetPassword([string]$Secret) {
    if (-not $Secret) { return '' }
    Add-Type -AssemblyName System.Security
    $b = [System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Secret), [Text.Encoding]::UTF8.GetBytes('COM3000-reset'), 'LocalMachine')
    return [Text.Encoding]::UTF8.GetString($b)
}
function Get-ComHosts {
    $h = New-Object System.Collections.ArrayList
    $main = Get-ComMainIp; if ($main) { [void]$h.Add($main) }
    try {
        if (Test-Path $StateFile) {
            $j = Get-Content $StateFile -Raw | ConvertFrom-Json
            if ($j.devices) { foreach ($p in $j.devices.PSObject.Properties) { if ("$($p.Value)" -match '^Card slot' -and $p.Name -match '^\d+\.\d+\.\d+\.\d+$' -and -not $h.Contains($p.Name)) { [void]$h.Add($p.Name) } } }
        }
    } catch {}
    return $h.ToArray()
}
function Set-UrlHost([string]$Url, [string]$NewHost) { return ($Url -replace '^(https?://)[^/]+', ('${1}' + $NewHost)) }
function Test-HostPort([string]$HostPort, [int]$Ms = 2000) {
    $hh = $HostPort; $pp = 80; if ($hh -match '^(.+):(\d+)$') { $hh = $Matches[1]; $pp = [int]$Matches[2] }
    $ok = $false; try { $tc = New-Object Net.Sockets.TcpClient; $ok = $tc.ConnectAsync($hh, $pp).Wait($Ms) -and $tc.Connected; $tc.Close() } catch {}
    return $ok
}
# Read the Overview page from the main card, or from another card if the main one is offline
function Get-ComOverview {
    $err = $null
    foreach ($h in @(Get-ComHosts)) {
        if (-not (Test-HostPort $h)) { if (-not $err) { $err = "Card $h is not answering" }; continue }
        try {
            $html = Get-PageHtml (Set-UrlHost $PageUrl $h)
            $data = Get-ComData $html
            $script:ComHostNow = $(if ($h -eq (Get-ComMainIp)) { '' } else { $h })
            return @{ Html = $html; Data = $data; Host = $h }
        } catch { $err = Get-CleanError $_ }
    }
    throw $(if ($err) { $err } else { 'No COM3000 card is answering' })
}

function Get-HtmlText([string]$Fragment) {
    $t = $Fragment -replace '(?i)<br\s*/?>', "`n"
    $t = [regex]::Replace($t, '<[^>]+>', '')
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    return @($t -split "\r?\n" | ForEach-Object { $_.TrimEnd() } | Where-Object { $_.Trim() })
}

# Fetches both pages and writes "<location> COM3000 backup <date>.txt" to the desktop folder
function Invoke-Backup {
    $comIp = Get-ComIp
    $epgHost = if ("$EpgIp".Trim()) { "$EpgIp".Trim() } else { $comIp }
    $tuneUrl = "http://$comIp/cgi-bin/webcmd?screen=TuneAll"
    $epgUrl  = "http://$epgHost/cgi-bin/webcmd?screen=EpgDisplay"

    $tuneHtml = Get-PageHtml $tuneUrl
    $m = [regex]::Match($tuneHtml, '(?is)Current Tuning Table\s*</h2>(.*?)(</pre>|$)')
    if (-not $m.Success) { throw "TuneAll page ($tuneUrl) loaded but 'Current Tuning Table' was not found." }
    $tune = Get-HtmlText $m.Groups[1].Value
    if ($tune.Count -eq 0) { throw 'The Current Tuning Table on the TuneAll page is empty.' }

    $epgHtml = Get-PageHtml $epgUrl
    $m = [regex]::Match($epgHtml, "(?is)<textarea[^>]*name=['""]?EpgList['""]?[^>]*>(.*?)</textarea>")
    if (-not $m.Success) { throw "EPG page ($epgUrl) loaded but the EPG list box was not found." }
    $epg = Get-HtmlText $m.Groups[1].Value
    if ($epg.Count -eq 0) { $epg = @("(the EPG list on $epgHost is empty)") }      # other blades' lists are still saved below

    # the EPG is often copied onto more than one blade (AEP boxes / TVs on the COM directly):
    # note which blades have the same list, and save any that differ
    $sameOn = New-Object System.Collections.ArrayList; $extra = @()
    foreach ($h in @(Get-ComHosts)) {
        if ($h -eq $epgHost) { continue }
        try {
            if (-not (Test-HostPort $h 2000)) { continue }
            $o = Get-EpgBoxLines (Get-PageHtml "http://$h/cgi-bin/webcmd?screen=EpgDisplay")
            if (-not $o -or $o.Count -eq 0) { continue }
            $mine = @($epg | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
            if (($o -join '|') -eq ($mine -join '|')) { [void]$sameOn.Add($h) }
            else { $extra += @('', '', "EPG on $h (different from the one above)", '') + $o }
        } catch {}
    }

    $now  = Get-Date
    $safe = ($SiteName -replace '[\\/:*?"<>|]', '').Trim()
    $text = @(
        $SiteName
        ''
        "Backed up $($now.ToString('ddd MM/dd/yyyy h:mm tt')) from COM3000 $comIp$(if ($epgHost -ne $comIp) { " (EPG from $epgHost)" })"
        ''
        'Tune all'
        ''
    ) + $tune + @('', '', "EPG$(if ($sameOn.Count) { " (from $epgHost - the same list is also on $($sameOn -join ', '))" })", '') + $epg + $extra + @('')
    if (-not (Test-Path $BackupDir -PathType Container)) { New-Item -ItemType Directory -Path $BackupDir -Force -ErrorAction Stop | Out-Null }
    $file = Join-Path $BackupDir "$safe COM3000 backup.txt"
    Set-Content -Path $file -Value ($text -join "`r`n") -Encoding UTF8 -ErrorAction Stop
    return [pscustomobject]@{ File = $file; TuneLines = $tune.Count; EpgLines = $epg.Count }
}

# Asks the Google Drive copy task to run now (it runs under the logged-in user)
function Start-DriveCopy { try { Start-ScheduledTask -TaskName $DriveTaskName -ErrorAction Stop; return $true } catch { return $false } }

function Get-DriveTarget {
    $safe = ($SiteName -replace '[\\/:*?"<>|]', '').Trim()
    if ("$DriveFolder".Trim() -and $DriveFolder -ne 'auto') { return $DriveFolder }
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        $md = Join-Path $d.Root 'My Drive'
        if (Test-Path -LiteralPath $md) { return (Join-Path $md "COM3000 Backups\$safe") }
    }
    return $null
}

# Puts the latest backup in Google Drive if Drive's copy is different (catches up after Drive was disconnected)
function Invoke-DriveCopy {
    $stamp = Get-Date -Format 'MM/dd h:mm tt'
    $target = Get-DriveTarget
    if (-not $target) {
        Set-Content -Path $DriveStatusFile -Value "$stamp  Google Drive not available (not signed in, or needs reconnecting). Will try again." -ErrorAction SilentlyContinue
        return "Google Drive not available - will try again later."
    }
    try {
        if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force -ErrorAction Stop | Out-Null }
        $n = 0
        foreach ($f in (Get-ChildItem -Path $BackupDir -Filter '*.txt' -ErrorAction SilentlyContinue)) {
            $dest = Join-Path $target $f.Name
            $have = Get-Item -LiteralPath $dest -ErrorAction SilentlyContinue
            $same = $have -and $have.Length -eq $f.Length -and
                    (Get-FileHash -LiteralPath $dest).Hash -eq (Get-FileHash -LiteralPath $f.FullName).Hash
            if (-not $same) { Copy-Item -LiteralPath $f.FullName -Destination $dest -Force -ErrorAction Stop; $n++ }
        }
        $msg = if ($n -gt 0) { "updated the backup in $target" } else { "Drive already has the latest backup ($target)" }
        Set-Content -Path $DriveStatusFile -Value "$stamp  OK - $msg" -ErrorAction SilentlyContinue
        return "Google Drive: $msg"
    } catch {
        Set-Content -Path $DriveStatusFile -Value "$stamp  FAILED - $($_.Exception.Message)" -ErrorAction SilentlyContinue
        return "Google Drive copy failed: $($_.Exception.Message)"
    }
}

# The Drive copy has to run as the person logged in to Windows (Google Drive only exists in their session)
function Register-DriveCopyTask {
    $user = $null
    try { $user = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch {}
    if (-not $user) { $user = "$env:USERDOMAIN\$env:USERNAME" }
    $vbs = @(
        'Set sh = CreateObject("WScript.Shell")'
        ('sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """"' + $PSCommandPath + '"""" -SyncDrive", 0, False')
    ) -join "`r`n"
    Set-Content -Path $DriveLauncher -Value $vbs -Encoding ASCII
    $action    = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$DriveLauncher`""
    $triggers  = @(
        (New-ScheduledTaskTrigger -AtLogOn -User $user),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 30))
    )
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
                   -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $DriveTaskName -Action $action -Trigger $triggers -Principal $principal `
        -Settings $settings -Force -ErrorAction Stop | Out-Null
    return $user
}

# ---------------- Backup now / Google Drive copy (buttons and background) ----------------
if ($SyncDrive) {
    Write-Host (Invoke-DriveCopy)
    return
}
# ---------------------------------------------------------------------------
# MAKE EPG FROM OVERVIEW: builds the EPG list from what the tuners are really sending,
# ready to paste into the EPG page. Each EPG line is tied to a tuner by its QAM port
# (the last number on the line), so virtual channel numbers stay the same.
# ---------------------------------------------------------------------------
function Build-EpgFromOverview([string]$OverviewHtml, [string]$EpgHtml, [int]$StartVirt = 3, [int]$GuidePort = 20, [int]$GuideVirt = 0, $Community = @()) {
    $m = [regex]::Match($EpgHtml, "(?is)<textarea[^>]*name=['""]?EpgList['""]?[^>]*>(.*?)</textarea>")
    if (-not $m.Success) { throw 'The EPG list box was not found on the EPG page.' }
    $old = @(Get-HtmlText $m.Groups[1].Value | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    # tuners on the Overview page sending to a QAM: port -> tuner
    $byPort = @{}; $noQam = 0
    foreach ($r in (Get-JsRows (Get-JsArrayText $OverviewHtml 'cardArray'))) {
        if ($r.Count -lt 16 -or "$($r[3])" -ne '0') { continue }
        $port = 0; if (-not [int]::TryParse("$($r[5])", [ref]$port) -or $port -le 0) { continue }
        if ("$($r[9])" -eq '0') { if ("$($r[8])" -ne '0') { $noQam++ }; continue }      # has a channel but no QAM output picked: not on any TV
        if (-not $byPort.ContainsKey($port)) {
            $byPort[$port] = [pscustomobject]@{ Tuner = "$($r[0])-$($r[1])-$($r[2])"; Maj = "$($r[6])"; Min = "$($r[7])"; Obj = "$($r[8])"; Name = "$($r[15])".Trim(); Port = $port }
        }
    }

    $out = New-Object System.Collections.ArrayList
    $changes = New-Object System.Collections.ArrayList
    $usedPorts = @{}; $usedVirt = @{}; $dtvInEpg = @{}; $portVirt = @{}; $lineObj = @{}
    foreach ($line in $old) {
        $x = [regex]::Match($line, '^(\d+)-(\d+)\s+(\d+)-(\d+)-(hd|sd)\s+(\S+)\s+(\d+)\s*$', 'IgnoreCase')
        if (-not $x.Success) {
            # guide / internal channels made by the COM3000 ("2-0 NEPG_... 1 20") and anything else: kept as they are
            $n = [regex]::Match($line, '^(\d+-\d+)\s+\S+\s+\S+\s+(\d+)\s*$')
            if ($n.Success) { $usedPorts[[int]$n.Groups[2].Value] = $true; $usedVirt[$n.Groups[1].Value] = $true }
            [void]$out.Add([pscustomobject]@{ Sort = $(if ($n.Success) { $n.Groups[1].Value } else { $line }); Text = $line }); continue
        }
        $virt = "$($x.Groups[1].Value)-$($x.Groups[2].Value)"; $port = [int]$x.Groups[7].Value
        $usedPorts[$port] = $true
        $t = $byPort[$port]
        if ($t) { $usedVirt[$virt] = $true }
        if (-not $t) {
            [void]$changes.Add("REMOVED  $virt  (DIRECTV $($x.Groups[3].Value), QAM port $port) - no tuner sends to that port")
            continue
        }
        if ($t.Obj -eq '0' -or $t.Maj -eq '0') {
            [void]$changes.Add("CHECK    $virt  tuner $($t.Tuner) has no channel (None) - line kept as it was (DIRECTV $($x.Groups[3].Value))")
            [void]$out.Add([pscustomobject]@{ Sort = $virt; Text = $line }); continue
        }
        $new = "$virt $($t.Maj)-$($t.Min)-$($x.Groups[5].Value.ToLower()) $($x.Groups[6].Value) $port"
        if ($t.Maj -ne $x.Groups[3].Value -or $t.Min -ne $x.Groups[4].Value) {
            [void]$changes.Add("FIXED    $virt  DIRECTV $($x.Groups[3].Value) -> $($t.Maj) $($t.Name)  (tuner $($t.Tuner), port $port)")
        }
        if (-not $dtvInEpg.ContainsKey("$($t.Maj)-$($t.Min)")) { $dtvInEpg["$($t.Maj)-$($t.Min)"] = $virt }
        $o = [pscustomobject]@{ Sort = $virt; Text = $new }
        if (-not $portVirt.ContainsKey($port) -and $x.Groups[2].Value -eq '0') { $portVirt[$port] = [int]$x.Groups[1].Value; $lineObj[$port] = $o }
        [void]$out.Add($o)
    }
    # tuners on a QAM port the EPG doesn't list
    # new location (empty EPG): channel numbers start at 3-0, after the guide on 2-0
    $maxVirt = (@($usedVirt.Keys | ForEach-Object { [int]($_ -split '-')[0] }) | Measure-Object -Maximum).Maximum
    $nextVirt = if ($maxVirt) { [int]$maxVirt + 1 } else { $StartVirt }
    # new location: community / internal channels typed in (they aren't on the Overview page)
    if ($true) {
        foreach ($cc in @($Community | Where-Object { $_ -and $_.Virt -and $_.Port })) {
            if ($usedVirt.ContainsKey("$($cc.Virt)-0")) { [void]$changes.Add("SKIPPED  $($cc.Virt)-0  community channel $($cc.Name) - that number is already used"); continue }
            [void]$out.Add([pscustomobject]@{ Sort = "$($cc.Virt)-0"; Text = "$($cc.Virt)-0 N$($cc.Name) 1 $($cc.Port)" })
            [void]$changes.Add("ADDED    $($cc.Virt)-0  community channel $($cc.Name) (port $($cc.Port))")
            $usedVirt["$($cc.Virt)-0"] = $true; $usedPorts[[int]$cc.Port] = $true
        }
    }
    # new location: add the guide line (unless the EPG already has one, or 'none' was chosen)
    $hasGuide = [bool]($old | Where-Object { $_ -match '^\d+-\d+\s+NEPG' })
    if ($GuideVirt -gt 0 -and -not $hasGuide -and -not $usedVirt.ContainsKey("$GuideVirt-0")) {
        [void]$out.Add([pscustomobject]@{ Sort = "$GuideVirt-0"; Text = "$GuideVirt-0 NEPG_Electronic_Program_Guide 1 $GuidePort" })
        [void]$changes.Add("ADDED    $GuideVirt-0  guide channel (NEPG_Electronic_Program_Guide, port $GuidePort)")
        $usedVirt["$GuideVirt-0"] = $true
    }
    # lines that were added at the END while their old spot is still free (e.g. 3-0 deleted, then re-added
    # as 34-0 by an older version): in port order they break the sequence, so move them back into the gap
    $ports = @($portVirt.Keys | Sort-Object)
    if ($ports.Count -ge 3) {
        $len = @(1) * $ports.Count; $prev = @(-1) * $ports.Count
        for ($a = 0; $a -lt $ports.Count; $a++) { for ($b = 0; $b -lt $a; $b++) { if ($portVirt[$ports[$b]] -lt $portVirt[$ports[$a]] -and $len[$b] + 1 -gt $len[$a]) { $len[$a] = $len[$b] + 1; $prev[$a] = $b } } }
        $end = 0; for ($a = 1; $a -lt $ports.Count; $a++) { if ($len[$a] -gt $len[$end]) { $end = $a } }
        $inOrder = @{}; for ($a = $end; $a -ge 0; $a = $prev[$a]) { $inOrder[$ports[$a]] = $true }
        $topInOrder = (@($inOrder.Keys | ForEach-Object { $portVirt[$_] }) | Measure-Object -Maximum).Maximum
        $stray = @($ports | Where-Object { -not $inOrder.ContainsKey($_) })
        # only when every out-of-order line sits after the end of the list (so nothing laid out on purpose is touched)
        if ($stray.Count -and $stray.Count -le 5 -and -not @($stray | Where-Object { $portVirt[$_] -le $topInOrder }).Count) {
            $oldVirt = @{}
            foreach ($sp in $stray) { $oldVirt[$sp] = $portVirt[$sp]; $usedVirt.Remove("$($portVirt[$sp])-0"); $portVirt.Remove($sp) }
            $i = 0
            while ($i -lt $stray.Count) {
                $run = @($stray[$i]); $j = $i + 1
                while ($j -lt $stray.Count -and -not @($portVirt.Keys | Where-Object { $_ -gt $stray[$j - 1] -and $_ -lt $stray[$j] }).Count) { $run += $stray[$j]; $j++ }
                $i = $j
                $below = @($portVirt.Keys | Where-Object { $_ -lt $run[0] } | Sort-Object -Descending | Select-Object -First 1)
                $above = @($portVirt.Keys | Where-Object { $_ -gt $run[-1] } | Sort-Object | Select-Object -First 1)
                $lo = if ($below.Count) { $portVirt[$below[0]] } elseif ($above.Count) { [Math]::Min($StartVirt, $portVirt[$above[0]]) - 1 } else { 0 }
                $hi = if ($above.Count) { $portVirt[$above[0]] } else { $lo + $run.Count + 1 }
                $free = @(for ($v = $lo + 1; $v -lt $hi; $v++) { if ($v -ge 1 -and -not $usedVirt.ContainsKey("$v-0")) { $v } })
                if ($free.Count -lt $run.Count -or (-not $below.Count -and -not $above.Count)) { $free = @($run | ForEach-Object { $oldVirt[$_] }) }      # no room: leave them where they are
                elseif (-not $below.Count) { $free = @($free | Select-Object -Last $run.Count) }
                for ($k = 0; $k -lt $run.Count; $k++) {
                    $sp = $run[$k]; $nv = [int]$free[$k]
                    $portVirt[$sp] = $nv; $usedVirt["$nv-0"] = $true
                    if ($nv -ne $oldVirt[$sp]) {
                        $o = $lineObj[$sp]; $o.Sort = "$nv-0"; $o.Text = $o.Text -replace '^\d+-0\b', "$nv-0"
                        foreach ($key in @($dtvInEpg.Keys)) { if ($dtvInEpg[$key] -eq "$($oldVirt[$sp])-0") { $dtvInEpg[$key] = "$nv-0" } }
                        [void]$changes.Add("MOVED    $($oldVirt[$sp])-0 -> $nv-0  DIRECTV $($byPort[$sp].Maj) $($byPort[$sp].Name)  (port $sp) - back in its place between the tuners around it")
                    }
                }
            }
        }
    }
    $maxVirt = (@($usedVirt.Keys | ForEach-Object { [int]($_ -split '-')[0] }) | Measure-Object -Maximum).Maximum
    $nextVirt = if ($maxVirt) { [int]$maxVirt + 1 } else { $StartVirt }
    # tuners missing from the EPG go back in their place among the tuners: a line deleted from the middle
    # comes back with its old number (between the tuners on the ports before and after it), if that's free
    $missing = @($byPort.Keys | Sort-Object | Where-Object { -not $usedPorts.ContainsKey($_) -and $byPort[$_].Obj -ne '0' -and $byPort[$_].Maj -ne '0' })
    $place = @{}; $between = @{}
    $i = 0
    while ($i -lt $missing.Count) {
        $run = @($missing[$i]); $j = $i + 1
        while ($j -lt $missing.Count -and -not @($portVirt.Keys | Where-Object { $_ -gt $missing[$j - 1] -and $_ -lt $missing[$j] }).Count) { $run += $missing[$j]; $j++ }
        $i = $j
        $below = @($portVirt.Keys | Where-Object { $_ -lt $run[0] } | Sort-Object -Descending | Select-Object -First 1)
        $above = @($portVirt.Keys | Where-Object { $_ -gt $run[-1] } | Sort-Object | Select-Object -First 1)
        if (-not $below.Count -and -not $above.Count) { continue }
        $lo = if ($below.Count) { $portVirt[$below[0]] } else { [Math]::Min($StartVirt, $portVirt[$above[0]]) - 1 }
        $hi = if ($above.Count) { $portVirt[$above[0]] } else { $lo + $run.Count + 1 }
        $free = @(for ($v = $lo + 1; $v -lt $hi; $v++) { if ($v -ge 1 -and -not $usedVirt.ContainsKey("$v-0")) { $v } })
        if ($free.Count -lt $run.Count) { continue }
        if (-not $below.Count) { $free = @($free | Select-Object -Last $run.Count) }
        for ($k = 0; $k -lt $run.Count; $k++) { $place[$run[$k]] = $free[$k]; $usedVirt["$($free[$k])-0"] = $true; if ($above.Count) { $between[$run[$k]] = $true } }
    }
    # hd or sd: whichever most of this blade's lines use
    $nSd = @($old | Where-Object { $_ -match '^\d+-\d+\s+\d+-\d+-sd\b' }).Count; $nHd = @($old | Where-Object { $_ -match '^\d+-\d+\s+\d+-\d+-hd\b' }).Count
    $hdsd = if ($nSd -gt $nHd) { 'sd' } else { 'hd' }
    foreach ($port in $missing) {
        $t = $byPort[$port]
        $dupOf = $dtvInEpg["$($t.Maj)-$($t.Min)"]
        if ($place.ContainsKey($port)) { $virt = "$($place[$port])-0" }
        else {
            while ($usedVirt.ContainsKey("$nextVirt-0")) { $nextVirt++ }     # step over the guide / community channel numbers
            $virt = "$nextVirt-0"; $nextVirt++
        }
        $usedVirt[$virt] = $true
        if (-not $dupOf) { $dtvInEpg["$($t.Maj)-$($t.Min)"] = $virt }
        [void]$out.Add([pscustomobject]@{ Sort = $virt; Text = "$virt $($t.Maj)-$($t.Min)-$hdsd 1 $port" })
        [void]$changes.Add("ADDED    $virt  DIRECTV $($t.Maj) $($t.Name)  (tuner $($t.Tuner), port $port) - $(if ($between.ContainsKey($port)) { 'put back in its place' } else { 'new virtual channel' }), $hdsd like the other lines" + $(if ($dupOf) { "; same channel as $dupOf - delete this line if you don't want it twice" } else { '' }))
    }
    $lines = @($out | Sort-Object { if ($_.Sort -match '^(\d+)-(\d+)$') { [int]$Matches[1] * 1000 + [int]$Matches[2] } else { 999999 } } | ForEach-Object { $_.Text })
    return [pscustomobject]@{ Lines = $lines; Changes = @($changes); OldCount = $old.Count; NoQam = $noQam }
}

# Encode a form value exactly the way Chrome does for a GET form (application/x-www-form-urlencoded):
# letters, digits and * - . _ stay; a space becomes '+'; everything else is %XX in capitals.
# (The COM3000 does NOT understand %20 for a space - sending that emptied the EPG list.)
function ConvertTo-FormValue([string]$Value) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in [Text.Encoding]::UTF8.GetBytes($Value)) {
        $c = [char]$b
        if (($b -ge 0x30 -and $b -le 0x39) -or ($b -ge 0x41 -and $b -le 0x5A) -or ($b -ge 0x61 -and $b -le 0x7A) -or $c -in @('*', '-', '.', '_')) { [void]$sb.Append($c) }
        elseif ($b -eq 0x20) { [void]$sb.Append('+') }
        else { [void]$sb.Append('%' + $b.ToString('X2')) }
    }
    return $sb.ToString()
}

# The exact request the EPG page's Submit button sends: every field as it is on the page now
# (text boxes, the ticked checkboxes, the list), to the form's address. Returns the full URL.
function Get-EpgSubmitUrl([string]$EpgHtml, [string]$BladeIp, [string[]]$NewLines = $null) {
    $fm = [regex]::Match($EpgHtml, "(?is)<form\b[^>]*>(?:(?!</form>).)*?name=['""]?EpgList['""]?.*?</form>")
    if (-not $fm.Success) { throw 'The EPG form was not found on the page.' }
    $form = $fm.Value
    $attr = { param([string]$Tag, [string]$Name)
        $m = [regex]::Match($Tag, "(?i)\b$Name\s*=\s*(?:'([^']*)'|""([^""]*)""|([^\s>]+))")
        if ($m.Success) { [System.Net.WebUtility]::HtmlDecode(($m.Groups[1].Value + $m.Groups[2].Value + $m.Groups[3].Value)) } else { $null } }
    $pairs = New-Object System.Collections.ArrayList
    foreach ($el in [regex]::Matches($form, '(?is)<(input|select|textarea)\b[^>]*>(?:(?<=<select\b[^>]*>).*?</select>|(?<=<textarea\b[^>]*>).*?</textarea>)?')) {
        $tag = $el.Value; $kind = $el.Groups[1].Value.ToLower()
        $name = & $attr $tag 'name'; if (-not $name) { continue }
        if ($kind -eq 'input') {
            $type = "$(& $attr $tag 'type')".ToLower(); if (-not $type) { $type = 'text' }
            if ($type -in @('submit', 'button', 'reset', 'image', 'file')) { continue }      # Submit has no name; EpgLoad/EpgDisable are never sent
            if ($type -in @('checkbox', 'radio')) {
                if ($tag -notmatch '(?i)\bchecked\b') { continue }
                $v = & $attr $tag 'value'; if ($null -eq $v) { $v = 'on' }
            } else { $v = & $attr $tag 'value'; if ($null -eq $v) { $v = '' } }
            [void]$pairs.Add("$name=$(ConvertTo-FormValue $v)")
        } elseif ($kind -eq 'textarea') {
            $inner = [regex]::Match($tag, '(?is)<textarea\b[^>]*>(.*?)</textarea>').Groups[1].Value
            $inner = [System.Net.WebUtility]::HtmlDecode(($inner -replace '^\r?\n', ''))
            $v = (@($inner -split '\r?\n') -join "`r`n")
            if ($null -ne $NewLines -and $name -eq 'EpgList') { $v = (($NewLines | ForEach-Object { "$_" }) -join "`r`n") + "`r`n" }      # the new list instead of what's there (ends with a line break, like Chrome)
            [void]$pairs.Add("$name=$(ConvertTo-FormValue $v)")
        } else {
            $opt = [regex]::Match($tag, "(?is)<option\b[^>]*\bselected\b[^>]*>")
            if (-not $opt.Success) { $opt = [regex]::Match($tag, "(?is)<option\b[^>]*>") }
            $v = if ($opt.Success) { & $attr $opt.Value 'value' } else { '' }
            [void]$pairs.Add("$name=$(ConvertTo-FormValue "$v")")
        }
    }
    if (-not ($pairs | Where-Object { $_ -like 'EpgList=*' })) { throw 'The EPG list box was not found in the form.' }
    return "http://$BladeIp/cgi-bin/webcmd?" + ($pairs -join '&')
}

# SAFETY SWITCH: an early version sent spaces as %20, which the COM3000 doesn't accept - it emptied
# the EPG lists (Nov 2026). Fixed to send exactly what Chrome sends (spaces as +), confirmed on a
# real COM3000. Set to $false to stop the script from ever submitting the EPG.
$script:EpgSubmitEnabled = $true
$script:EpgSubmitAllowedNow = $false     # set only by the hand-run test (6. Refresh EPG now) after you type YES

# Re-submit each blade's EPG page as it is, then check the list is still there. One result per blade.
function Invoke-EpgRefresh {
    $hosts = @("$EpgRefreshBlades" -split '[,\s]+' | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
    $onlyWithList = $false
    if (-not $hosts) { $hosts = @(@(Get-ComHosts) + @("$EpgIp".Trim()) | Where-Object { $_ } | Select-Object -Unique); $onlyWithList = $true }
    $results = New-Object System.Collections.ArrayList
    foreach ($h in $hosts) {
        try {
            if (-not (Test-HostPort $h 3000)) { throw "$h is not answering" }
            $page = Get-PageHtml "http://$h/cgi-bin/webcmd?screen=EpgDisplay"
            $before = Get-EpgBoxLines $page
            if ($null -eq $before) { if ($onlyWithList) { continue } else { throw "$h has no EPG page" } }
            if ($before.Count -eq 0) { if ($onlyWithList) { continue } else { throw "$h has an empty EPG list - not submitted" } }
            # keep a copy of what's there now on the desktop, so it can be pasted back
            try {
                $desk0 = Get-EpgCopyDir
                Set-Content -Path (Join-Path $desk0 "$(($SiteName -replace '[\\/:*?"<>|]', '').Trim()) EPG before refresh - $h.txt") -Value $before -Encoding ASCII -ErrorAction Stop
            } catch {}
            if (-not ($script:EpgSubmitEnabled -or $script:EpgSubmitAllowedNow)) {
                $u = Get-EpgSubmitUrl $page $h
                $desk = Get-EpgCopyDir
                try { Add-Content -Path (Join-Path $desk 'EPG submit test - what the script would send.txt') -Value @("$(Get-Date)  $h", $u, '') -ErrorAction Stop } catch {}
                throw "submitting from the script is turned off for now - nothing was sent to $h (the request it would send is saved in the desktop folder 'COM3000 EPG copies')"
            }
            [void](Get-PageHtml (Get-EpgSubmitUrl $page $h))
            Start-Sleep -Seconds 2
            $page2 = Get-PageHtml "http://$h/cgi-bin/webcmd?screen=EpgDisplay"
            $after = Get-EpgBoxLines $page2
            if ($null -eq $after -or (($after -join '|') -ne ($before -join '|'))) {
                # SAFETY NET: put the list back the way it was
                $fixed = $false
                try { [void](Get-PageHtml (Get-EpgSubmitUrl $page2 $h $before)); Start-Sleep -Seconds 2; $chk = Get-EpgBoxLines (Get-PageHtml "http://$h/cgi-bin/webcmd?screen=EpgDisplay"); $fixed = (($chk -join '|') -eq ($before -join '|')) } catch {}
                throw "$h - the EPG list didn't come back the same after submitting ($(if ($after) { $after.Count } else { 0 }) lines, expected $($before.Count)); $(if ($fixed) { 'the old list was put back' } else { 'COULD NOT put the old list back - paste it from the file in the desktop folder COM3000 EPG copies' })"
            }
            [void]$results.Add([pscustomobject]@{ Host = $h; Ok = $true; Lines = $before.Count; Err = '' })
        } catch {
            [void]$results.Add([pscustomobject]@{ Host = $h; Ok = $false; Lines = 0; Err = (Get-CleanError $_) })
        }
    }
    return $results
}

# EPG list lines currently in an EPG page's box
function Get-EpgBoxLines([string]$EpgHtml) {
    $m = [regex]::Match($EpgHtml, "(?is)<textarea[^>]*name=['""]?EpgList['""]?[^>]*>(.*?)</textarea>")
    if (-not $m.Success) { return $null }
    return ,@(Get-HtmlText $m.Groups[1].Value | ForEach-Object { $_.Trim() } | Where-Object { $_ })     # the comma keeps an empty list from turning into 'no page'
}
# A ready-to-submit copy of one blade's EPG page: that blade's own form, every setting (checkboxes)
# exactly as it is now, with the new list in the box. Nothing is sent until Submit is pressed.
function New-EpgSubmitPage([string]$EpgHtml, [string[]]$Lines, [string]$BladeIp, [string]$BladeName, [string[]]$Changes, [string]$Note) {
    $fm = [regex]::Match($EpgHtml, "(?is)<form\b[^>]*>(?:(?!</form>).)*?name=['""]?EpgList['""]?.*?</form>")
    if (-not $fm.Success) { throw 'EPG form not found' }
    $form = $fm.Value
    $enc = [System.Net.WebUtility]::HtmlEncode(($Lines -join "`r`n"))
    $form = [regex]::Replace($form, "(?is)(<textarea[^>]*name=['""]?EpgList['""]?[^>]*>).*?(</textarea>)", { param($mm) $mm.Groups[1].Value + $enc + $mm.Groups[2].Value })
    $form = [regex]::Replace($form, "(?i)action=['""][^'""]*['""]", "action='http://$BladeIp/cgi-bin/webcmd'", 1)
    $form = [regex]::Replace($form, "(?i)<input[^>]*name=['""]?(EpgLoad|EpgDisable)['""]?[^>]*>[^<\r\n]*", '')     # only the normal Submit stays
    $form = $form -replace '(&lt;|<)-\s*Load currently playing channels\.', ''
    $form = [regex]::Replace($form, "(?i)<input type=['""]submit['""]>", "<input type='submit' value='Submit to $BladeName ($BladeIp)' style='font-size:16px;padding:6px 18px;background:#1f7a3f;color:#fff;border:0;border-radius:4px;cursor:pointer'>", 1)
    $chg = if ($Changes.Count) { '<ul>' + (($Changes | ForEach-Object { '<li>' + [System.Net.WebUtility]::HtmlEncode($_) + '</li>' }) -join '') + '</ul>' } else { '<p><b>This blade''s EPG already matches the Overview page - nothing to change.</b></p>' }
    $noteHtml = if ($Note) { "<div class='box'>$([System.Net.WebUtility]::HtmlEncode($Note))</div>" } else { '' }
    $safeSite = [System.Net.WebUtility]::HtmlEncode($SiteName)
    return @"
<!doctype html><html><head><meta charset='utf-8'><title>$safeSite EPG - $BladeName $BladeIp</title>
<style>body{font:14px Segoe UI,Arial,sans-serif;margin:16px;max-width:1000px} .box{background:#fff8d6;border:1px solid #e0c96b;padding:10px 14px;border-radius:6px;margin-bottom:14px}
.blade{display:inline-block;background:#1f5f8b;color:#fff;padding:3px 10px;border-radius:4px;font-weight:600}
li{font-family:Consolas,monospace;font-size:13px}</style></head><body>
<h2>$safeSite - EPG for <span class='blade'>$BladeName &middot; $BladeIp</span></h2>
<div class='box'><b>Nothing has been sent yet.</b> This is the EPG page of <b>$BladeName ($BladeIp)</b> with its settings and checkboxes as they are now, and the new channel list already in the box.
Check the boxes are right for this blade, then press <b>Submit</b> at the bottom. Run Backup Now first so you can go back.</div>
$noteHtml
<h3>Changes on this blade</h3>$chg
<pre style='font:13px Consolas,monospace'>$form</pre>
</body></html>
"@
}

if ($RefreshEpg) {
    if (-not $script:EpgSubmitEnabled) {
        # test mode: send only after you say so, and only from this window
        $targets = @("$EpgRefreshBlades" -split '[,\s]+' | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
        Write-Host 'TEST: this re-submits the EPG page exactly as it is (same list, same checkboxes), the same request Chrome sends.' -ForegroundColor Yellow
        Write-Host "Blades: $(if ($targets) { $targets -join ', ' } else { 'every blade that has an EPG list' })"
        Write-Host 'Each blade''s current list is saved first in the desktop folder 'COM3000 EPG copies' ("... EPG before refresh - <IP>.txt"), so you can paste it back.'
        $one = "$(Read-Host 'Test on ONE blade only? Type its IP address (e.g. 192.168.3.19), or Enter for the list above')".Trim()
        if ($one -match '^\d+\.\d+\.\d+\.\d+$') { $EpgRefreshBlades = $one }
        if ("$(Read-Host 'Type YES to send')".Trim() -notmatch '^(yes|y)$') { Write-Host 'Cancelled - nothing was sent.'; return }
        $script:EpgSubmitAllowedNow = $true
    }
    Write-Host "Re-submitting the EPG page(s) for $SiteName, exactly as they are..." -ForegroundColor Cyan
    $res = @(Invoke-EpgRefresh)
    if (-not $res) { Write-Host 'No blade with an EPG list was found.' -ForegroundColor Yellow }
    foreach ($x in $res) {
        if ($x.Ok) { Write-Host "  $($x.Host): refreshed ($($x.Lines) lines, unchanged)" -ForegroundColor Green; Write-Log "EPG refreshed by hand on $($x.Host) ($($x.Lines) lines)" }
        else { Write-Host "  FAILED: $($x.Err)" -ForegroundColor Red }
    }
    if (@($res | Where-Object { -not $_.Ok }).Count) { Write-Host 'If a list is now wrong or empty: open "... EPG before refresh - <IP>.txt" in the desktop folder 'COM3000 EPG copies', paste it into that blade''s EPG box and press Submit.' -ForegroundColor Yellow }
    return
}

# ---------------------------------------------------------------------------
#  -OpenBlades: close Chrome, then open it again with a tab for every COM3000 blade.
#  Runs from the 'COM3000 Blades' desktop icon.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
#  -ShowIp: show this PC's address (the one to type into a blade's EPG DestIP), copied to the clipboard
# ---------------------------------------------------------------------------
if ($SetWallpaper) {
    if ("$Wallpaper" -notin 'blue', 'gray') { $Wallpaper = 'blue' }
    $a = Read-Host "Background color: blue or gray [$Wallpaper]"
    if ($a -match '^\s*(g|gray|grey)\s*$') { $Wallpaper = 'gray' } elseif ($a -match '^\s*b') { $Wallpaper = 'blue' }
    Set-ComWallpaper $SiteName
    # remember the choice for next time
    try { if (Test-Path $SettingsFile) { $t = Get-Content $SettingsFile -Raw; if ($t -match '(?m)^\$Wallpaper\s*=') { $t = $t -replace "(?m)^\`$Wallpaper(\s*)=\s*'[^']*'", "`$Wallpaper`${1}= '$Wallpaper'" } else { $t += "`r`n`$Wallpaper          = '$Wallpaper'`r`n" }; Set-Content -Path $SettingsFile -Value $t.TrimEnd() -Encoding UTF8 } } catch {}
    exit 0
}

if ($ShowIp) {
    Add-Type -AssemblyName System.Windows.Forms
    $rows = @()
    try {
        foreach ($a in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } | Sort-Object InterfaceAlias)) {
            $rows += [pscustomobject]@{ Ip = $a.IPAddress; Name = $a.InterfaceAlias }
        }
    } catch {
        foreach ($a in @([System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) | Where-Object { $_.AddressFamily -eq 'InterNetwork' -and "$_" -notmatch '^(127\.|169\.254\.)' })) { $rows += [pscustomobject]@{ Ip = "$a"; Name = '' } }
    }
    # the one on the COM3000's network (same first three numbers as the COM3000) goes first
    $com = Get-ComMainIp
    $pre = if ($com -match '^(\d+\.\d+\.\d+)\.') { $Matches[1] + '.' } else { '' }
    $best = @($rows | Where-Object { $pre -and $_.Ip.StartsWith($pre) }) | Select-Object -First 1
    if (-not $best) { $best = $rows | Select-Object -First 1 }
    if (-not $best) { [void][System.Windows.Forms.MessageBox]::Show('No network address found - is the network cable plugged in?', 'This PC''s IP'); exit 1 }
    try { [System.Windows.Forms.Clipboard]::SetText($best.Ip) } catch {}
    $txt = "This PC's IP:   $($best.Ip)`n`n(copied - paste it into DestIP on a blade's EPG page)"
    if ($com) { $txt += "`n`nCOM3000: $com" }
    $others = @($rows | Where-Object { $_.Ip -ne $best.Ip })
    if ($others.Count) { $txt += "`n`nOther addresses on this PC:`n" + (($others | ForEach-Object { "   $($_.Ip)   $($_.Name)" }) -join "`n") }
    [void][System.Windows.Forms.MessageBox]::Show($txt, "This PC's IP - $SiteName", 'OK', 'Information')
    exit 0
}

if ($OpenBlades) {
    # the addresses to try - a tab opens only for the ones that answer (a site with 2 blades gets 2 tabs)
    $tryBlades = @('192.168.3.18', '192.168.3.19', '192.168.3.20', '192.168.3.21', '192.168.3.22', '192.168.3.23')
    $alwaysOpen = @('192.168.10.2')       # WebSTX - always opened
    foreach ($h in @(Get-ComHosts) + @("$EpgIp".Trim())) { if ($h -match '^\d+\.\d+\.\d+\.\d+$' -and $tryBlades -notcontains $h) { $tryBlades += $h } }
    $ips = @()
    # at startup the network can take a minute: keep trying for up to 2 minutes until a blade answers
    $until = (Get-Date).AddMinutes(2)
    do {
        $tests = @($tryBlades | ForEach-Object { $tc = New-Object Net.Sockets.TcpClient; [pscustomobject]@{ Ip = $_; Tc = $tc; Task = $tc.ConnectAsync($_, 80) } })
        try { [void][Threading.Tasks.Task]::WaitAll(@($tests | ForEach-Object { $_.Task }), 1200) } catch {}
        $ips = @($tests | Where-Object { $_.Task.Status -eq 'RanToCompletion' -and $_.Tc.Connected } | ForEach-Object { $_.Ip })
        foreach ($t in $tests) { try { $t.Tc.Close() } catch {} }
        if ($ips.Count) { break }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $until)
    $ips = @($ips | Sort-Object { [version]$_ })
    if (-not $ips.Count) { Write-Log 'Open blades: no blade answered - opening WebSTX only' }

    # close every Chrome window first, so there's only one set of blade tabs
    $open = @(Get-Process -Name chrome -ErrorAction SilentlyContinue)
    foreach ($p in $open) { try { $p.CloseMainWindow() | Out-Null } catch {} }
    for ($i = 0; $i -lt 8 -and $open.Count -and (Get-Process -Name chrome -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 250 }      # up to 2 s, only if Chrome was open
    Get-Process -Name chrome -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 20 -and (Get-Process -Name chrome -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 250 }

    # only the blades that have an EPG list (usually 2) - fewer tabs, so a small PC doesn't freeze.
    # Uses the blades picked for the daily EPG refresh (installer question 17), otherwise reads each blade's EPG page.
    $epgIps = @("$EpgRefreshBlades" -split '[,\s]+' | Where-Object { $ips -contains $_ })
    if (-not $epgIps.Count -and $ips.Count) {
        try {
            Add-Type -AssemblyName System.Net.Http
            $hc = New-Object System.Net.Http.HttpClient; $hc.Timeout = [TimeSpan]::FromSeconds(4)
            $jobs = @($ips | ForEach-Object { [pscustomobject]@{ Ip = $_; Task = $hc.GetStringAsync("http://$_/cgi-bin/webcmd?screen=EpgDisplay") } })
            try { [void][Threading.Tasks.Task]::WaitAll(@($jobs | ForEach-Object { $_.Task }), 4500) } catch {}
            foreach ($j in $jobs) { if ($j.Task.Status -eq 'RanToCompletion') { $bl = Get-EpgBoxLines $j.Task.Result; if ($bl -and $bl.Count) { $epgIps += $j.Ip } } }
            $hc.Dispose()
        } catch {}
    }
    if ($epgIps.Count) { $ips = @($ips | Where-Object { $epgIps -contains $_ }) }      # none found: open them all
    $urls = @($ips | ForEach-Object { "http://$_/" })      # the blade's main page (lighter than the Overview)
    # streamers and other devices from installer question 19 (opened even if they don't answer yet)
    foreach ($x in @("$ExtraTabs" -split '[,\s]+' | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+(:\d+)?$' })) { $urls += "http://$x/" }
    foreach ($h in $alwaysOpen) {
        # WebSTX: sign in with the backend user/password saved by the installer (question 14), so no sign-in box
        $u = "http://$h/"; $why = ''
        if (-not "$SystemResetHost") { $why = 'no WebSTX address saved (installer question 14 was skipped or set to none)' }
        elseif ($h -ne "$SystemResetHost") { $why = "installer question 14 has $SystemResetHost, not $h" }
        elseif (-not "$SystemResetUser" -or -not "$SystemResetSecret") { $why = 'no WebSTX user/password saved (installer question 14)' }
        else {
            # a blank password is fine - it's what the installer's login check accepted
            try { $pw = "$(Unprotect-ResetPassword $SystemResetSecret)"; $u = "http://$([uri]::EscapeDataString("$SystemResetUser")):$([uri]::EscapeDataString($pw))@$h/"; $why = "signing in as $SystemResetUser$(if (-not $pw) { ' (blank password)' })" }
            catch { $why = "the saved password couldn't be read on this PC ($($_.Exception.Message))" }
        }
        Write-Log "Open blades: WebSTX $h - $why"; Write-Host "WebSTX $h - $why"
        $urls += $u
    }
    $chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    try {
        # all tabs in one go (only a few light pages now) - Chrome then shows the FIRST tab
        $exe = if ($chrome) { $chrome } else { 'chrome' }
        Start-Process -FilePath $exe -ArgumentList (@('--new-window', '--hide-crash-restore-bubble') + $urls) -ErrorAction Stop
        Write-Log "Opened Chrome with: $((@($ips) + @($alwaysOpen)) -join ', ')"
    } catch { foreach ($u in $urls) { Start-Process $u }; Write-Log "Chrome not found - opened them in the default browser" }
    exit 0
}

if ($MakeEpg) {
    if (-not (Test-Path $SettingsFile)) {
        # brand-new location, monitor not installed yet: ask where the COM3000 is
        $cur = if ($PageUrl -match '^https?://([^/]+)') { $Matches[1] } else { '' }
        $a = Read-Host "COM3000 IP address [$cur]"
        if ("$a".Trim()) { $PageUrl = "http://$("$a".Trim())/cgi-bin/webcmd?screen=Overview" }
        $n = Read-Host 'Location name (for the file names)'
        if ("$n".Trim()) { $SiteName = "$n".Trim() }
    }
    Write-Host "Building the EPG list for $SiteName from the Overview page..." -ForegroundColor Cyan
    try {
        $ov = Get-ComOverview
        $ovHtml = $ov.Html

        # every blade (card) on the Overview page, plus the EPG address from Settings if it's another one
        $blades = New-Object System.Collections.ArrayList
        foreach ($sl in @($ov.Data.Slots | Where-Object { "$($_.Ip)" -match '^\d+\.\d+\.\d+\.\d+$' } | Sort-Object { [int]$_.Slot })) {
            [void]$blades.Add([pscustomobject]@{ Name = "Slot $($sl.Slot)"; Ip = "$($sl.Ip)"; Html = $null; Lines = $null })
        }
        $comNow = Get-ComIp
        if ($comNow -and -not ($blades | Where-Object { $_.Ip -eq $comNow })) {
            [void]$blades.Insert(0, [pscustomobject]@{ Name = 'COM3000'; Ip = $comNow; Html = $null; Lines = $null })
        }
        if ("$EpgIp".Trim() -and -not ($blades | Where-Object { $_.Ip -eq "$EpgIp".Trim() })) {
            [void]$blades.Add([pscustomobject]@{ Name = 'EPG'; Ip = "$EpgIp".Trim(); Html = $null; Lines = $null })
        }
        Write-Host ''
        Write-Host 'EPG on each blade right now:'
        for ($i = 0; $i -lt $blades.Count; $i++) {
            $bl = $blades[$i]
            try { $bl.Html = Get-PageHtml "http://$($bl.Ip)/cgi-bin/webcmd?screen=EpgDisplay"; $bl.Lines = Get-EpgBoxLines $bl.Html } catch {}
            $what = if ($null -eq $bl.Html) { 'not answering' } elseif ($null -eq $bl.Lines) { 'no EPG page' } elseif ($bl.Lines.Count -eq 0) { 'empty' } else { "$($bl.Lines.Count) lines" }
            Write-Host ("  {0}) {1,-7} {2,-15}  {3}" -f ($i + 1), $bl.Name, $bl.Ip, $what)
        }
        $usable = @(for ($i = 0; $i -lt $blades.Count; $i++) { if ($null -ne $blades[$i].Lines) { $i } })
        if ($usable.Count -eq 0) { throw 'No blade has an EPG page that answered.' }
        $withList = @($usable | Where-Object { $blades[$_].Lines.Count -gt 0 })
        $def = if ($withList.Count) { $withList } else { @($usable[0]) }
        $defTxt = ($def | ForEach-Object { $_ + 1 }) -join ','
        $pick = @()
        for ($try = 0; $try -lt 5; $try++) {
            $a = Read-Host "Put the EPG on which blade(s)? Numbers like 1,2 [$defTxt]"
            if (-not "$a".Trim()) { $pick = @($def); break }
            $nums = @("$a" -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { $v = 0; if ([int]::TryParse($_, [ref]$v)) { $v - 1 } else { -1 } })
            if ($nums.Count -and -not @($nums | Where-Object { $usable -notcontains $_ }).Count) { $pick = @($nums | Select-Object -Unique); break }
            Write-Host "  Please enter numbers from the list (only blades with an EPG page), like 1,2." -ForegroundColor Yellow
        }
        if ($null -eq $pick -or $pick.Count -eq 0) { $pick = @($def) }

        # Each blade keeps ITS OWN list (numbers, guide, community lines) - only the DIRECTV numbers are fixed
        # to match the tuners. An empty blade gets a copy of the fullest list.
        $ref = $blades[@($pick | Sort-Object { -$blades[$_].Lines.Count })[0]]
        $start = 3; $guidePort = 20; $guideVirt = 0; $community = New-Object System.Collections.ArrayList
        $askNum = {
            param([string]$Prompt, [int]$Default, [int]$Min, [int]$Max, [string]$Example, [bool]$AllowNone)
            for ($try = 0; $try -lt 5; $try++) {
                $a = "$(Read-Host "  $Prompt [$(if ($Default) { $Default } else { 'none' })]")".Trim() -replace '-0$', ''
                if (-not $a) { return $Default }
                if ($AllowNone -and $a -match '^(none|no|0)$') { return 0 }
                $v = 0; if ([int]::TryParse($a, [ref]$v) -and $v -ge $Min -and $v -le $Max) { return $v }
                Write-Host "  Please enter a number like $Example$(if ($AllowNone) { ', or none' })." -ForegroundColor Yellow
            }
            return $Default
        }
        # community / internal channels (from an encoder - not on the Overview page); $taken = number -> what uses it
        $askCommunity = {
            param([hashtable]$taken)
            for ($k = 1; $k -le 10; $k++) {
                $nm = "$(Read-Host "  Community channel $k name (e.g. Emerald Oaks Channel; Enter = $(if ($k -eq 1) { 'none' } else { 'done' }))")".Trim()
                if (-not $nm) { break }
                $nm = ($nm -replace '\s+', '_') -replace '[^\w\-]', ''
                $suggest = 2; while ($taken.ContainsKey($suggest)) { $suggest++ }
                $cv = 0
                for ($try = 0; $try -lt 5; $try++) {
                    $cv = & $askNum "  Its virtual channel" $suggest 1 9999 '3' $false
                    if ($taken.ContainsKey($cv)) { Write-Host "  $cv-0 is already $($taken[$cv]) - pick another number." -ForegroundColor Yellow; $cv = 0 } else { break }
                }
                if (-not $cv) { continue }
                $cp = 0
                for ($try = 0; $try -lt 5 -and -not $cp; $try++) {
                    $a = "$(Read-Host '    Its QAM port (e.g. 737 or 738)')".Trim()
                    $v = 0; if ([int]::TryParse($a, [ref]$v) -and $v -ge 1 -and $v -le 65535) { $cp = $v } else { Write-Host '    Please enter the port number from the encoder / QAM setup.' -ForegroundColor Yellow }
                }
                if (-not $cp) { Write-Host "    Skipped $nm - no port." -ForegroundColor Yellow; continue }
                [void]$community.Add([pscustomobject]@{ Name = $nm; Virt = $cv; Port = $cp }); $taken[$cv] = $nm
            }
        }
        $isChan  = { param($l) $l -match '^\d+-\d+\s+\d+-\d+-(hd|sd)\b' }
        $isGuide = { param($l) $l -match '^\d+-\d+\s+NEPG' }
        $isComm  = { param($l) $l -match '^\d+-\d+\s+N' -and $l -notmatch '^\d+-\d+\s+NEPG' }
        $withChan = @($pick | Where-Object { @($blades[$_].Lines | Where-Object { & $isChan $_ }).Count -gt 0 })
        $noGuide = @(); $noComm = @()
        if ($withChan.Count -eq 0) {
            Write-Host ''
            Write-Host 'The EPG has no channels yet - this looks like a new location.' -ForegroundColor Yellow
            $guideVirt = & $askNum 'Guide channel on virtual channel (none = no guide line)' 2 1 9999 '2' $true
            if ($guideVirt) {
                Write-Host '  Guide port: 20 for most locations (401 / AEP guide); with GuideChannel + PSIP on, use the DestPort (e.g. 753).'
                $guidePort = & $askNum 'Guide channel port' 20 1 65535 '20 or 753' $false
            }
            $taken = @{}; if ($guideVirt) { $taken[$guideVirt] = 'the guide' }
            Write-Host '  Community / internal channels (from an encoder):'
            & $askCommunity $taken
            Write-Host '  The first tuner (slot 1, tuner 1) gets the next number, the next tuner the one after, and so on'
            Write-Host '  (numbers already used by the guide or a community channel are skipped).'
            $after = 2; if ($taken.Count) { $after = (@($taken.Keys) | Measure-Object -Maximum).Maximum }
            $start = & $askNum 'Start the tuners at virtual channel' ([int]$after + 1) 1 9999 '3 or 100' $false
        } else {
            # blades with channels but no guide / no community line: offer to add them there
            $noGuide = @($withChan | Where-Object { -not @($blades[$_].Lines | Where-Object { & $isGuide $_ }).Count })
            $noComm  = @($withChan | Where-Object { -not @($blades[$_].Lines | Where-Object { & $isComm $_ }).Count })
            $taken = @{}
            foreach ($i in $withChan) { foreach ($l in $blades[$i].Lines) { if ($l -match '^(\d+)-0\s') { $taken[[int]$Matches[1]] = 'used' } } }
            if ($noGuide.Count) {
                Write-Host ''
                Write-Host ("No guide channel line on: " + (($noGuide | ForEach-Object { "$($blades[$_].Name) ($($blades[$_].Ip))" }) -join ', ')) -ForegroundColor Yellow
                $guideVirt = & $askNum 'Add the guide there on virtual channel, e.g. 2 (Enter = leave it out)' 0 1 9999 '2' $true
                if ($guideVirt -and $taken.ContainsKey($guideVirt)) { Write-Host "  $guideVirt-0 is already used - guide not added." -ForegroundColor Yellow; $guideVirt = 0 }
                if ($guideVirt) {
                    Write-Host '  Guide port: 20 for most locations (401 / AEP guide); with GuideChannel + PSIP on, use the DestPort (e.g. 753).'
                    $guidePort = & $askNum 'Guide channel port' 20 1 65535 '20 or 753' $false
                    $taken[$guideVirt] = 'the guide'
                }
            }
            if ($noComm.Count) {
                Write-Host ''
                Write-Host ("No community / internal channel on: " + (($noComm | ForEach-Object { "$($blades[$_].Name) ($($blades[$_].Ip))" }) -join ', ') + ". Add one? (Enter = no)") -ForegroundColor Yellow
                & $askCommunity $taken
            }
        }

        # build each chosen blade's list
        $desk = Get-EpgCopyDir
        $safe = ($SiteName -replace '[\\/:*?"<>|]', '').Trim()
        $refIdx = if ($withChan.Count) { @($withChan | Sort-Object { -$blades[$_].Lines.Count })[0] } else { $pick[0] }
        $refBuilt = Build-EpgFromOverview $ovHtml $blades[$refIdx].Html $start $guidePort $(if ($noGuide -contains $refIdx -or -not $withChan.Count) { $guideVirt } else { 0 }) $(if ($noComm -contains $refIdx -or -not $withChan.Count) { $community } else { @() })
        $plan = foreach ($i in $pick) {
            $bl = $blades[$i]
            if ($withChan -contains $i) {
                $rb = if ($i -eq $refIdx) { $refBuilt } else { Build-EpgFromOverview $ovHtml $bl.Html $start $guidePort $(if ($noGuide -contains $i) { $guideVirt } else { 0 }) $(if ($noComm -contains $i) { $community } else { @() }) }
                $note = if (($bl.Lines -join '|') -eq ($rb.Lines -join '|')) { 'no change (submitting again also refreshes the guide)' } else { "$($rb.Changes.Count) change(s)" }
                [pscustomobject]@{ Blade = $bl; Lines = $rb.Lines; Changes = @($rb.Changes); Note = $note; NoQam = $rb.NoQam }
            } else {
                [pscustomobject]@{ Blade = $bl; Lines = $refBuilt.Lines; Changes = @("This blade's EPG is empty - it gets a copy of $($blades[$refIdx].Name)'s list ($($refBuilt.Lines.Count) lines).") + @($refBuilt.Changes); Note = "empty now - gets a copy of $($blades[$refIdx].Name)'s list ($($refBuilt.Lines.Count) lines)"; NoQam = $refBuilt.NoQam }
            }
        }
        if ($start -le 2 -and -not $withChan.Count) { Write-Host '  (Starting at 1 or 2 leaves no room for the guide on 2-0 - add the guide line yourself if you want one.)' -ForegroundColor Yellow }

        Write-Host ''
        foreach ($p in $plan) {
            $bl = $p.Blade
            Write-Host "$($bl.Name) ($($bl.Ip)):" -ForegroundColor Cyan
            if (($bl.Lines -join '|') -eq ($p.Lines -join '|')) { Write-Host '  Already matches the Overview page - nothing to change.' -ForegroundColor Green }
            else { foreach ($c in $p.Changes) { Write-Host "  $c" -ForegroundColor $(if ($c -match '^(REMOVED|CHECK|ADDED|MOVED|This blade)') { 'Yellow' } else { 'Green' }) } }
        }
        if ($plan[0].NoQam) { Write-Host "  ($($plan[0].NoQam) tuner(s) have a channel but no QAM output picked, so no TV can get them - left out.)" -ForegroundColor Gray }
        Write-Host ''
        Write-Host 'Ready to submit to:' -ForegroundColor Cyan
        foreach ($p in $plan) { Write-Host ("  {0,-7} {1,-15}  {2}" -f $p.Blade.Name, $p.Blade.Ip, $p.Note) }
        Write-Host '  Each blade keeps its own list, checkboxes and settings - only wrong DIRECTV numbers are fixed.' -ForegroundColor Gray
        Write-Host ''
        if ($script:EpgSubmitEnabled) {
            $ans = "$(Read-Host 'Type YES to submit now, TABS to open the filled-in pages in Chrome instead, or Enter to cancel')".Trim()
        } else {
            Write-Host 'Submitting straight from here is turned off for now - you check each page and press Submit in Chrome.' -ForegroundColor Yellow
            $ans = "$(Read-Host 'Type TABS to open the filled-in pages in Chrome, or Enter to cancel')".Trim()
            if ($ans -match '^(yes|y)$') { $ans = 'tabs' }
        }

        if ($ans -match '^(yes|y)$') {
            # one copy of every blade's current EPG list first (replaced each time), so it can be put back.
            # Not the daily backup file - that one goes to Google Drive.
            $bkOk = $false
            try {
                $copy = Join-Path $desk "$safe EPG before submit.txt"
                $txt = @("$SiteName - EPG lists before submitting, $(Get-Date -Format 'ddd MM/dd/yyyy h:mm tt')", '')
                foreach ($bl in $blades) { if ($null -ne $bl.Lines) { $txt += @("EPG on $($bl.Name) $($bl.Ip)", '') + $bl.Lines + @('', '') } }
                Set-Content -Path $copy -Value $txt -Encoding UTF8 -ErrorAction Stop
                $bkOk = $true; Write-Host "Current EPG lists saved first: $copy" -ForegroundColor Gray; Write-Log "EPG lists saved before submitting: $copy"
            } catch { Write-Host "Couldn't save a copy of the current EPG lists ($(Get-CleanError $_))." -ForegroundColor Yellow }
            if (-not $bkOk -and "$(Read-Host 'Submit anyway? Type YES')".Trim() -notmatch '^(yes|y)$') { Write-Host 'Cancelled - nothing was submitted.'; return }
            foreach ($p in $plan) {
                $bl = $p.Blade
                try {
                    $page = Get-PageHtml "http://$($bl.Ip)/cgi-bin/webcmd?screen=EpgDisplay"       # fresh copy of that blade's own settings
                    [void](Get-PageHtml (Get-EpgSubmitUrl $page $bl.Ip $p.Lines))
                    Start-Sleep -Seconds 2
                    $after = Get-EpgBoxLines (Get-PageHtml "http://$($bl.Ip)/cgi-bin/webcmd?screen=EpgDisplay")
                    if ($after -and (($after -join '|') -eq ($p.Lines -join '|'))) {
                        Write-Host "  $($bl.Name) ($($bl.Ip)): saved - $($after.Count) lines" -ForegroundColor Green
                        Write-Log "EPG submitted on $($bl.Ip) ($($after.Count) lines) by Make EPG"
                    } else {
                        # SAFETY NET: put the blade's old list back
                        $fixed = $false
                        if ($bl.Lines.Count) {
                            try { [void](Get-PageHtml (Get-EpgSubmitUrl (Get-PageHtml "http://$($bl.Ip)/cgi-bin/webcmd?screen=EpgDisplay") $bl.Ip $bl.Lines)); Start-Sleep -Seconds 2
                                  $chk = Get-EpgBoxLines (Get-PageHtml "http://$($bl.Ip)/cgi-bin/webcmd?screen=EpgDisplay"); $fixed = (($chk -join '|') -eq ($bl.Lines -join '|')) } catch {}
                        }
                        Write-Host "  $($bl.Name) ($($bl.Ip)): the list didn't come out right ($(if ($after) { $after.Count } else { 0 }) lines) - $(if ($fixed) { 'the old list was put back.' } else { 'COULD NOT put the old list back - paste it from the backup.' })" -ForegroundColor Red
                        Write-Log "EPG submit on $($bl.Ip) did not stick ($(if ($after) { $after.Count } else { 0 }) lines afterwards); old list put back: $fixed"
                    }
                } catch { Write-Host "  $($bl.Name) ($($bl.Ip)): FAILED - $(Get-CleanError $_)" -ForegroundColor Red }
            }
        } elseif ($ans -match '^tabs?$') {
            $chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
            foreach ($p in $plan) {
                $bl = $p.Blade
                try {
                    $changes = if (($bl.Lines -join '|') -eq ($p.Lines -join '|')) { @() } else { $p.Changes }
                    $html = New-EpgSubmitPage $bl.Html $p.Lines $bl.Ip $bl.Name $changes ''
                    $pg = Join-Path $desk "$safe EPG ready to submit - $($bl.Name) $($bl.Ip).html"
                    Set-Content -Path $pg -Value $html -Encoding UTF8
                    Write-Host "Opening the filled-in EPG page for $($bl.Name) ($($bl.Ip)) - check its boxes, then press Submit." -ForegroundColor Cyan
                    $opened = $false
                    foreach ($exe in @($chrome, 'chrome') | Where-Object { $_ }) {        # 'chrome' = wherever Windows has it registered
                        if ($opened) { break }
                        try { Start-Process $exe -ArgumentList "`"$pg`"" -ErrorAction Stop; $opened = $true } catch {}
                    }
                    if (-not $opened) { try { Start-Process $pg -ErrorAction Stop; $opened = $true; Write-Host '  (Chrome not found - opened in the default browser.)' -ForegroundColor Yellow } catch {} }
                    if (-not $opened) { Write-Host "  Open it yourself: $pg" -ForegroundColor Yellow }
                } catch { Write-Host "Couldn't make the page for $($bl.Name) ($($bl.Ip)): $(Get-CleanError $_)" -ForegroundColor Yellow }
            }
        } else {
            Write-Host 'Cancelled - nothing was submitted. '
        }
    } catch {
        Write-Host "Could not build the EPG list: $(Get-CleanError $_)" -ForegroundColor Red
    }
    return
}

if ($BackupNow) {
    Write-Host "Backing up TuneAll and EPG for $SiteName..." -ForegroundColor Cyan
    try {
        $b = Invoke-Backup
        Write-Host "Saved $($b.TuneLines) Tune all lines and $($b.EpgLines) EPG lines to:" -ForegroundColor Green
        Write-Host "  $($b.File)"
        Write-Log "Backup saved (button): $($b.File)"
        if (Start-DriveCopy) { Write-Host 'Google Drive copy started - it will appear in Drive within a minute or two.' }
        else { Write-Host 'Google Drive copy is not set up yet - run the installer.' -ForegroundColor Yellow }
    } catch {
        Write-Host "Backup FAILED: $(Get-CleanError $_)" -ForegroundColor Red
        if ($_.Exception.Message -match 'denied') { Write-Host 'Run this as administrator (use the Backup Now button, which asks for permission).' -ForegroundColor Red }
    }
    return
}

# ---------------------------------------------------------------------------
# CHANNEL PICKER: watch channels in VLC by retuning ONE spare tuner to this PC.
# ---------------------------------------------------------------------------
$PickerPrefsFile = Join-Path $(if ($env:APPDATA) { $env:APPDATA } else { $ScriptDir }) 'COM3000Picker\picker-settings.json'

# Every IPv4 address this PC has right now, wired connections first
function Get-PickerAllIps {
    $list = New-Object System.Collections.ArrayList
    try {
        $nics = @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' })
        $order = @($nics | Sort-Object { if ($_.NetworkInterfaceType -eq 'Ethernet' -or $_.NetworkInterfaceType -eq 'GigabitEthernet') { 0 } elseif ($_.NetworkInterfaceType -eq 'Wireless80211') { 2 } else { 1 } })
        foreach ($n in $order) { foreach ($a in $n.GetIPProperties().UnicastAddresses) { if ($a.Address.AddressFamily -eq 'InterNetwork') { [void]$list.Add($a.Address.ToString()) } } }
    } catch {}
    if (-not $list.Count) {
        try { foreach ($a in [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName())) { if ($a.AddressFamily -eq 'InterNetwork') { [void]$list.Add($a.ToString()) } } } catch {}
    }
    return [string[]]@($list | Where-Object { $_ -notlike '127.*' -and $_ -notlike '169.254.*' })
}
# This PC's address on the COM3000's network - the WIRED one if the PC is on both cable and Wi-Fi
function Get-PickerPcIp {
    $prefix = ((Get-ComIp) -split '\.')[0..2] -join '.'
    $ips = Get-PickerAllIps
    $match = $ips | Where-Object { $_ -like "$prefix.*" } | Select-Object -First 1
    if ($match) { return $match }
    return ($ips | Select-Object -First 1)
}
# Addresses that count as "this PC" (current ones plus any this PC used before, e.g. Wi-Fi vs cable)
$script:PickerMyIps = @()

# Tuners the picker may use: idle (IP mode, 0.0.0.0, no channel) or already sending to this PC.
# Never a tuner that feeds the QAM card.
function Get-PickerTuners([string]$Html, [string]$PcIp) {
    $out = New-Object System.Collections.ArrayList
    foreach ($r in (Get-JsRows (Get-JsArrayText $Html 'cardArray'))) {
        if ($r.Count -lt 9) { continue }
        $ip = $r[4]
        $idle = ($ip -eq '0.0.0.0' -and $r[8] -eq '0')
        $mine = ($PcIp -and $ip -eq $PcIp) -or ($script:PickerMyIps -contains $ip)
        if ($idle -or $mine) { [void]$out.Add("$($r[0])-$($r[1])-$($r[2])") }
    }
    return [string[]]$out.ToArray()
}

# One tuner's row from the Overview data: where it sends, its bitrate/SNR, and its CardEdit index
function Get-PickerTunerRow([string]$Html, [string]$Tuner) {
    $i = 0
    foreach ($r in (Get-JsRows (Get-JsArrayText $Html 'cardArray'))) {
        if ($r.Count -ge 14 -and "$($r[0])-$($r[1])-$($r[2])" -eq $Tuner) {
            $mb = 0.0; [void][double]::TryParse($r[12], [Globalization.NumberStyles]::Float, $Inv, [ref]$mb)
            return [pscustomobject]@{ Index = $i; Ip = $r[4]; Port = $r[5]; Mbps = $mb; Snr = $r[13]; Slot = $r[1]; Num = $r[2] }
        }
        $i++
    }
    return $null
}
# Puts a spare tuner back to idle - the same as its CardEdit page's Channel_Close button.
# Only ever for a tuner that is sending to this PC.
function Invoke-PickerRelease([string]$Tuner, [string]$OverviewHtml = '') {
    if (-not $OverviewHtml) { $OverviewHtml = Get-PageHtml $PageUrl }
    $row = Get-PickerTunerRow $OverviewHtml $Tuner
    if (-not $row) { return $false }
    if ($row.Ip -eq '0.0.0.0') { return $true }                                   # already idle
    if ($script:PickerMyIps -notcontains $row.Ip) { return $false }               # not ours - never touch
    $page = Get-PageHtml "http://$(Get-ComIp)/cgi-bin/webcmd?screen=CardEdit&tune=$($row.Index)"
    $h = [regex]::Match($page, 'Slot=(\d+),\s*Tuner=(\d+)')
    if (-not $h.Success -or $h.Groups[1].Value -ne "$($row.Slot)" -or $h.Groups[2].Value -ne "$($row.Num)") { return $false }   # wrong page - stop
    $form = [regex]::Match($page, "(?is)<form[^>]*>(?:(?!</form>).)*?value='TuneCard'.*?</form>")
    if (-not $form.Success) { return $false }
    $pairs = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($form.Value, "(?is)<input([^>]*)>")) {
        $a = $m.Groups[1].Value
        if ($a -match "type=['""]?submit") { continue }
        $n = [regex]::Match($a, "name=['""]([^'""]+)"); $v = [regex]::Match($a, "value=['""]([^'""]*)")
        if ($n.Success) { [void]$pairs.Add("$([uri]::EscapeDataString($n.Groups[1].Value))=$([uri]::EscapeDataString($(if ($v.Success) { $v.Groups[1].Value } else { '' })))") }
    }
    foreach ($m in [regex]::Matches($form.Value, "(?is)<select[^>]*name=['""]([^'""]+)['""][^>]*>(.*?)</select>")) {
        $sel = [regex]::Match($m.Groups[2].Value, "(?is)<option[^>]*value=['""]([^'""]*)['""][^>]*selected")
        if (-not $sel.Success) { $sel = [regex]::Match($m.Groups[2].Value, "(?is)<option[^>]*value=['""]([^'""]*)") }
        [void]$pairs.Add("$([uri]::EscapeDataString($m.Groups[1].Value))=$([uri]::EscapeDataString($sel.Groups[1].Value))")
    }
    [void]$pairs.Add('Channel_Close=Channel_Close')
    [void](Get-PageHtml "http://$(Get-ComIp)/cgi-bin/webcmd?$($pairs -join '&')")
    return $true
}

# Is this tuner safe to retune right now? (re-checked before every channel change)
function Test-PickerTunerSafe([string]$Html, [string]$Tuner, [string]$PcIp) {
    return (@(Get-PickerTuners $Html $PcIp) -contains $Tuner)
}

# The line-up from the EPG page, with names and live bitrate/SNR from the Overview page
# Compare one guide (EPG) line with the tuner on the Overview page for the same virtual channel.
# Returns Mark 'OK' / 'X' and a plain reason when it doesn't match.
function Get-GuideMatch([string]$Maj, [string]$Min, $Live) {
    if (-not $Live) { return @{ Mark = 'X'; Why = "EPG lists DIRECTV $Maj but no tuner on the Overview page sends this channel" } }
    if ($Live.NoChannel) { return @{ Mark = 'X'; Why = "EPG says DIRECTV $Maj but the tuner has no channel (None)" } }
    $tMaj = "$($Live.Major)"; $tMin = "$($Live.Minor)"
    if ($tMaj -ne $Maj) { return @{ Mark = 'X'; Why = "EPG says DIRECTV $Maj, Overview tuner $($Live.Slot)-$($Live.Tuner) is on $tMaj" } }
    if ($Min -ne '65535' -and $tMin -and $tMin -ne $Min) { return @{ Mark = 'X'; Why = "EPG says $Maj-$Min, Overview tuner $($Live.Slot)-$($Live.Tuner) is on $tMaj-$tMin" } }
    return @{ Mark = 'OK'; Why = '' }
}

# The EPG is copied onto several blades. Check every blade's copy against the Overview page and say
# WHICH blade is wrong. $BladeEpgs = @{ '192.168.3.18' = <EPG page html>; ... }
# The scrolling guide (2-0) can be watched when a blade sends its own copy of the guide to THIS PC:
# on that blade's EPG page DestIP = this PC, DestPort = e.g. 5000, GuideChannel ticked.
# (The blade feeding the guide to the QAM is never touched.)
function Set-PickerGuideStream($Channels, [hashtable]$BladeEpgs) {
    # this PC's addresses - looked up once (fast .NET call, no WMI: Get-NetIPAddress could freeze the window)
    if (-not $script:MyIps) {
        $script:MyIps = @()
        try {
            foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
                foreach ($ua in $ni.GetIPProperties().UnicastAddresses) { if ($ua.Address.AddressFamily -eq 'InterNetwork') { $script:MyIps += "$($ua.Address)" } }
            }
        } catch {}
    }
    $mine = $script:MyIps
    $url = $null; $from = ''
    foreach ($h in @($BladeEpgs.Keys | Sort-Object)) {
        $html = "$($BladeEpgs[$h])"
        $ip = [regex]::Match($html, "(?i)name=['""]?EpgDestIp['""]?\s+value=['""]?([\d.]+)").Groups[1].Value
        $port = [regex]::Match($html, "(?i)name=['""]?destPort['""]?\s+value=['""]?(\d+)").Groups[1].Value
        $on = $html -match "(?i)<input[^>]*value=['""]?GuideChannel['""]?[^>]*\bchecked"
        if ($on -and $ip -and $port -and $port -ne '0' -and $mine -contains $ip) { $url = "udp://@:$port"; $from = $h; break }
    }
    foreach ($c in @($Channels | Where-Object { $_.Internal -and "$($_.RawName)" -match '^EPG' })) {
        if ($url) { $c.Url = $url; $c.Skip = $false; $c.Dtv = 'stream'; $c.GuideWhy = "guide copy from $from" }
        elseif ($c.Dtv -eq 'stream' -and "$($c.GuideWhy)" -like 'guide copy from*') { $c.Url = $null; $c.Skip = $true; $c.Dtv = 'COM3000'; $c.GuideWhy = '' }
    }
}

function Set-PickerBladeChecks($Channels, [string]$OverviewHtml, [hashtable]$BladeEpgs) {
    $maps = [ordered]@{}
    foreach ($ip in @($BladeEpgs.Keys | Sort-Object { [version]("$_" -replace '[^\d.]', '') })) {
        $lines = Get-EpgBoxLines $BladeEpgs[$ip]
        if (-not $lines) { continue }
        $m = @{}
        foreach ($l in $lines) { $x = [regex]::Match($l, '^(\d+-\d+)\s+(\d+)-(\d+)-(hd|sd)\b', 'IgnoreCase'); if ($x.Success) { $m[$x.Groups[1].Value] = @{ Maj = $x.Groups[2].Value; Min = $x.Groups[3].Value } } }
        if ($m.Count) { $maps[$ip] = $m }
    }
    if ($maps.Count -eq 0) { return }
    $live = @{}
    foreach ($c in (Get-ComData $OverviewHtml).Channels) { if (-not $live.ContainsKey($c.Virt)) { $live[$c.Virt] = $c } }
    foreach ($c in $Channels) {
        if ($c.Internal -or $c.ComMade) { continue }
        $l = $live[$c.Virt]
        $why = New-Object System.Collections.ArrayList
        foreach ($ip in $maps.Keys) {
            $e = $maps[$ip][$c.Virt]
            if (-not $e) {
                if ($l) { [void]$why.Add("missing from the EPG on $ip") }
            } elseif (-not $l) { [void]$why.Add("EPG on $ip lists DIRECTV $($e.Maj) but no tuner sends it")
            } elseif ($l.NoChannel) { [void]$why.Add("EPG on $ip says DIRECTV $($e.Maj) but the tuner has no channel (None)")
            } elseif ("$($l.Major)" -ne $e.Maj -or ($e.Min -ne '65535' -and "$($l.Minor)" -and "$($l.Minor)" -ne $e.Min)) {
                # same number but a different sub-channel (e.g. a game's alternate feed 652-1650): show both parts
                $minDiff = "$($l.Major)" -eq $e.Maj
                $eTxt = if ($minDiff) { "$($e.Maj)-$($e.Min)" } else { "$($e.Maj)" }
                $lTxt = if ($minDiff) { "$($l.Major)-$($l.Minor)" } else { "$($l.Major)" }
                [void]$why.Add("EPG on $ip says DIRECTV $eTxt, Overview tuner $($l.Slot)-$($l.Tuner) is on $lTxt")
            }
        }
        if ($why.Count) {
            # same problem on several blades -> say it once with all of them
            $byText = [ordered]@{}
            foreach ($w in $why) { $k = $w -replace '(on|from the EPG on) \d+\.\d+\.\d+\.\d+', '$1 #'; $ipw = [regex]::Match($w, '\d+\.\d+\.\d+\.\d+').Value; if (-not $byText.Contains($k)) { $byText[$k] = @() }; $byText[$k] += $ipw }
            $c.Guide = 'X'
            $c.GuideWhy = (@($byText.Keys | ForEach-Object { $_ -replace '#', ($byText[$_] -join ' and ') }) -join '; ')
        } elseif ($c.Tune) { $c.Guide = 'OK'; $c.GuideWhy = '' }
    }
}

# Short version of an EPG problem for the Notes column (the full sentence is in the tooltip / status bar):
# "EPG on 192.168.3.18 says DIRECTV 265, Overview tuner 1-1-1 is on 202" -> ".18: EPG 265, tuner 202"
function Get-GuideShort([string]$Why) {
    $parts = foreach ($w in ($Why -split '; ')) {
        $ips = @([regex]::Matches($w, '\d+\.\d+\.\d+\.(\d+)') | ForEach-Object { '.' + $_.Groups[1].Value }) -join '+'
        $who = if ($ips) { "$($ips): " } else { '' }
        if ($w -match 'says DIRECTV (\d+(?:-\d+)?), Overview tuner \S+ is on (\d+(?:-\d+)?)') { "$($who)EPG $($Matches[1]), tuner $($Matches[2])" }
        elseif ($w -match '^EPG says (?:DIRECTV )?(\d+(?:-\d+)?), Overview tuner \S+ is on (\d+(?:-\d+)?)') { "EPG $($Matches[1]), tuner $($Matches[2])" }
        elseif ($w -match 'missing from the EPG') { "$($who)missing from EPG" }
        elseif ($w -match 'lists DIRECTV (\d+) but no tuner') { "$($who)EPG $($Matches[1]), no tuner" }
        elseif ($w -match 'says DIRECTV (\d+) but the tuner has no channel') { "$($who)EPG $($Matches[1]), tuner None" }
        elseif ($w -match '^not in the EPG') { 'not in the EPG' }
        else { $w }
    }
    return ($parts -join '; ')
}

function Get-PickerChannels([string]$OverviewHtml, [string]$EpgHtml) {
    $names = @{}
    foreach ($c in (Get-JsRows (Get-JsArrayText $OverviewHtml 'channelArray'))) {
        if ($c.Count -ge 3 -and $c[2] -and $c[2] -ne 'None') { $k = "$($c[0])-$($c[1])"; if (-not $names.ContainsKey($k)) { $names[$k] = $c[2] } }
    }
    $live = @{}
    try { foreach ($ch in (Get-ComData $OverviewHtml).Channels) { if (-not $live.ContainsKey($ch.Virt)) { $live[$ch.Virt] = $ch } } } catch {}

    $m = [regex]::Match($EpgHtml, "(?is)<textarea[^>]*name=['""]?EpgList['""]?[^>]*>(.*?)</textarea>")
    if (-not $m.Success) { throw 'The EPG list was not found on the EPG page.' }
    $list = New-Object System.Collections.ArrayList; $inEpg = @{}
    foreach ($line in (Get-HtmlText $m.Groups[1].Value)) {
        $x = [regex]::Match($line.Trim(), '^(\d+)-(\d+)\s+(\d+)-(\d+)-(hd|sd)\b', 'IgnoreCase')
        if (-not $x.Success) {
            # Channels the COM3000 makes itself (guide, internal channels): "2-0 NEPG_Electronic_Program_Guide 1 20".
            # They can't be tuned on a spare tuner, but they're listed with their bitrate from the QAM page.
            $n = [regex]::Match($line.Trim(), '^(\d+)-(\d+)\s+N(\S+)\s+(-?\d+)\s+(\d+)')
            if ($n.Success) {
                $raw = $n.Groups[3].Value
                $url = $null; foreach ($k in @($InternalStreams.Keys)) { if ($k -ieq $raw) { $url = $InternalStreams[$k] } }
                $inEpg["$($n.Groups[1].Value)-$($n.Groups[2].Value)"] = $true
                [void]$list.Add([pscustomobject]@{
                    Virt = "$($n.Groups[1].Value)-$($n.Groups[2].Value)"; Name = ($raw -replace '_', ' '); Dtv = $(if ($url) { 'stream' } else { 'COM3000' }); Tune = ''
                    Rate = ''; Snr = ''; Skip = (-not $url); Check = ''; Note = ''; Internal = $true; Port = [int]$n.Groups[5].Value
                    RawName = $raw; Url = $url; Guide = ''; GuideWhy = ''
                })
            }
            continue
        }
        $virt = "$($x.Groups[1].Value)-$($x.Groups[2].Value)"
        $maj = $x.Groups[3].Value; $min = $x.Groups[4].Value
        # the name the tuner shows on the Overview page first, then the COM3000's channel list
        $name = if ($live[$virt] -and $live[$virt].Channel -match '^\d+\s+(\S.*)$' -and $live[$virt].Channel -notmatch 'NO CHANNEL') { $Matches[1] } else { '' }
        if (-not $name) { $name = $names["$maj-$min"] }
        if (-not $name) { $name = $names["$maj-65535"] }
        $dtv = if ($min -eq '65535') { $maj } else { "$maj-$min" }
        $l = $live[$virt]
        # Does the guide (EPG) match what the tuner on the Overview page is actually sending?
        $gm = Get-GuideMatch $maj $min $l
        # EPG wrong: tune what the room tuner is really on, so you see what the TVs get on this channel
        $tune = "$maj-$min"; $tunesTuner = $false
        if ($gm.Mark -eq 'X' -and $l -and -not $l.NoChannel -and $l.Major -and $l.Major -ne '0') { $tune = "$($l.Major)-$($l.Minor)"; $tunesTuner = $true }
        [void]$list.Add([pscustomobject]@{
            Virt = $virt; Name = "$name"; Dtv = $dtv; Tune = $tune; TunesTuner = $tunesTuner
            Rate = $(if ($l) { $l.Rate } else { '' }); Snr = $(if ($l) { "$($l.Snr)" } else { '' })
            Skip = $false; Check = ''; Note = ''; Internal = $false; Port = 0; RawName = ''; Url = $null
            Guide = $gm.Mark; GuideWhy = $gm.Why
        })
        $inEpg[$virt] = $true
    }
    # tuners sending a channel number the guide doesn't list at all
    foreach ($v in @($live.Keys)) {
        if ($inEpg.ContainsKey($v)) { continue }
        $l = $live[$v]
        $nm = if ($l.Channel -match '^\d+\s+(\S.*)$') { $Matches[1] } else { "$($l.Channel)" }
        [void]$list.Add([pscustomobject]@{
            Virt = $v; Name = $nm; Dtv = $(if ($l.Major -and $l.Major -ne '0') { $l.Major } else { '?' }); Tune = ''
            Rate = $l.Rate; Snr = "$($l.Snr)"; Skip = $true; Check = ''; Note = ''; Internal = $false; Port = 0; RawName = ''; Url = $null
            Guide = 'X'; GuideWhy = "not in the EPG: Overview tuner $($l.Slot)-$($l.Tuner) sends $v but the EPG has no $v"
        })
    }
    $sorted = @($list | Sort-Object { $p = $_.Virt -split '-'; [int]$p[0] * 1000 + [int]$p[1] })
    $list = New-Object System.Collections.ArrayList; foreach ($c in $sorted) { [void]$list.Add($c) }
    $IgnoreChannels | Out-Null
    foreach ($c in $list) {
        if ($c.Internal) { continue }
        $fake = [pscustomobject]@{ Virt = $c.Virt; Channel = "$($c.Dtv) $($c.Name)" }
        if (Test-Ignored $fake) { $c.Skip = $true }
    }
    return ,$list
}

function Get-QamPortRates([string]$Html) {
    $rates = @{}
    foreach ($row in ($Html -split '(?i)<tr(?:\s[^>]*)?>')) {
        $cells = @([regex]::Matches($row, '(?is)<t[dh](?:\s[^>]*)?>(.*?)(?=<t[dh][\s>]|</tr|</table|$)') | ForEach-Object {
            ([System.Net.WebUtility]::HtmlDecode(([regex]::Replace($_.Groups[1].Value, '<[^>]+>', '')))).Trim() })
        if ($cells.Count -lt 7 -or $cells[0] -notmatch '^Qam\d+$') { continue }
        $base = 0; if (-not [int]::TryParse($cells[1], [ref]$base)) { continue }
        for ($k = 1; $k -le 4; $k++) {
            $v = 0.0
            if ($cells.Count -gt 2 + $k -and [double]::TryParse($cells[2 + $k], [Globalization.NumberStyles]::Float, $Inv, [ref]$v)) { $rates[$base + $k] = $v }
        }
    }
    return $rates
}
function Set-PickerQamRates($Channels, [string]$QamHtml) {
    if (-not $QamHtml) { return }
    $r = Get-QamPortRates $QamHtml
    foreach ($c in $Channels) { if ($c.Internal -and $r.ContainsKey($c.Port)) { $c.Rate = ('{0} Mbps' -f $r[$c.Port].ToString('0.0', $Inv)) } }
}

function Get-PickerTuneUrl([string]$Tuner, [string]$PcIp, [int]$Port, [string]$Tune) {
    $line = "$Tuner, ${PcIp}:$Port, $Tune-0;"
    return "http://$(Get-ComIp)/cgi-bin/webcmd?screen=TuneList&TuneList=$([uri]::EscapeDataString($line))"
}

# Retunes the spare tuner. The tuner is re-checked as "still spare" if the last check is
# over 5 minutes old, so channel changes stay quick but a reassigned tuner is never touched.
$script:PickerSafeAt = [datetime]::MinValue
function Invoke-PickerTune([string]$Tuner, [string]$PcIp, [int]$Port, [string]$Tune) {
    if (((Get-Date) - $script:PickerSafeAt).TotalMinutes -gt 5) {
        $ov = Get-PageHtml $PageUrl
        if (-not (Test-PickerTunerSafe $ov $Tuner $PcIp)) {
            $script:PickerSafeAt = [datetime]::MinValue
            throw "Tuner $Tuner is not a spare tuner right now (it may be feeding rooms). Not changing it."
        }
        $script:PickerSafeAt = Get-Date
    }
    [void](Get-PageHtml (Get-PickerTuneUrl $Tuner $PcIp $Port $Tune))
}

# Downloads a page on a background thread. Start-PickerFetch returns a job; check $job.Handle.IsCompleted,
# then Complete-PickerFetch returns the page text (or throws).
$script:PickerFetchScript = {
    param($Url, $Alts)
    # try the main card, then the others if it isn't answering
    $urls = @($Url) + @($Alts | Where-Object { $_ })
    $lastErr = $null
    foreach ($u in $urls) {
        $hp = if ($u -match '^https?://([^/]+)') { $Matches[1] } else { '' }
        $hh = $hp; $pp = 80; if ($hh -match '^(.+):(\d+)$') { $hh = $Matches[1]; $pp = [int]$Matches[2] }
        $ok = $false; try { $tc = New-Object Net.Sockets.TcpClient; $ok = $tc.ConnectAsync($hh, $pp).Wait(2000) -and $tc.Connected; $tc.Close() } catch {}
        if (-not $ok) { $lastErr = "Card $hp is not answering"; continue }
        try {
            $req = [System.Net.HttpWebRequest]::Create($u)
            $req.Timeout = 30000; $req.ReadWriteTimeout = 15000; $req.Proxy = $null
            $resp = $req.GetResponse()
            try {
                $stream = $resp.GetResponseStream(); $ms = New-Object System.IO.MemoryStream; $buf = New-Object byte[] 65536
                $deadline = (Get-Date).AddSeconds(45)
                while ((Get-Date) -lt $deadline) {
                    $n = 0
                    try { $n = $stream.Read($buf, 0, $buf.Length) } catch { if ($ms.Length -gt 0) { break } else { throw } }
                    if ($n -le 0) { break }
                    $ms.Write($buf, 0, $n)
                }
                $text = [Text.Encoding]::UTF8.GetString($ms.ToArray())
                if ($urls.Count -gt 1 -and $text -notmatch 'cardArray') { $lastErr = "Card $hp sent an incomplete page"; continue }
                return "@@HOST=$hp`n$text"
            } finally { $resp.Close() }
        } catch { $lastErr = $_.Exception.Message }
    }
    throw $lastErr
}
function Start-PickerFetch([string]$Url) {
    # Overview page from the main card: also give the other cards to fall back on
    $alts = @()
    $main = Get-ComMainIp
    if ($main -and $Url -eq $PageUrl) {
        $alts = @(@(Get-ComHosts) | Where-Object { $_ -ne $main } | ForEach-Object { Set-UrlHost $Url $_ })
    }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:PickerFetchScript).AddArgument($Url).AddArgument($alts)
    return @{ PS = $ps; Handle = $ps.BeginInvoke(); Started = Get-Date }
}
function Complete-PickerFetch($Job) {
    try {
        $out = $Job.PS.EndInvoke($Job.Handle)
        if ($Job.PS.HadErrors -and -not $out) { throw $Job.PS.Streams.Error[0].Exception }
        $text = [string]($out | Select-Object -Last 1)
        if ($text -match '^@@HOST=([^\r\n]*)\r?\n') {
            $h = $Matches[1]; $text = $text.Substring($Matches[0].Length)
            $script:ComHostNow = $(if ($h -eq (Get-ComMainIp)) { '' } else { $h })
        }
        return $text
    } finally { $Job.PS.Dispose() }
}
# Stop() waits until a stuck web request gives up (it froze the window - "Not Responding");
# BeginStop just asks it to stop and returns right away.
function Stop-PickerFetch($Job) { try { [void]$Job.PS.BeginStop($null, $null) } catch {} }

# Live bitrate/SNR for one virtual channel from a fresh Overview page
function Get-PickerLive([string]$Html, [string]$Virt) {
    foreach ($ch in (Get-ComData $Html).Channels) { if ($ch.Virt -eq $Virt) { return $ch } }
    return $null
}

# VLC options for a smoother, steadier network stream: a 2-second buffer and software decoding.
# (Deinterlacing is left to VLC's own menu: Video > Deinterlace - it can crash VLC on some video drivers.)
$PickerVlcCtl = @{ Port = 9091; Password = 'com3000' }   # VLC's remote control, reachable from this PC only
function Start-PickerVlc([string]$Vlc, [int]$Port, [string]$Source = '') {
    if (-not $Source) { $Source = "udp://@:$Port" }
    # --avcodec-hw=none: decode in software. Hardware decoding can crash VLC when the stream
    # changes format mid-way (which happens on every channel change, e.g. 720p <-> 1080i).
    # --no-qt-video-autoresize: keep the VLC window the size you made it when the channel changes
    $vlcArgs = @($Source, '--network-caching=2000', '--avcodec-hw=none', '--no-qt-video-autoresize',
                 '--extraintf=http', '--http-host=127.0.0.1', "--http-port=$($PickerVlcCtl.Port)", "--http-password=$($PickerVlcCtl.Password)")
    Start-Process $Vlc -ArgumentList $vlcArgs
}

# Switch what VLC is playing (spare-tuner stream or an internal channel's stream) without restarting it
function Set-PickerVlcSource([string]$Source) {
    $auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PickerVlcCtl.Password)"))
    foreach ($q in @('command=pl_empty', "command=in_play&input=$([uri]::EscapeDataString($Source))")) {
        $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$($PickerVlcCtl.Port)/requests/status.xml?$q")
        $req.Timeout = 3000; $req.Proxy = $null; $req.Headers['Authorization'] = $auth
        $resp = $req.GetResponse(); $resp.Close()
    }
}

function Find-Vlc {
    foreach ($p in @("$env:ProgramFiles\VideoLAN\VLC\vlc.exe", "${env:ProgramFiles(x86)}\VideoLAN\VLC\vlc.exe")) { if ($p -and (Test-Path $p)) { return $p } }
    $c = Get-Command vlc.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

# Marks and notes are kept in current-check.json (next to the picker settings) so they come back next time
$PickerCheckFile = Join-Path (Split-Path $PickerPrefsFile) 'current-check.json'
function Save-PickerCheck($Channels) {
    try {
        $keep = @($Channels | Where-Object { $_.Check -or $_.Note } | ForEach-Object { [pscustomobject]@{ Virt = $_.Virt; Tune = $_.Tune; Dtv = $_.Dtv; Name = $_.Name; Check = $_.Check; Note = $_.Note } })
        $d = Split-Path $PickerCheckFile; if (-not (Test-Path $d)) { New-Item -ItemType Directory $d -Force | Out-Null }
        if ($keep.Count) { @{ Site = $SiteName; Saved = (Get-Date).ToString('o'); Channels = $keep } | ConvertTo-Json -Depth 4 | Set-Content $PickerCheckFile -Encoding UTF8 }
        else { Remove-Item $PickerCheckFile -ErrorAction SilentlyContinue }
    } catch {}
}
function Read-PickerCheck {
    try { if (Test-Path $PickerCheckFile) { $j = Get-Content $PickerCheckFile -Raw | ConvertFrom-Json; if ($j.Site -eq $SiteName) { return $j } } } catch {}
    return $null
}
# Copies marks/notes from an earlier list onto a fresh one. A channel whose DIRECTV channel changed
# loses its mark and gets a "changed from ..." note. Returns the list of changes.
function Merge-PickerMarks($New, $Old) {
    $byVirt = @{}; foreach ($o in $Old) { $byVirt["$($o.Virt)"] = $o }
    $changed = New-Object System.Collections.ArrayList
    foreach ($c in $New) {
        $o = $byVirt[$c.Virt]
        if (-not $o) { continue }
        if ("$($o.Tune)" -eq $c.Tune) { $c.Check = "$($o.Check)"; $c.Note = "$($o.Note)" }
        elseif ($o.Check -or $o.Note -or $o.Dtv) { $c.Check = ''; $c.Note = "changed from $($o.Dtv) $($o.Name)"; [void]$changed.Add("$($c.Virt) $($o.Dtv)->$($c.Dtv)") }
    }
    return ,$changed
}

function Save-PickerReport($Channels, [string]$Tuner) {
    $now  = Get-Date
    $safe = ($SiteName -replace '[\\/:*?"<>|]', '').Trim()
    $checked  = @($Channels | Where-Object { $_.Check })
    $problems = @($Channels | Where-Object { $_.Check -eq 'Problem' })
    $lines = @(
        "$SiteName - channel check"
        "$($now.ToString('ddd MM/dd/yyyy h:mm tt'))  (spare tuner $Tuner)"
        ''
        "Checked $($checked.Count) of $(@($Channels | Where-Object { -not $_.Skip }).Count) channels - $($problems.Count) problem(s)"
        ''
    )
    if ($problems.Count) { $lines += 'PROBLEMS:'; $lines += ($problems | ForEach-Object { "  $($_.Virt)  $($_.Dtv) $($_.Name)$(if ($_.Note) { "  - $($_.Note)" })" }); $lines += '' }
    $lines += 'ALL CHANNELS:'
    $lines += ($Channels | ForEach-Object {
        $st = if ($_.Internal -and -not $_.Check) { "COM3000 channel ($($_.Rate))" } elseif ($_.Skip -and -not $_.Check) { 'skipped' } elseif ($_.Check) { $_.Check } else { 'not checked' }
        "  {0,-7} {1,-6} {2,-16} {3,-12}{4}" -f $_.Virt, $_.Dtv, $_.Name, $st, $(if ($_.Note) { " - $($_.Note)" })
    })
    $name = "$safe channel check $($now.ToString('yyyy-MM-dd HHmm')).txt"
    # saved on this PC only - not to Google Drive or the backup folders
    $dirs = @(Join-Path $ScriptDir 'Channel checks')
    $docs = [Environment]::GetFolderPath('MyDocuments'); if ($docs) { $dirs += (Join-Path $docs 'COM3000 Channel checks') }
    foreach ($dir in $dirs) {
        try {
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
            $file = Join-Path $dir $name
            Set-Content -Path $file -Value ($lines -join "`r`n") -Encoding UTF8 -ErrorAction Stop
            return @($file)
        } catch {}
    }
    return @()
}

# Closes any Channel Check and VLC windows that are already open, so clicking the icon
# never leaves doubles. Gentle first (like clicking X - an open Channel Check saves its marks),
# forced only if something hasn't closed after 5 seconds.
function Close-PickerAndVlc {
    $procs = @()
    try {
        $procs += @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop |
            Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'com3000-monitor\.ps1' -and $_.CommandLine -match '-Picker' } |
            ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
    } catch {}
    $procs += @(Get-Process vlc -ErrorAction SilentlyContinue)
    $procs = @($procs | Where-Object { $_ })
    if (-not $procs.Count) { return }
    foreach ($p in $procs) { try { [void]$p.CloseMainWindow() } catch {} }
    $until = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $until -and @($procs | Where-Object { -not $_.HasExited }).Count) { Start-Sleep -Milliseconds 200; foreach ($p in $procs) { try { $p.Refresh() } catch {} } }
    foreach ($p in @($procs | Where-Object { -not $_.HasExited })) { try { $p.Kill() } catch {} }
    Start-Sleep -Milliseconds 300
}

function Show-ChannelPicker {
    Close-PickerAndVlc
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $msg = { param($t, $icon = 'Information')
             $o = $null; if ($f) { $o = $f }
             if ($o) { [void][System.Windows.Forms.MessageBox]::Show($o, $t, 'COM3000 Channel Check', 'OK', $icon) }
             else { [void][System.Windows.Forms.MessageBox]::Show($t, 'COM3000 Channel Check', 'OK', $icon) } }

    # shared state (a hashtable, so the button handlers can change it)
    $st = @{ Prefs = @{ Tuner = ''; Port = 1234; TourSeconds = 8; Bounds = ''; OnTop = 'yes'; KnownIps = @() }; Saved = $true; Updating = $false; LoadBlades = @{}; EpgHost = ''; EpgJobs = $null; EpgOvJob = $null; EpgNext = [datetime]::MaxValue; EpgStarted = [datetime]::MinValue; Self = $PSCommandPath; FixProc = $null }
    try { if (Test-Path $PickerPrefsFile) { $j = Get-Content $PickerPrefsFile -Raw | ConvertFrom-Json
          foreach ($k in 'Tuner', 'Port', 'TourSeconds', 'Bounds', 'OnTop', 'KnownIps') { if ($j.$k) { $st.Prefs[$k] = $j.$k } } } } catch {}
    $st.PcIp = Get-PickerPcIp
    $script:PickerMyIps = @(@(Get-PickerAllIps) + @($st.Prefs.KnownIps) | Where-Object { $_ } | Select-Object -Unique)
    $st.Prefs.KnownIps = @($script:PickerMyIps | Select-Object -First 10)
    $savePrefs = { try { $d = Split-Path $PickerPrefsFile; if (-not (Test-Path $d)) { New-Item -ItemType Directory $d -Force | Out-Null }
                         $st.Prefs | ConvertTo-Json | Set-Content $PickerPrefsFile } catch {} }

    if (-not $st.PcIp) { & $msg "Couldn't find this PC's network address." 'Error'; return }
    # the line-up loads in the background once the window is open (see "loading" below)
    $st.Channels = New-Object System.Collections.ArrayList
    $st.Updating = $true
    $tuners = @()

    # ---------- window ----------
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "COM3000 Channel Check - $SiteName   (v$ScriptVersion)"
    $f.MinimumSize = New-Object System.Drawing.Size(460, 360)
    try { $ico = Join-Path $ScriptDir 'tv.ico'; if (Test-Path $ico) { $f.Icon = New-Object System.Drawing.Icon($ico) } } catch {}
    $f.TopMost = ($st.Prefs.OnTop -ne 'no')      # stays above VLC and other windows
    $f.KeyPreview = $true
    $f.StartPosition = 'Manual'
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $b = $null
    if ($st.Prefs.Bounds -match '^(-?\d+),(-?\d+),(\d+),(\d+)$') {
        $b = New-Object System.Drawing.Rectangle([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4])
        # only use the remembered spot if it's still on a screen (e.g. a monitor was unplugged)
        $onScreen = $false; foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) { if ($scr.WorkingArea.IntersectsWith($b)) { $onScreen = $true } }
        if (-not $onScreen) { $b = $null }
    }
    if (-not $b) {
        $w = 560; $h = [Math]::Min(560, $wa.Height)
        $b = New-Object System.Drawing.Rectangle(($wa.Right - $w), ($wa.Top + [int](($wa.Height - $h) / 2)), $w, $h)
    }
    $f.Bounds = $b
    $font = New-Object System.Drawing.Font('Segoe UI', 9)
    $f.Font = $font

    $top = New-Object System.Windows.Forms.FlowLayoutPanel
    $top.Dock = 'Top'; $top.AutoSize = $true; $top.AutoSizeMode = 'GrowAndShrink'; $top.Padding = (New-Object System.Windows.Forms.Padding(6,6,6,0))
    $mkLabel = { param($t) $l = New-Object System.Windows.Forms.Label; $l.Text = $t; $l.AutoSize = $true; $l.Margin = (New-Object System.Windows.Forms.Padding(3,8,3,0)); $l }
    $top.Controls.Add((& $mkLabel 'Spare tuner:'))
    $cbTuner = New-Object System.Windows.Forms.ComboBox
    $cbTuner.DropDownStyle = 'DropDownList'; $cbTuner.Width = 90
    $top.Controls.Add($cbTuner)
    $lblDest = & $mkLabel ("-> {0}:{1}" -f $st.PcIp, $st.Prefs.Port)
    $top.Controls.Add($lblDest)
    $btnVlc = New-Object System.Windows.Forms.Button; $btnVlc.Text = 'VLC'; $btnVlc.AutoSize = $true
    $top.Controls.Add($btnVlc)
    $btnRefresh = New-Object System.Windows.Forms.Button; $btnRefresh.Text = 'Refresh'; $btnRefresh.AutoSize = $true
    $top.Controls.Add($btnRefresh)
    $chkTop = New-Object System.Windows.Forms.CheckBox; $chkTop.Text = 'On top'; $chkTop.AutoSize = $true
    $chkTop.Margin = New-Object System.Windows.Forms.Padding(6, 6, 3, 0); $chkTop.Checked = $f.TopMost
    $top.Controls.Add($chkTop)
    $top.SetFlowBreak($chkTop, $true)
    $top.Controls.Add((& $mkLabel 'Go to:'))
    $txtGo = New-Object System.Windows.Forms.TextBox; $txtGo.Width = 120
    $top.Controls.Add($txtGo)
    $btnGo = New-Object System.Windows.Forms.Button; $btnGo.Text = 'Go'; $btnGo.AutoSize = $true
    $top.Controls.Add($btnGo)
    $top.Controls.Add((& $mkLabel '(50, 202 or ESPN + Enter)'))

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $false; $lv.HideSelection = $false; $lv.GridLines = $true
    $lblLoading = New-Object System.Windows.Forms.Label
    $lblLoading.Dock = 'Fill'; $lblLoading.TextAlign = 'MiddleCenter'; $lblLoading.BackColor = [System.Drawing.Color]::White
    $lblLoading.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 80)
    $lblLoading.Font = New-Object System.Drawing.Font('Segoe UI', 13)
    $lblLoading.Text = "Loading line-up from the COM3000..."
    $lv.Controls.Add($lblLoading)
    foreach ($c in @(@('Virt', 46), @('EPG', 34), @('Channel', 104), @('DIRECTV', 56), @('Bitrate', 66), @('SNR', 34), @('Check', 52), @('Notes', 140))) { [void]$lv.Columns.Add($c[0], $c[1]) }
    $lv.ShowItemToolTips = $true
    # Notes is the last column: let it use all the width that's left, so the notes aren't cut off
    $fitNotes = { try { $used = 0; for ($ci = 0; $ci -lt $lv.Columns.Count - 1; $ci++) { $used += $lv.Columns[$ci].Width }
                       $lv.Columns[$lv.Columns.Count - 1].Width = [Math]::Max(140, $lv.ClientSize.Width - $used - 4) } catch {} }
    $lv.Add_Resize({ & $fitNotes })
    $lv.Add_ColumnWidthChanged({ param($sender, $e) if ($e.ColumnIndex -lt $lv.Columns.Count - 1) { & $fitNotes } })

    $bottom = New-Object System.Windows.Forms.FlowLayoutPanel
    $bottom.Dock = 'Bottom'; $bottom.AutoSize = $true; $bottom.AutoSizeMode = 'GrowAndShrink'; $bottom.Padding = (New-Object System.Windows.Forms.Padding(6,6,6,0))
    $mkBtn = { param($t) $b = New-Object System.Windows.Forms.Button; $b.Text = $t; $b.AutoSize = $true; $bottom.Controls.Add($b); $b }
    $btnUp = & $mkBtn 'Up'; $btnDown = & $mkBtn 'Down'
    $btnGood = & $mkBtn 'Good G'; $btnGood.BackColor = [System.Drawing.Color]::FromArgb(220, 245, 220)
    $btnBad  = & $mkBtn 'Problem P'; $btnBad.BackColor = [System.Drawing.Color]::FromArgb(250, 220, 220)
    $btnNote = & $mkBtn 'Note N'
    $chkTour = New-Object System.Windows.Forms.CheckBox; $chkTour.Text = 'Tour every'; $chkTour.AutoSize = $true; $chkTour.Margin = (New-Object System.Windows.Forms.Padding(12,8,0,0))
    $bottom.Controls.Add($chkTour)
    $numSec = New-Object System.Windows.Forms.NumericUpDown; $numSec.Minimum = 3; $numSec.Maximum = 120; $numSec.Value = [int]$st.Prefs.TourSeconds; $numSec.Width = 50
    $bottom.Controls.Add($numSec); $bottom.Controls.Add((& $mkLabel 'sec'))
    $btnSave = & $mkBtn 'Save'
    $btnClear = & $mkBtn 'Clear'
    $btnFixEpg = & $mkBtn 'Fix EPG'; $btnFixEpg.Margin = (New-Object System.Windows.Forms.Padding(12,3,3,3))
    $btnFixEpg.BackColor = [System.Drawing.Color]::FromArgb(222, 234, 250)

    $status = New-Object System.Windows.Forms.StatusStrip
    $stLeft = New-Object System.Windows.Forms.ToolStripStatusLabel; $stLeft.Spring = $true; $stLeft.TextAlign = 'MiddleLeft'
    [void]$status.Items.Add($stLeft)
    $stLive = New-Object System.Windows.Forms.ToolStripStatusLabel; $stLive.TextAlign = 'MiddleRight'
    $stLive.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    [void]$status.Items.Add($stLive)

    $f.Controls.Add($lv); $f.Controls.Add($top); $f.Controls.Add($bottom); $f.Controls.Add($status)

    # ---------- helpers ----------
    $fillRow = {
        param($it, $c)
        $it.UseItemStyleForSubItems = $false
        $it.SubItems[4].Text = $c.Rate; $it.SubItems[5].Text = $c.Snr
        if ($c.Internal) { $it.SubItems[3].Text = $c.Dtv }
        $it.SubItems[6].Text = $(if ($c.Check) { $c.Check } elseif ($c.Internal -and -not $c.Url) { 'not viewable' } elseif ($c.Skip -and $c.Guide -ne 'X') { 'skip' } else { '' })
        $it.SubItems[7].Text = $(if ($c.Note) { $c.Note } elseif ($c.GuideWhy) { Get-GuideShort $c.GuideWhy } else { '' })
        $fore = if ($c.Low) { [System.Drawing.Color]::Red } elseif ($c.Skip -and -not $c.Check -and $c.Guide -ne 'X') { [System.Drawing.Color]::Gray } else { [System.Drawing.Color]::Black }
        $back = switch ($c.Check) { 'Good' { [System.Drawing.Color]::FromArgb(225, 248, 225) } 'Problem' { [System.Drawing.Color]::FromArgb(252, 222, 222) } default { [System.Drawing.Color]::White } }
        foreach ($si in $it.SubItems) { $si.ForeColor = $fore; $si.BackColor = $back }
        # Guide column: check mark when the EPG matches the Overview page, X when it doesn't
        $g = $it.SubItems[1]
        switch ($c.Guide) {
            'OK' { $g.Text = [string][char]0x2714; $g.ForeColor = [System.Drawing.Color]::FromArgb(20, 140, 60) }
            'X'  { $g.Text = [string][char]0x2716; $g.ForeColor = [System.Drawing.Color]::FromArgb(200, 30, 30); $g.BackColor = [System.Drawing.Color]::FromArgb(255, 236, 236) }
            default { $g.Text = '' }
        }
        if ($c.GuideWhy) { $it.ToolTipText = $c.GuideWhy } else { $it.ToolTipText = '' }
        $it.SubItems[7].ForeColor = if ($c.GuideWhy -and -not $c.Note) { [System.Drawing.Color]::FromArgb(200, 30, 30) } else { $fore }
    }
    $counts = {
        $all = @($st.Channels | Where-Object { -not $_.Skip }).Count
        $done = @($st.Channels | Where-Object { $_.Check }).Count
        $bad = @($st.Channels | Where-Object { $_.Check -eq 'Problem' }).Count
        "Checked $done of $all  -  $bad problem(s)"
    }
    $setStatus = { param($t, $err = $false) $stLeft.Text = "$t     |     $(& $counts)"; $stLeft.ForeColor = if ($err) { [System.Drawing.Color]::DarkRed } else { [System.Drawing.Color]::Black } }
    $select = { param([int]$i) if ($i -ge 0 -and $i -lt $lv.Items.Count) { $lv.Items[$i].Selected = $true; $lv.Items[$i].Focused = $true; $lv.EnsureVisible($i) } }
    $current = { if ($lv.SelectedIndices.Count) { $lv.SelectedIndices[0] } else { -1 } }
    $nextIndex = {
        param([int]$from, [int]$dir, [bool]$skipSkipped)
        $i = $from + $dir
        while ($i -ge 0 -and $i -lt $lv.Items.Count) { if (-not ($skipSkipped -and $st.Channels[$i].Skip)) { return $i }; $i += $dir }
        return -1
    }

    $fillList = {
        $lv.BeginUpdate(); $lv.Items.Clear()
        foreach ($c in $st.Channels) {
            $it = New-Object System.Windows.Forms.ListViewItem($c.Virt)
            foreach ($v in @('', $c.Name, $c.Dtv, '', '', '', '')) { [void]$it.SubItems.Add($v) }
            & $fillRow $it $c
            [void]$lv.Items.Add($it)
        }
        $lv.EndUpdate()
    }
    & $fillList

    # ---------- what VLC is playing: the spare tuner's stream, or an internal channel's own stream ----------
    $st.VlcSrc = ''
    $playSource = {
        param([string]$src)
        if ($st.VlcSrc -eq $src) { return }
        try { Set-PickerVlcSource $src; $st.VlcSrc = $src }
        catch {
            # VLC's remote isn't answering (e.g. VLC was opened another way) - restart VLC on the new source
            $v = Find-Vlc; if (-not $v) { return }
            foreach ($p in @(Get-Process vlc -ErrorAction SilentlyContinue)) { [void]$p.CloseMainWindow() }
            $until = (Get-Date).AddSeconds(5); while ((Get-Process vlc -ErrorAction SilentlyContinue) -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 200 }
            Start-PickerVlc $v ([int]$st.Prefs.Port) $src; $st.VlcSrc = $src
        }
    }
    $tunerSrc = { "udp://@:$($st.Prefs.Port)" }

    # ---------- tuning (waits a moment so scrolling quickly doesn't retune every row) ----------
    $tuneTimer = New-Object System.Windows.Forms.Timer; $tuneTimer.Interval = 600
    $tuneTimer.Add_Tick({
        $tuneTimer.Stop()
        $i = & $current; if ($i -lt 0) { return }
        $c = $st.Channels[$i]
        if ($c.Internal -and $c.Url) {
            & $playSource $c.Url
            & $setStatus "Now on $($c.Virt)  $($c.Name) - straight from its stream ($($c.Url))"
            return
        }
        if ($c.Internal) {
            & $setStatus "$($c.Virt) $($c.Name) is made by the COM3000 itself (QAM port $($c.Port)), so it can't be shown in VLC. Its bitrate comes from the QAM page."
            return
        }
        if (-not $c.Tune) {
            & $setStatus "$($c.Virt) $($c.Name) can't be tuned from here: $($c.GuideWhy)" $true
            return
        }
        & $playSource (& $tunerSrc)
        & $setStatus "Tuning $($c.Virt) $($c.Name)..."
        $f.Cursor = [System.Windows.Forms.Cursors]::WaitCursor; [System.Windows.Forms.Application]::DoEvents()
        try {
            Invoke-PickerTune $st.Prefs.Tuner $st.PcIp ([int]$st.Prefs.Port) $c.Tune
            $st.TunedAt = Get-Date
            $shownDtv = if ($c.TunesTuner) { ($c.Tune -split '-')[0] + ' (what the TVs get)' } else { $c.Dtv }
            & $setStatus ("Now on $($c.Virt)  $shownDtv $($c.Name)  (picture in VLC in a few seconds)" + $(if ($c.Guide -eq 'X') { "  -  EPG MISMATCH: $($c.GuideWhy)" } else { '' })) ($c.Guide -eq 'X')
        } catch { & $setStatus "Could not tune: $(Get-CleanError $_)" $true }
        $f.Cursor = [System.Windows.Forms.Cursors]::Default
    })
    $lv.Add_SelectedIndexChanged({ if ($lv.SelectedIndices.Count -and -not $st.Updating) { $tuneTimer.Stop(); $tuneTimer.Start() } })

    $mark = {
        param($what)
        $i = & $current; if ($i -lt 0) { return }
        $st.Channels[$i].Check = $what
        & $fillRow $lv.Items[$i] $st.Channels[$i]
        Save-PickerCheck $st.Channels
        if ($what -ne 'Good') { & $setStatus "$($st.Channels[$i].Virt) marked as a problem - staying on it (N = add a note)."; return }      # stay on a problem channel
        $n = & $nextIndex $i 1 $true
        if ($n -ge 0) { & $select $n } else { & $setStatus 'End of the list.' }
    }
    $note = {
        $i = & $current; if ($i -lt 0) { return }
        $c = $st.Channels[$i]
        $wasTop = $f.TopMost; $f.TopMost = $false       # let the note box come to the front
        $t = [Microsoft.VisualBasic.Interaction]::InputBox("Note for $($c.Virt) $($c.Name):", 'Add note', $c.Note)
        $f.TopMost = $wasTop
        $c.Note = $t; if (-not $c.Check -and $t) { $c.Check = 'Problem' }
        & $fillRow $lv.Items[$i] $c; Save-PickerCheck $st.Channels; & $setStatus 'Note saved.'
    }
    $goTo = {
        $q = $txtGo.Text.Trim(); if (-not $q) { return }
        $start = & $current
        $hits = @()
        for ($i = 0; $i -lt $st.Channels.Count; $i++) {
            $c = $st.Channels[$i]
            if ($c.Virt -eq $q -or $c.Virt -eq "$q-0" -or $c.Dtv -eq $q -or ($q -notmatch '^\d' -and $c.Name -like "*$q*")) { $hits += $i }
        }
        if (-not $hits) { & $setStatus "No channel matches '$q'." $true; return }
        $n = @($hits | Where-Object { $_ -gt $start }) | Select-Object -First 1      # Enter again = next match
        if ($null -eq $n) { $n = $hits[0] }
        & $select $n; $lv.Focus()
    }

    $tourTimer = New-Object System.Windows.Forms.Timer
    $tourTimer.Add_Tick({
        $n = & $nextIndex (& $current) 1 $true
        if ($n -ge 0) { & $select $n } else { $chkTour.Checked = $false; & $setStatus 'Auto tour finished - end of the list.' }
    })

    # ---------- events ----------
    $chkTop.Add_CheckedChanged({ $f.TopMost = $chkTop.Checked; $st.Prefs.OnTop = $(if ($chkTop.Checked) { 'yes' } else { 'no' }); & $savePrefs; $lv.Focus() })
    $btnUp.Add_Click({ $n = & $nextIndex (& $current) -1 $false; if ($n -ge 0) { & $select $n }; $lv.Focus() })
    $btnDown.Add_Click({ $n = & $nextIndex (& $current) 1 $false; if ($n -ge 0) { & $select $n }; $lv.Focus() })
    $btnGood.Add_Click({ & $mark 'Good'; $lv.Focus() })
    $btnBad.Add_Click({ & $mark 'Problem'; $lv.Focus() })
    $btnNote.Add_Click({ & $note; $lv.Focus() })
    $btnGo.Add_Click({ & $goTo })
    $txtGo.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; & $goTo } })
    $f.Add_KeyDown({
        if ($txtGo.Focused) { return }
        switch ($_.KeyCode) {
            'G' { & $mark 'Good'; $_.SuppressKeyPress = $true }
            'P' { & $mark 'Problem'; $_.SuppressKeyPress = $true }
            'N' { & $note; $_.SuppressKeyPress = $true }
        }
    })
    $chkTour.Add_CheckedChanged({
        if ($chkTour.Checked) { $tourTimer.Interval = [int]$numSec.Value * 1000; $tourTimer.Start(); & $setStatus "Auto tour on - every $($numSec.Value) seconds. Press P on anything bad." }
        else { $tourTimer.Stop() }
    })
    $numSec.Add_ValueChanged({ $st.Prefs.TourSeconds = [int]$numSec.Value; $tourTimer.Interval = [int]$numSec.Value * 1000; & $savePrefs })
    $cbTuner.Add_SelectedIndexChanged({
        $old = $st.Prefs.Tuner; $new = [string]$cbTuner.SelectedItem
        if ($old -and $old -ne $new -and $st.TunedAt) { try { [void](Invoke-PickerRelease $old) } catch {} }   # free the tuner we're leaving
        $st.Prefs.Tuner = $new; $script:PickerSafeAt = [datetime]::MinValue; & $savePrefs
        if ($old -and $old -ne $new -and $st.TunedAt) { $tuneTimer.Stop(); $tuneTimer.Start() }              # retune the current channel on the new tuner
        & $setStatus "Using spare tuner $($st.Prefs.Tuner)."
    })
    $btnVlc.Add_Click({
        $v = Find-Vlc
        if ($v) {
            if (Get-Process vlc -ErrorAction SilentlyContinue) {
                $a = [System.Windows.Forms.MessageBox]::Show($f, "Restart VLC with the steadier settings (2-second buffer, software decoding)?`nChoose No to open another VLC window.", 'COM3000 Channel Check', 'YesNoCancel', 'Question')
                if ($a -eq 'Cancel') { return }
                if ($a -eq 'Yes') {
                    foreach ($p in @(Get-Process vlc -ErrorAction SilentlyContinue)) { [void]$p.CloseMainWindow() }
                    $until = (Get-Date).AddSeconds(5)
                    while ((Get-Process vlc -ErrorAction SilentlyContinue) -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 200 }
                }
            }
            Start-PickerVlc $v ([int]$st.Prefs.Port) $(if ($st.VlcSrc) { $st.VlcSrc } else { & $tunerSrc })
            if (-not $st.VlcSrc) { $st.VlcSrc = & $tunerSrc }
        }
        else { & $msg "VLC isn't installed on this PC. Install it from videolan.org, or open this in any player:`n`nudp://@:$($st.Prefs.Port)" 'Warning' }
    })
    $btnRefresh.Add_Click({
        $f.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $ov  = Get-PageHtml $PageUrl
            $epgHost = if ("$EpgIp".Trim()) { "$EpgIp".Trim() } else { Get-ComIp }
            $epgNow = Get-PageHtml "http://$epgHost/cgi-bin/webcmd?screen=EpgDisplay"
            $new = Get-PickerChannels $ov $epgNow
            $bladeEpgs = @{ $epgHost = $epgNow }
            foreach ($h in @(Get-ComHosts)) { if ($h -ne $epgHost -and (Test-HostPort $h 1500)) { try { $bladeEpgs[$h] = Get-PageHtml "http://$h/cgi-bin/webcmd?screen=EpgDisplay" } catch {} } }
            try { Set-PickerBladeChecks $new $ov $bladeEpgs } catch {}
            try { Set-PickerGuideStream $new $bladeEpgs } catch {}
            try { Set-PickerQamRates $new (Get-PageHtml "http://$(Get-ComIp)/cgi-bin/webcmd?screen=Qam") } catch {}
            # keep marks/notes for channels that didn't change; flag ones whose DIRECTV channel changed
            $changed = Merge-PickerMarks $new $st.Channels
            $oldVirts = @($st.Channels | ForEach-Object { $_.Virt })
            $added = @($new | Where-Object { $oldVirts -notcontains $_.Virt }).Count
            $removed = @($st.Channels | Where-Object { $v = $_.Virt; -not ($new | Where-Object { $_.Virt -eq $v }) }).Count
            $sel = if ($lv.SelectedIndices.Count) { $st.Channels[$lv.SelectedIndices[0]].Virt } else { '' }
            $st.Updating = $true
            $st.Channels = $new
            & $fillList
            $i = 0; for ($k = 0; $k -lt $new.Count; $k++) { if ($new[$k].Virt -eq $sel) { $i = $k; break } }
            & $select $i
            & $markFixBtn
            $st.Updating = $false
            $script:PickerSafeAt = [datetime]::MinValue      # re-check the spare tuner on the next change
            $sum = "Line-up refreshed: $($new.Count) channels"
            if ($changed.Count) { $sum += "; changed: $($changed -join ', ')"; Save-PickerCheck $st.Channels }
            if ($added) { $sum += "; $added new" }
            if ($removed) { $sum += "; $removed removed" }
            & $setStatus $sum
        } catch { $st.Updating = $false; & $setStatus "Refresh failed: $(Get-CleanError $_)" $true }
        $f.Cursor = [System.Windows.Forms.Cursors]::Default
    })
    $btnClear.Add_Click({
        $a = [System.Windows.Forms.MessageBox]::Show($f, 'Clear all Good/Problem marks and notes and start a fresh check?', 'COM3000 Channel Check', 'YesNo', 'Question')
        if ($a -ne 'Yes') { return }
        for ($i = 0; $i -lt $st.Channels.Count; $i++) { $st.Channels[$i].Check = ''; $st.Channels[$i].Note = ''; & $fillRow $lv.Items[$i] $st.Channels[$i] }
        Save-PickerCheck $st.Channels
        & $setStatus 'Cleared - starting a fresh check.'; $lv.Focus()
    })
    # ---------- Fix EPG: opens the Make EPG window (it shows the changes and asks for YES before submitting) ----------
    $markFixBtn = {
        $nx = @($st.Channels | Where-Object { $_.Guide -eq 'X' }).Count
        if ($nx) { $btnFixEpg.Text = "Fix EPG ($nx wrong)"; $btnFixEpg.BackColor = [System.Drawing.Color]::FromArgb(255, 214, 160) }
        else { $btnFixEpg.Text = 'Fix EPG'; $btnFixEpg.BackColor = [System.Drawing.Color]::FromArgb(222, 234, 250) }
    }
    $btnFixEpg.Add_Click({
        if ($st.FixProc -and -not $st.FixProc.HasExited) { & $msg 'The Make EPG window is already open.'; return }
        try {
            $exe = (Get-Process -Id $PID).Path
            $st.FixProc = Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($st.Self)`"", '-MakeEpg') -PassThru -ErrorAction Stop
            $f.TopMost = $false          # don't cover the Make EPG window
            & $setStatus 'Make EPG is open in its own window - check the changes there and type YES to submit. The EPG marks here update when it closes.'
        } catch { & $msg "Couldn't open Make EPG:`n$(Get-CleanError $_)" 'Error' }
    })

    $btnSave.Add_Click({
        $p = @(Save-PickerReport $st.Channels $st.Prefs.Tuner)
        if ($p.Count) { & $msg ("Report saved on this PC:`n`n" + ($p -join "`n")) }
        else { & $msg 'The report could not be saved.' 'Error' }
    })
    # ---------- EPG recheck: every minute, re-read the Overview and every blade's EPG in the background ----------
    $epgTimer = New-Object System.Windows.Forms.Timer; $epgTimer.Interval = 1000
    $epgTimer.Add_Tick({
        if ($st.Updating -or -not $st.Channels) { return }
        if ($st.FixProc -and $st.FixProc.HasExited) {
            $st.FixProc = $null; $st.EpgNext = Get-Date
            $f.TopMost = $chkTop.Checked
            & $setStatus 'Make EPG closed - rechecking the EPG on every blade...'
        }
        if (-not $st.EpgJobs) {
            if ((Get-Date) -lt $st.EpgNext) { return }
            $st.EpgJobs = @{}; $st.EpgStarted = Get-Date
            $st.EpgOvJob = Start-PickerFetch $PageUrl
            foreach ($h in @(@(Get-ComHosts) + @($st.EpgHost) | Where-Object { $_ } | Select-Object -Unique)) { $st.EpgJobs[$h] = Start-PickerFetch "http://$h/cgi-bin/webcmd?screen=EpgDisplay" }
            return
        }
        $pending = @(@($st.EpgJobs.Values) + @($st.EpgOvJob) | Where-Object { -not $_.Handle.IsCompleted }).Count
        if ($pending -and ((Get-Date) - $st.EpgStarted).TotalSeconds -lt 20) { return }
        $map = @{}; $ov = ''
        foreach ($h in @($st.EpgJobs.Keys)) { $j = $st.EpgJobs[$h]; if ($j.Handle.IsCompleted) { try { $map[$h] = Complete-PickerFetch $j } catch {} } else { Stop-PickerFetch $j } }
        if ($st.EpgOvJob.Handle.IsCompleted) { try { $ov = Complete-PickerFetch $st.EpgOvJob } catch {} } else { Stop-PickerFetch $st.EpgOvJob }
        $st.EpgJobs = $null; $st.EpgOvJob = $null; $st.EpgNext = (Get-Date).AddSeconds(60)
        if ($ov -notmatch 'cardArray' -or -not $map.Count -or $st.Updating) { return }
        try {
            $was = @($st.Channels | ForEach-Object { "$($_.Guide)|$($_.GuideWhy)|$($_.Url)" })
            Set-PickerBladeChecks $st.Channels $ov $map
            try { Set-PickerGuideStream $st.Channels $map } catch {}
            $lv.BeginUpdate()
            try { for ($k = 0; $k -lt $st.Channels.Count -and $k -lt $lv.Items.Count; $k++) { if ("$($st.Channels[$k].Guide)|$($st.Channels[$k].GuideWhy)|$($st.Channels[$k].Url)" -ne $was[$k]) { & $fillRow $lv.Items[$k] $st.Channels[$k] } } }
            finally { $lv.EndUpdate() }
            & $markFixBtn
        } catch {}
    })

    # ---------- live bitrate/SNR for the channel on screen (fetched in the background) ----------
    $st.Live = $null; $st.LiveNext = Get-Date
    $liveTimer = New-Object System.Windows.Forms.Timer; $liveTimer.Interval = 1000
    $liveTimer.Add_Tick({
        $i = & $current
        if ($st.Live) {
            if ($st.Live.Handle.IsCompleted) {
                $job = $st.Live; $st.Live = $null; $st.LiveNext = (Get-Date).AddSeconds(4)
                try {
                    $html = Complete-PickerFetch $job
                    if ($i -ge 0 -and -not $st.Updating -and $st.Channels[$i].Internal) {
                        $c = $st.Channels[$i]
                        $r = Get-QamPortRates $html
                        if ($r.ContainsKey($c.Port)) {
                            $c.Rate = ('{0} Mbps' -f $r[$c.Port].ToString('0.0', $Inv)); & $fillRow $lv.Items[$i] $c
                            $stLive.Text = "LIVE $($c.Virt) $($c.Name): $($c.Rate) (QAM page)  ($((Get-Date).ToString('h:mm:ss tt')))"
                            $stLive.ForeColor = if ($r[$c.Port] -lt $MinMbps) { [System.Drawing.Color]::Red } else { [System.Drawing.Color]::DarkGreen }
                        } else { $stLive.Text = "LIVE $($c.Virt): not on the QAM page"; $stLive.ForeColor = [System.Drawing.Color]::DarkOrange }
                    }
                    elseif ($i -ge 0 -and -not $st.Updating) {
                        $c = $st.Channels[$i]
                        # is the SPARE tuner actually receiving? (no satellite signal = nothing for VLC to show)
                        if ($st.TunedAt -and ((Get-Date) - $st.TunedAt).TotalSeconds -ge 15) {
                            $sr = Get-PickerTunerRow $html $st.Prefs.Tuner
                            if ($sr -and $sr.Ip -ne '0.0.0.0' -and $sr.Mbps -le 0) {
                                $stLeft.Text = "Spare tuner $($st.Prefs.Tuner) has NO satellite signal (0 Mbps, SNR $($sr.Snr)) - nothing to show in VLC. Pick another spare tuner from the list."
                                $stLeft.ForeColor = [System.Drawing.Color]::DarkRed
                            }
                        }
                        # refresh EVERY satellite channel's bitrate/SNR from this same page read
                        $byVirt = @{}; foreach ($x in (Get-ComData $html).Channels) { if (-not $byVirt.ContainsKey($x.Virt)) { $byVirt[$x.Virt] = $x } }
                        $lv.BeginUpdate()
                        try {
                            for ($k = 0; $k -lt $st.Channels.Count; $k++) {
                                $o = $st.Channels[$k]
                                if ($o.Internal -or $o.ComMade) { continue }
                                $x = $byVirt[$o.Virt]
                                $nr = if ($x) { $x.Rate } else { 'gone' }; $ns = if ($x) { "$($x.Snr)" } else { '' }
                                $nl = (-not $x) -or ($x.Mbps -lt $MinMbps)
                                if ($o.Rate -ne $nr -or $o.Snr -ne $ns -or [bool]$o.Low -ne $nl) {
                                    $o.Rate = $nr; $o.Snr = $ns; $o | Add-Member -NotePropertyName Low -NotePropertyValue $nl -Force
                                    & $fillRow $lv.Items[$k] $o
                                }
                            }
                        } finally { $lv.EndUpdate() }
                        $l = $byVirt[$c.Virt]
                        if ($l) {
                            $c.Rate = $l.Rate; $c.Snr = "$($l.Snr)"; & $fillRow $lv.Items[$i] $c
                            $stLive.Text = "LIVE $($c.Virt) $($c.Name): $($l.Rate), SNR $($l.Snr)  ($((Get-Date).ToString('h:mm:ss tt')))"
                            $stLive.ForeColor = if ($l.Mbps -lt $MinMbps) { [System.Drawing.Color]::Red } else { [System.Drawing.Color]::DarkGreen }
                        } else {
                            $stLive.Text = "LIVE $($c.Virt): not on the Overview page"; $stLive.ForeColor = [System.Drawing.Color]::DarkOrange
                        }
                    }
                } catch {
                    $stLive.Text = "LIVE: can't reach COM3000"; $stLive.ForeColor = [System.Drawing.Color]::Red
                }
            } elseif (((Get-Date) - $st.Live.Started).TotalSeconds -gt 60) {
                Stop-PickerFetch $st.Live; $st.Live = $null; $st.LiveNext = Get-Date
            }
        } elseif ($i -ge 0 -and -not $st.Updating -and (Get-Date) -ge $st.LiveNext) {
            $st.Live = if ($st.Channels[$i].Internal) { Start-PickerFetch "http://$(Get-ComIp)/cgi-bin/webcmd?screen=Qam" } else { Start-PickerFetch $PageUrl }
        }
    })
    # show "updating..." the moment you move to another channel
    $lv.Add_SelectedIndexChanged({ if ($lv.SelectedIndices.Count) { $c = $st.Channels[$lv.SelectedIndices[0]]; $stLive.Text = "LIVE $($c.Virt) $($c.Name): updating..."; $stLive.ForeColor = [System.Drawing.Color]::Gray; $st.LiveNext = Get-Date } })

    $f.Add_FormClosing({
        $tourTimer.Stop(); $tuneTimer.Stop(); $liveTimer.Stop(); $loadTimer.Stop(); $epgTimer.Stop(); foreach ($j in @(@($st.EpgJobs.Values) + @($st.EpgOvJob))) { if ($j) { try { Stop-PickerFetch $j } catch {} } }
        if ($st.Live) { Stop-PickerFetch $st.Live; $st.Live = $null }
        foreach ($j in @($st.LoadOv, $st.LoadEpg, $st.LoadQam)) { if ($j -and -not $j.Handle.IsCompleted) { Stop-PickerFetch $j } }
        $rb = if ($f.WindowState -eq 'Normal') { $f.Bounds } else { $f.RestoreBounds }
        $st.Prefs.Bounds = "$($rb.X),$($rb.Y),$($rb.Width),$($rb.Height)"; & $savePrefs
        if (-not $st.Updating -and $st.Channels.Count -gt 0) { Save-PickerCheck $st.Channels }   # never wipe saved marks if the line-up didn't load
        # putting the spare tuner back to idle talks to the COM3000 (can take a while) - done AFTER the window is gone
        $st.NeedRelease = [bool]($st.TunedAt -and $st.Prefs.Tuner)
    })
    # ---------- loading: both COM3000 pages at once, in the background ----------
    $loadTimer = New-Object System.Windows.Forms.Timer; $loadTimer.Interval = 200
    $loadTimer.Add_Tick({
        $secs = [int]((Get-Date) - $st.LoadOv.Started).TotalSeconds
        $bladesPending = @($st.LoadBlades.Values | Where-Object { -not $_.Handle.IsCompleted }).Count
        if (-not ($st.LoadOv.Handle.IsCompleted -and $st.LoadEpg.Handle.IsCompleted) -or ($bladesPending -and $secs -lt 15)) {
            $stLeft.Text = "Loading line-up from the COM3000... $secs s"
            $lblLoading.Text = "Loading line-up from the COM3000...`n`n$secs s"
            if ($secs -gt 90) { $loadTimer.Stop(); Stop-PickerFetch $st.LoadOv; Stop-PickerFetch $st.LoadEpg
                & $msg "The COM3000 didn't answer within 90 seconds." 'Error'; $f.Close() }
            return
        }
        $loadTimer.Stop()
        try {
            $ov  = Complete-PickerFetch $st.LoadOv
            $epg = Complete-PickerFetch $st.LoadEpg
            $st.Channels = Get-PickerChannels $ov $epg
            $bladeEpgs = @{ $st.EpgHost = $epg }
            foreach ($h in @($st.LoadBlades.Keys)) {
                $j = $st.LoadBlades[$h]
                if ($j.Handle.IsCompleted) { try { $bladeEpgs[$h] = Complete-PickerFetch $j } catch {} } else { Stop-PickerFetch $j }
            }
            try { Set-PickerBladeChecks $st.Channels $ov $bladeEpgs } catch {}
            try { Set-PickerGuideStream $st.Channels $bladeEpgs } catch {}
            $tuners = @(Get-PickerTuners $ov $st.PcIp)
            # bitrate for the COM3000's own channels (guide etc.) - only if the QAM page is already in
            if ($st.LoadQam.Handle.IsCompleted) { try { Set-PickerQamRates $st.Channels (Complete-PickerFetch $st.LoadQam) } catch {} }
            else { Stop-PickerFetch $st.LoadQam }
        } catch { $lblLoading.Text = "Couldn't read the COM3000."; & $msg "Couldn't read the COM3000:`n$(Get-CleanError $_)" 'Error'; $f.Close(); return }
        # pick up the marks and notes from last time
        $st.Resumed = ''
        $prev = Read-PickerCheck
        if ($prev -and $prev.Channels) {
            $ch = Merge-PickerMarks $st.Channels @($prev.Channels)
            $n = @($st.Channels | Where-Object { $_.Check }).Count
            $when = try { ([datetime]::Parse($prev.Saved, $Inv, [Globalization.DateTimeStyles]::RoundtripKind)).ToString('MM/dd h:mm tt') } catch { 'last time' }
            $st.Resumed = "Picked up your check from $when ($n marked$(if ($ch.Count) { "; changed since: $($ch -join ', ')" }))."
            if ($ch.Count) { Save-PickerCheck $st.Channels }
        }
        if ($tuners.Count -eq 0) {
            & $msg "There is no spare tuner on this COM3000 (a tuner set to IP with address 0.0.0.0).`nThe channel check needs one unused tuner." 'Warning'
            $f.Close(); return
        }
        if ($tuners -notcontains $st.Prefs.Tuner) {
            # prefer a tuner that's already ours, otherwise the first idle one
            $ours = @($tuners | Where-Object { $r = Get-PickerTunerRow $ov $_; $r -and $r.Ip -ne '0.0.0.0' })
            $st.Prefs.Tuner = if ($ours) { $ours[0] } else { $tuners[0] }
        }
        $extra = @($tuners | Where-Object { $_ -ne $st.Prefs.Tuner } | Where-Object { $r = Get-PickerTunerRow $ov $_; $r -and $r.Ip -ne '0.0.0.0' })
        if ($extra.Count) {
            $lblLoading.Text = "Freeing $($extra.Count) old spare tuner(s)..."; [System.Windows.Forms.Application]::DoEvents()
            foreach ($t in $extra) { try { [void](Invoke-PickerRelease $t $ov) } catch {} }
        }
        foreach ($t in $tuners) { [void]$cbTuner.Items.Add($t) }
        $cbTuner.SelectedItem = $st.Prefs.Tuner
        & $fillList
        $lblLoading.Visible = $false
        $st.Updating = $false
        & $setStatus $(if ($st.Resumed) { $st.Resumed } else { "Spare tuner $($st.Prefs.Tuner) sends to $($st.PcIp):$($st.Prefs.Port). Pick a channel to start." })
        # start on the first DIRECTV channel (not the guide or a streamer - switching away from those is slow)
        $first = -1; for ($k = 0; $k -lt $st.Channels.Count; $k++) { if (-not $st.Channels[$k].Skip -and -not $st.Channels[$k].Internal) { $first = $k; break } }
        if ($first -lt 0) { $first = & $nextIndex -1 1 $true }
        if ($first -ge 0) { & $select $first }
        $liveTimer.Start()
        & $markFixBtn
        $st.EpgNext = (Get-Date).AddSeconds(60); $epgTimer.Start()
        $lv.Focus()
    })

    $f.Add_Shown({
        & $fitNotes
        $stLeft.Text = 'Loading line-up from the COM3000...'
        $epgHost = if ("$EpgIp".Trim()) { "$EpgIp".Trim() } else { Get-ComIp }
        $st.LoadOv  = Start-PickerFetch $PageUrl
        $st.LoadQam = Start-PickerFetch "http://$(Get-ComIp)/cgi-bin/webcmd?screen=Qam"
        $st.LoadEpg = Start-PickerFetch "http://$epgHost/cgi-bin/webcmd?screen=EpgDisplay"
        # the EPG copies on the other blades, to say which blade is wrong
        $st.LoadBlades = @{}
        foreach ($h in @(@(Get-ComHosts) + @($epgHost) | Select-Object -Unique)) { if ($h -ne $epgHost) { $st.LoadBlades[$h] = Start-PickerFetch "http://$h/cgi-bin/webcmd?screen=EpgDisplay" } }
        $st.EpgHost = $epgHost
        $loadTimer.Start()
        # start VLC now so it's ready by the time the list appears
        if (-not (Get-Process vlc -ErrorAction SilentlyContinue)) { $v = Find-Vlc; if ($v) { Start-PickerVlc $v ([int]$st.Prefs.Port); $st.VlcSrc = & $tunerSrc } }
    })

    & $savePrefs
    [void]$f.ShowDialog()
    try { $f.Dispose() } catch {}
    if ($st.NeedRelease) { try { [void](Invoke-PickerRelease $st.Prefs.Tuner) } catch {} }      # window already closed - nobody waits on this
}

# ---------------- Channel check window (the "Channel Check" button) ----------------
# (exit straight away afterwards, so background downloads still running can't hold the program open)
if ($Picker) { Show-ChannelPicker; [Environment]::Exit(0) }


# Password for the backend switch is encrypted with Windows DPAPI, machine scope: only programs on
# THIS PC can decrypt it (the background monitor runs as SYSTEM, so user-only encryption wouldn't do).
function Invoke-SwitchRequest([string]$Url, [string]$User, [string]$Pass, $PostBody = $null) {   # $PostBody untyped on purpose: $null = GET (look only)
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Timeout = 15000; $req.Proxy = $null; $req.PreAuthenticate = $true
    $req.Credentials = New-Object System.Net.NetworkCredential($User, $Pass)
    if ($null -ne $PostBody) {
        $req.Method = 'POST'; $req.ContentType = 'application/x-www-form-urlencoded'
        $bytes = [Text.Encoding]::ASCII.GetBytes($PostBody); $req.ContentLength = $bytes.Length
        $rs = $req.GetRequestStream(); $rs.Write($bytes, 0, $bytes.Length); $rs.Close()
    }
    try { $resp = $req.GetResponse(); $code = [int]$resp.StatusCode; $resp.Close(); return $code }
    catch [System.Net.WebException] {
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode; if ($code -eq 401) { throw 'The username or password for the COM3000 backend was not accepted.' } }
        throw
    }
}
# Checks the login without restarting anything (opens the Restart page's status, like viewing it)
function Test-SystemResetLogin([string]$HostIp, [string]$User, [string]$Pass) {
    [void](Invoke-SwitchRequest "http://$HostIp/config/wreset" $User $Pass)
}
# Same as Maintenance > Restart Device > Yes  (POST /config/misc, warm restart)
function Invoke-SystemReset {
    if (-not "$SystemResetHost".Trim()) { throw 'The whole COM3000 reset is not set up (run the installer).' }
    [void](Invoke-SwitchRequest "http://$SystemResetHost/config/misc" $SystemResetUser (Unprotect-ResetPassword $SystemResetSecret) 'warm=')
}
# Quiet the alerts while everything restarts
# ---- Reset history (for the dashboard's resets-per-month) ----
$ResetHistoryFile = Join-Path $ScriptDir 'reset-history.csv'
# Kind: 'card' or 'whole'; How: 'auto' or 'hand'
function Add-ResetHistory([string]$Kind, [string]$Slot, [string]$How) {
    try {
        Initialize-ResetHistory
        Add-Content -Path $ResetHistoryFile -Value ('{0},{1},{2},{3}' -f (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'), $Kind, ($Slot -replace ',', ' '), $How) -Encoding ASCII
    } catch {}
}
# First time: fill the history from the resets already in the monitor log
function Initialize-ResetHistory {
    if (Test-Path $ResetHistoryFile) { return }
    $lines = New-Object System.Collections.ArrayList; [void]$lines.Add('time,kind,slot,how')
    foreach ($f in @("$LogFile.old", $LogFile)) {
        if (-not (Test-Path $f)) { continue }
        foreach ($l in (Get-Content $f)) {
            if ($l -notmatch '^(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d)  (.*)$') { continue }
            $t = "$($Matches[1])T$($Matches[2])"; $x = $Matches[3]
            if ($x -like 'Reset history cleared*') { $lines.Clear(); [void]$lines.Add('time,kind,slot,how'); continue }
            if ($x -match '^Card reset sent by hand: slot (\S+)') { [void]$lines.Add("$t,card,$($Matches[1]),hand") }
            elseif ($x -match '^Card reset sent: slot (\S+)') { [void]$lines.Add("$t,card,$($Matches[1]),auto") }
            elseif ($x -match '^Whole COM3000 reset sent by hand') { [void]$lines.Add("$t,whole,,hand") }
            elseif ($x -match '^Whole COM3000 reset sent: card slot ([^ ]+)') { [void]$lines.Add("$t,whole,$($Matches[1] -replace ',', ' '),auto") }
            elseif ($x -match '^Whole COM3000 reset sent: COM3000 page') { [void]$lines.Add("$t,whole,page,auto") }
        }
    }
    try { Set-Content -Path $ResetHistoryFile -Value $lines -Encoding ASCII } catch {}
}
# resets per month for the last 12 months, plus the 5 most recent
function Get-ResetSummary {
    $months = [ordered]@{}; $recent = @(); $bySlot = @{}; $bySlotMonth = [ordered]@{}
    $all = [ordered]@{ since = ''; card = 0; whole = 0; slots = [ordered]@{} }      # every reset ever recorded on this PC
    Initialize-ResetHistory
    try {
        if (Test-Path $ResetHistoryFile) {
            $cut = (Get-Date).AddMonths(-11).ToString('yyyy-MM')
            $every = @(Import-Csv $ResetHistoryFile | Where-Object { $_.time -and $_.time.Length -ge 7 })
            if ($every.Count) { $all.since = $every[0].time.Substring(0, 7) }
            foreach ($r in $every) {
                if ($r.kind -eq 'whole') { $all.whole++ }
                else { $all.card++; $all.slots["$($r.slot)"] = [int]$all.slots["$($r.slot)"] + 1 }
            }
            $rows = @($every | Where-Object { $_.time.Substring(0, 7) -ge $cut })
            foreach ($r in $rows) {
                $m = $r.time.Substring(0, 7)
                if (-not $months.Contains($m)) { $months[$m] = [ordered]@{ ca = 0; ch = 0; wa = 0; wh = 0 } }
                $k = $(if ($r.kind -eq 'whole') { 'w' } else { 'c' }) + $(if ($r.how -eq 'auto') { 'a' } else { 'h' })
                $months[$m][$k]++
            }
            $recent = @($rows | Select-Object -Last 5 | ForEach-Object { [ordered]@{ t = $_.time; k = $_.kind; s = $_.slot; h = $_.how } })
            # card resets per slot this month
            $thisM = (Get-Date).ToString('yyyy-MM')
            foreach ($r in @($rows | Where-Object { $_.kind -eq 'card' -and $_.time.Substring(0, 7) -eq $thisM })) { $bySlot["$($r.slot)"] = [int]$bySlot["$($r.slot)"] + 1 }
            # card resets per slot per month (last 6 months), for the dashboard's per-location tables
            $cut6 = (Get-Date).AddMonths(-5).ToString('yyyy-MM')
            foreach ($r in @($rows | Where-Object { $_.kind -eq 'card' -and $_.time.Substring(0, 7) -ge $cut6 })) {
                $m = $r.time.Substring(0, 7)
                if (-not $bySlotMonth.Contains($m)) { $bySlotMonth[$m] = [ordered]@{} }
                $bySlotMonth[$m]["$($r.slot)"] = [int]$bySlotMonth[$m]["$($r.slot)"] + 1
            }
        }
    } catch {}
    return @{ Months = $months; Recent = $recent; BySlot = $bySlot; BySlotMonth = $bySlotMonth; All = $all }
}

# ---- Status reports for the COM3000 Dashboard ----
function Get-StatusTopic { return "$NtfyTopic-status" }
function Send-StatusReport($State, [hashtable]$Info) {
    if ("$StatusReports" -eq 'off' -or $Test -or $ReadOnly) { return }
    $now = Get-Date
    # send every 15 minutes, or straight away when something changed
    # (the bitrate in "- low bitrate (0.3 Mbps)" changes every minute - leave it out, or it would report every minute)
    $sig = "$($Info.Page)|$($Info.Paused)|" + (($Info.Cards | ForEach-Object { "$($_.s):$($_.up):$($_.out)" }) -join ',') + '|' + ((@($Info.Out) | ForEach-Object { "$_" -replace ' - low bitrate \(.*\)$', '' }) -join ',') + "|$($State.epgBad)"
    $last = [datetime]::MinValue; [void][datetime]::TryParse("$($State.statusAt)", $Inv, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$last)
    if ($sig -eq $State.statusSig -and ($now - $last).TotalMinutes -lt 14.5) { return }
    $sum = Get-ResetSummary
    $out = @($Info.Out)
    # this location's last alerts (7 days), so the dashboard has them even after ntfy's 12 hours
    $recentAlerts = @()
    try {
        $hf = Join-Path $ScriptDir 'alert-history.jsonl'
        if (Test-Path $hf) {
            $lines = @(Get-Content $hf -Encoding UTF8)
            if ($lines.Count -gt 500) { Set-Content -Path $hf -Value ($lines | Select-Object -Last 300) -Encoding UTF8; $lines = @($lines | Select-Object -Last 300) }
            $cut = $now.AddDays(-7)
            $recentAlerts = @($lines | Select-Object -Last 40 | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } | Where-Object {
                $tt = [datetime]::MinValue; [datetime]::TryParse("$($_.t)", $Inv, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$tt) -and $tt -ge $cut } | Select-Object -Last 8)
        }
    } catch {}
    $rep = [ordered]@{
        v = 1; site = $SiteName; pc = $env:COMPUTERNAME; t = $now.ToString('o'); every = $IntervalMinutes
        page = $Info.Page; via = $Info.Via; paused = $Info.Paused; err = $Info.Err
        cards = @($Info.Cards); outN = $out.Count; lowN = [int]$Info.Low; out = @($out | Select-Object -First 25)
        watched = $Info.Watched; backup = $State.lastBackup; ver = $ScriptVersion
        epgBad = [int]$State.epgBad; epgBadList = "$($State.epgBadList)"
        epgRef = $(if ("$EpgRefreshTime" -match '^\d\d:\d\d$' -and $State.epgRefAt) { [ordered]@{ at = $State.epgRefAt; ok = ($State.epgRefOk -eq 'ok') } } else { $null })
        resets = $sum.Months; recent = $sum.Recent; slotResets = $sum.BySlot; slotMonths = $sum.BySlotMonth; allRes = $sum.All
        alerts = $recentAlerts
    }
    $json = $rep | ConvertTo-Json -Depth 6 -Compress
    if ($json.Length -gt 3800) { $rep.alerts = @($recentAlerts | Select-Object -Last 4); $json = $rep | ConvertTo-Json -Depth 6 -Compress }
    if ($json.Length -gt 3800) { $rep.out = @($out | Select-Object -First 5); $rep.recent = @(); $rep.alerts = @($recentAlerts | Select-Object -Last 2); $json = $rep | ConvertTo-Json -Depth 6 -Compress }
    try {
        Send-Ntfy "$NtfyServer/$(Get-StatusTopic)" ([Text.Encoding]::UTF8.GetBytes($json)) @{ Title = "status $SiteName"; Priority = 'min'; Tags = 'bar_chart' }
        $State.statusSig = $sig; $State.statusAt = $now.ToString('o')
    } catch { Write-Log "Could not send the dashboard status report: $(Get-CleanError $_)" }
    # while we're at it: has another site stopped reporting?
    Set-Step "reading the other sites' reports"
    try { Test-QuietSites $State } catch {}
}
# Every site reads the other sites' reports. If one has been silent 60+ minutes, the first
# site (A-Z) that is still reporting sends one alert - so you hear about a dead PC/internet.
function Test-QuietSites($State) {
    # only the last 2 hours: enough to see who went quiet (60 min), and a much smaller download than 12 hours
    $raw = Get-PageHtml "$NtfyServer/$(Get-StatusTopic)/json?poll=1&since=2h"
    $lastBy = @{}; $offSite = @{}
    foreach ($line in ("$raw" -split "`n")) {
        if (-not $line.Trim()) { continue }
        try { $m = $line | ConvertFrom-Json; if ($m.event -ne 'message') { continue }; $r = $m.message | ConvertFrom-Json } catch { continue }
        if (-not $r.site -or "$($r.kind)" -eq 'alert') { continue }
        # when ntfy received it (so a site PC with a wrong clock isn't taken for a silent one)
        $tt = [DateTimeOffset]::FromUnixTimeSeconds([int64]$m.time).UtcDateTime
        if (-not $lastBy.ContainsKey($r.site) -or $tt -gt $lastBy[$r.site]) { $lastBy[$r.site] = $tt; $offSite[$r.site] = ("$($r.page)" -eq 'off') }
    }
    # a site whose monitor was turned off on purpose (Alerts OFF) isn't "stopped reporting"
    foreach ($site in @($offSite.Keys)) { if ($offSite[$site]) { $lastBy.Remove($site); $State.quiet.Remove($site) } }
    # compare against ntfy's clock too: this PC's clock may be off as well
    $now = [datetime]::UtcNow
    try { if ($lastBy.ContainsKey($SiteName) -and $State.statusAt) {
        $mine = [datetime]::MinValue; [void][datetime]::TryParse("$($State.statusAt)", $Inv, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$mine)
        $now = $now + ($lastBy[$SiteName] - $mine.ToUniversalTime())    # shift by how far this PC's clock is off
    } } catch {}
    $alive = @($lastBy.Keys | Where-Object { ($now - $lastBy[$_]).TotalMinutes -lt 30 } | Sort-Object)
    $iAmSender = ($alive.Count -gt 0 -and $alive[0] -eq $SiteName)
    foreach ($site in @($lastBy.Keys)) {
        if ($site -eq $SiteName) { continue }
        $mins = ($now - $lastBy[$site]).TotalMinutes
        if ($mins -ge 60) {
            if ($iAmSender -and -not $State.quiet.ContainsKey($site)) {
                Send-Alert "$site - stopped reporting" "$site has not sent a status report since $($lastBy[$site].ToLocalTime().ToString('h:mm tt')). Its PC may be off, frozen or offline, so it can't send alerts. (Noticed by $SiteName.)" 'high' 'electric_plug' -NoSite
                $State.quiet[$site] = $lastBy[$site].ToString('o')
            }
        } elseif ($State.quiet.ContainsKey($site)) {
            # the site that sent "stopped reporting" also sends "reporting again"
            Send-Alert "$site - reporting again" "$site is sending status reports again." 'default' 'white_check_mark' -NoSite
            $State.quiet.Remove($site)
        }
    }
}

function Set-ResetPause([int]$Minutes = 10) {
    try { Set-Content -Path $PauseFile -Value (Get-Date).AddMinutes($Minutes).ToString('o') } catch {}
}

# ---------------- Reset panel: one button per card + whole COM3000 (the "COM3000 Reset" button) ----------------
# Background check of every card's address (so the window never freezes while a dead card times out)
$script:ResetPingScript = {
    param([string[]]$Ips)
    $out = @{}
    foreach ($ip in $Ips) {
        $up = $false
        $tcp = New-Object System.Net.Sockets.TcpClient
        try { $t = $tcp.ConnectAsync($ip, 80); if ($t.Wait(2000) -and $tcp.Connected) { $up = $true } } catch {} finally { $tcp.Dispose() }
        if (-not $up) { try { if ((New-Object System.Net.NetworkInformation.Ping).Send($ip, 1500).Status -eq 'Success') { $up = $true } } catch {} }
        $out[$ip] = $up
    }
    $out
}
function Start-ResetPing([string[]]$Ips) {
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:ResetPingScript).AddArgument($Ips)
    return @{ PS = $ps; Handle = $ps.BeginInvoke(); Started = Get-Date }
}

function Get-CardResetUrl([string]$Ip, [string]$Slot) {
    $u = if ("$CardResetCommand".Trim()) { $CardResetCommand } else { 'http://{com}/cgi-bin/webcmd?screen=resetIp&resetIp={ip}' }
    return ($u -replace '\{ip\}', $Ip -replace '\{slot\}', $Slot -replace '\{com\}', (Get-ComIp))
}

function Show-ResetPanel {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $known = @{}                                         # cards the monitor has seen at this site (so a missing one still shows)
    try { $ms = Load-State; foreach ($k in $ms.devices.Keys) { if ($ms.devices[$k] -match '^Card slot (\S+)$') { $known[$Matches[1]] = $k } } } catch {}
    $st = @{ Data = $null; Up = @{}; Resetting = @{}; Fetch = $null; Ping = $null; Next = Get-Date; Updated = $null; SysReset = $null }

    $f = New-Object System.Windows.Forms.Form
    $f.Text = "COM3000 Reset - $SiteName"
    $f.Size = New-Object System.Drawing.Size(560, 470); $f.MinimumSize = New-Object System.Drawing.Size(400, 300)
    $f.StartPosition = 'CenterScreen'; $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    try { $ico = Join-Path $ScriptDir 'com3000-power.ico'; if (-not (Test-Path $ico)) { $ico = Join-Path $ScriptDir 'reset-card.ico' }; if (Test-Path $ico) { $f.Icon = New-Object System.Drawing.Icon($ico) } } catch {}

    $hdr = New-Object System.Windows.Forms.Label; $hdr.Dock = 'Top'; $hdr.Height = 34; $hdr.Padding = New-Object System.Windows.Forms.Padding(10, 10, 10, 0)
    $hdr.Text = "Click a card to reset it. You'll be asked to confirm first."
    $grid = New-Object System.Windows.Forms.FlowLayoutPanel; $grid.Dock = 'Fill'; $grid.AutoScroll = $true; $grid.Padding = New-Object System.Windows.Forms.Padding(8)
    $loading = New-Object System.Windows.Forms.Label; $loading.Text = 'Reading the COM3000...'; $loading.AutoSize = $true; $loading.Margin = New-Object System.Windows.Forms.Padding(12)
    $loading.Font = New-Object System.Drawing.Font('Segoe UI', 12); $grid.Controls.Add($loading)

    $bottom = New-Object System.Windows.Forms.Panel; $bottom.Dock = 'Bottom'; $bottom.Height = 84
    $btnSys = New-Object System.Windows.Forms.Button; $btnSys.Text = 'Reset whole COM3000'
    $btnSys.Size = New-Object System.Drawing.Size(220, 40); $btnSys.Location = New-Object System.Drawing.Point(12, 6)
    $btnSys.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $btnSys.BackColor = [System.Drawing.Color]::FromArgb(250, 215, 215)
    $sysNote = New-Object System.Windows.Forms.Label; $sysNote.AutoSize = $true; $sysNote.Location = New-Object System.Drawing.Point(242, 18)
    if (-not "$SystemResetHost".Trim()) { $btnSys.Enabled = $false; $sysNote.Text = '(not set up - run the installer, question 14)' }
    else { $sysNote.Text = 'Restarts every card - all channels go off for a few minutes.' }
    $lblUpd = New-Object System.Windows.Forms.Label; $lblUpd.AutoSize = $true; $lblUpd.Location = New-Object System.Drawing.Point(12, 56); $lblUpd.ForeColor = [System.Drawing.Color]::Gray
    $bottom.Controls.AddRange(@($btnSys, $sysNote, $lblUpd))
    $f.Controls.Add($grid); $f.Controls.Add($hdr); $f.Controls.Add($bottom)

    $tiles = @{}
    $msg = { param($t, $icon = 'Information') [void][System.Windows.Forms.MessageBox]::Show($f, $t, 'COM3000 Reset', 'OK', $icon) }

    # what each card looks like right now
    $cardInfo = {
        param($sl)
        $d = $st.Data
        $slot = if ($d) { @($d.Slots | Where-Object { "$($_.Slot)" -eq "$sl" }) | Select-Object -First 1 } else { $null }
        $ip = if ($slot) { $slot.Ip } else { $known[$sl] }
        $ch = if ($d) { @($d.Channels | Where-Object { "$($_.Slot)" -eq "$sl" -and -not $_.NoChannel }) } else { @() }
        $out = @($ch | Where-Object { $_.Mbps -lt $MinMbps }).Count
        $up = if ($st.Up.ContainsKey($ip)) { $st.Up[$ip] } else { $true }
        [pscustomobject]@{ Slot = $sl; Ip = $ip; OnPage = [bool]$slot; Up = $up; Total = $ch.Count; Out = $out }
    }

    $paint = {
        param($sl)
        $b = $tiles[$sl]; $i = & $cardInfo $sl
        $green = [System.Drawing.Color]::FromArgb(205, 238, 205); $amber = [System.Drawing.Color]::FromArgb(255, 232, 180)
        $red = [System.Drawing.Color]::FromArgb(250, 200, 200); $grey = [System.Drawing.Color]::FromArgb(215, 215, 215); $blue = [System.Drawing.Color]::FromArgb(200, 222, 250)
        if ($st.Resetting.ContainsKey($sl)) {
            $secs = [int]((Get-Date) - $st.Resetting[$sl]).TotalSeconds
            $line = if (-not $i.Up -or -not $i.OnPage) { "restarting... $secs s" } elseif (-not $i.Total) { "starting up... $secs s" } else { "$($i.Total - $i.Out) of $($i.Total) back - $secs s" }
            $b.Text = "Slot $sl`n$($i.Ip)`nRESETTING`n$line"; $b.BackColor = $blue
        } elseif (-not $i.Up) { $b.Text = "Slot $sl`n$($i.Ip)`nNOT ANSWERING"; $b.BackColor = $grey }
        elseif (-not $i.OnPage) { $b.Text = "Slot $sl`n$($i.Ip)`nMISSING FROM`nTHE COM3000"; $b.BackColor = $grey }
        elseif ($i.Total -and $i.Out -eq $i.Total) { $b.Text = "Slot $sl`n$($i.Ip)`nNO VIDEO`n($($i.Total) channels out)"; $b.BackColor = $red }
        elseif ($i.Out) { $b.Text = "Slot $sl`n$($i.Ip)`n$($i.Out) of $($i.Total) out"; $b.BackColor = $amber }
        else { $b.Text = "Slot $sl`n$($i.Ip)`n$($i.Total) of $($i.Total) OK"; $b.BackColor = $green }
    }

    $resetCard = {
        param($sl)
        $i = & $cardInfo $sl
        if (-not $i.Ip) { return }
        if ($st.Resetting.ContainsKey($sl)) { & $msg "Slot $sl is already resetting."; return }
        $hint = if (-not $i.Up -or -not $i.OnPage) { "`n`nThis card isn't answering. A whole COM3000 reset is usually what brings back a missing card." } else { '' }
        $a = [System.Windows.Forms.MessageBox]::Show($f, "Reset card slot $sl ($($i.Ip))?`n`nIts $($i.Total) channels will go off the TVs for a few minutes.$hint", 'COM3000 Reset', 'YesNo', 'Warning', 'Button2')
        if ($a -ne 'Yes') { return }
        try { [void](Get-PageHtml (Get-CardResetUrl $i.Ip $sl)) } catch { & $msg "Could not send the reset:`n$(Get-CleanError $_)" 'Error'; return }
        $st.Resetting[$sl] = Get-Date; $st.Next = Get-Date
        Write-Log "Card reset sent by hand: slot $sl ($($i.Ip))"; Add-ResetHistory 'card' $sl 'hand'
        Send-Alert 'card reset (by hand)' "Card slot $sl ($($i.Ip)) was reset from $env:COMPUTERNAME. Its channels will be off for a few minutes." 'default' 'arrows_counterclockwise'
        & $paint $sl
    }

    $btnSys.Add_Click({
        $a = [System.Windows.Forms.MessageBox]::Show($f, "Reset the WHOLE COM3000?`n`nEvery card restarts and ALL channels go off the TVs for several minutes.", 'COM3000 Reset', 'YesNo', 'Warning', 'Button2')
        if ($a -ne 'Yes') { return }
        try { Invoke-SystemReset } catch { & $msg "Could not send the reset:`n$(Get-CleanError $_)" 'Error'; return }
        Set-ResetPause 10
        $st.SysReset = Get-Date
        foreach ($k in @($tiles.Keys)) { $st.Resetting[$k] = Get-Date }
        Write-Log 'Whole COM3000 reset sent by hand'; Add-ResetHistory 'whole' '' 'hand'
        Send-Alert 'COM3000 reset (by hand)' "The whole COM3000 was reset from $env:COMPUTERNAME. All channels will be off for several minutes. Alerts are paused 10 minutes while it restarts." 'high' 'arrows_counterclockwise'
    })

    # refresh loop: read the Overview page and check every card, both in the background
    $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 1000
    $timer.Add_Tick({
        # finished background jobs
        if ($st.Fetch -and $st.Fetch.Handle.IsCompleted) {
            $j = $st.Fetch; $st.Fetch = $null
            try { $st.Data = Get-ComData (Complete-PickerFetch $j); $st.Updated = Get-Date; $lblUpd.ForeColor = [System.Drawing.Color]::Gray }
            catch { $lblUpd.Text = "Can't read the COM3000 right now: $(Get-CleanError $_)"; $lblUpd.ForeColor = [System.Drawing.Color]::DarkRed }
        }
        if ($st.Ping -and $st.Ping.Handle.IsCompleted) {
            $j = $st.Ping; $st.Ping = $null
            try { $r = $j.PS.EndInvoke($j.Handle) | Select-Object -Last 1; foreach ($k in $r.Keys) { $st.Up[$k] = $r[$k] } } catch {}
            try { $j.PS.Dispose() } catch {}
        }
        # build the buttons once we know the cards
        if ($st.Data -and $loading.Parent) {
            $grid.Controls.Remove($loading)
            $slots = @(@($st.Data.Slots | ForEach-Object { "$($_.Slot)" }) + @($known.Keys) | Sort-Object { [int]$_ } -Unique)
            foreach ($sl in $slots) {
                $b = New-Object System.Windows.Forms.Button
                $b.Size = New-Object System.Drawing.Size(160, 100); $b.Margin = New-Object System.Windows.Forms.Padding(6)
                $b.Font = New-Object System.Drawing.Font('Segoe UI', 10); $b.FlatStyle = 'Flat'; $b.Tag = $sl
                $b.Add_Click({ & $resetCard $this.Tag })
                $tiles[$sl] = $b; [void]$grid.Controls.Add($b)
            }
        }
        # follow cards that are resetting
        foreach ($sl in @($st.Resetting.Keys)) {
            if (-not $tiles.ContainsKey($sl)) { continue }
            $i = & $cardInfo $sl; $secs = ((Get-Date) - $st.Resetting[$sl]).TotalSeconds
            if (-not $i.Up -or -not $i.OnPage) { $st["down$sl"] = $true }
            $back = $i.Up -and $i.OnPage -and $i.Total -and $i.Out -eq 0 -and ($st["down$sl"] -or $secs -ge 60) -and $st.Updated -gt $st.Resetting[$sl]
            if ($back) {
                $st.Resetting.Remove($sl); $st.Remove("down$sl")
                Write-Log "Card slot $sl ($($i.Ip)) back after reset ($([int]$secs) s)"
                Send-Alert 'card back after reset' "Card slot $sl ($($i.Ip)) is back after the reset - all $($i.Total) channels have video ($([int]$secs) s)." 'default' 'white_check_mark'
            } elseif ($secs -ge 300) {
                $st.Resetting.Remove($sl); $st.Remove("down$sl")
                Write-Log "Card slot $sl ($($i.Ip)) not back 5 minutes after reset"
                Send-Alert 'card not back after reset' "Card slot $sl ($($i.Ip)) is not fully back 5 minutes after the reset. The monitor keeps watching it." 'high' 'warning'
            }
        }
        foreach ($sl in @($tiles.Keys)) { & $paint $sl }
        if ($st.Updated) { $lblUpd.Text = "Updated $($st.Updated.ToString('h:mm:ss tt'))" }
        # start the next round
        if (-not $st.Fetch -and -not $st.Ping -and (Get-Date) -ge $st.Next) {
            $st.Fetch = Start-PickerFetch $PageUrl
            $ips = @(@($st.Data.Slots | ForEach-Object { $_.Ip }) + @($known.Values) | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -ne '0.0.0.0' } | Sort-Object -Unique)
            if ($ips) { $st.Ping = Start-ResetPing $ips }
            $st.Next = (Get-Date).AddSeconds($(if ($st.Resetting.Count) { 5 } else { 10 }))
        }
    })
    $f.Add_Shown({ $timer.Start() })
    $f.Add_FormClosing({ $timer.Stop(); foreach ($j in @($st.Fetch, $st.Ping)) { if ($j) { Stop-PickerFetch $j } } })
    [void]$f.ShowDialog()
}

if ($ResetCard) { Show-ResetPanel; return }

# ---------------- Send a test notification (the Send Test Alert button) ----------------
if ($SendTest) {
    $when = Get-Date -Format 'h:mm tt'
    Write-Host "Sending a test alert to topic '$NtfyTopic'..." -ForegroundColor Cyan
    try {
        $body = [Text.Encoding]::UTF8.GetBytes("Test from $env:COMPUTERNAME at $when. If you see this, COM3000 alerts reach this phone.")
        Send-Ntfy "$NtfyServer/$NtfyTopic" $body @{ Title = "$SiteName - test alert"; Priority = 'urgent'; Tags = 'bell' }
        Write-Host "Sent at $when. Every phone subscribed to '$NtfyTopic' should get it within a few seconds." -ForegroundColor Green
        Write-Host "If a phone doesn't: check its ntfy subscription and notification settings."
    } catch {
        Write-Host "Could NOT send: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Check that this PC has internet access.' -ForegroundColor Red
    }
    return
}

# ---------------------------------------------------------------------------
# Old PingInfoView watchdog cleanup (asked for during install). Only touches things whose name or
# command mentions PingInfoView / "Ping Info View" / Watchdog.ps1 - never the COM3000 monitor's own tasks.
# ---------------------------------------------------------------------------
$PingPattern = 'PingInfoView|Ping Info View|Watchdog\.ps1'
function Find-PingInfoView {
    $found = [ordered]@{ Processes = @(); Tasks = @(); RunKeys = @(); Shortcuts = @(); Folders = @() }
    try {
        $found.Processes = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $_.ProcessId -ne $PID -and ($_.Name -match '^PingInfoView' -or "$($_.CommandLine)" -match $PingPattern) })
    } catch {
        # Windows Management (WMI) not answering: find it the plain way
        $found.Processes = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and ($_.ProcessName -match '^PingInfoView' -or "$($_.Path)" -match $PingPattern) } |
            ForEach-Object { [pscustomobject]@{ ProcessId = $_.Id; Name = "$($_.ProcessName).exe"; ExecutablePath = "$($_.Path)" } })
    }
    try {
        $found.Tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
            $_.TaskName -notlike 'COM3000*' -and (("$($_.TaskName) " + (($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ')) -match $PingPattern) })
    } catch {
        # WMI not answering: ask schtasks.exe instead
        try {
            $rows = @(& schtasks.exe /Query /FO CSV /V 2>$null | ConvertFrom-Csv | Where-Object { $_.TaskName -and $_.TaskName -ne 'TaskName' })
            $found.Tasks = @($rows | Where-Object { $_.TaskName -notmatch '\\(COM3000|Microsoft\\)' -and ("$($_.TaskName) $($_.'Task To Run')" -match $PingPattern) } |
                Select-Object -Property TaskName -Unique | ForEach-Object { [pscustomobject]@{ TaskName = $_.TaskName; TaskPath = ''; Schtasks = $true } })
        } catch {}
    }
    foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
        try {
            $props = Get-ItemProperty -Path $key -ErrorAction Stop
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -notlike 'PS*' -and ("$($p.Name) $($p.Value)" -match $PingPattern)) { $found.RunKeys += [pscustomobject]@{ Key = $key; Name = $p.Name } }
            }
        } catch {}
    }
    try {
        $sh = New-Object -ComObject WScript.Shell
        foreach ($dir in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))) {
            if (-not $dir -or -not (Test-Path $dir)) { continue }
            foreach ($l in (Get-ChildItem $dir -Filter *.lnk -ErrorAction SilentlyContinue)) {
                $t = ''; try { $lk = $sh.CreateShortcut($l.FullName); $t = "$($lk.TargetPath) $($lk.Arguments)" } catch {}
                if ("$($l.Name) $t" -match $PingPattern) { $found.Shortcuts += $l.FullName }
            }
        }
    } catch {}
    $dirs = @('C:\Ping Info View')
    foreach ($pr in $found.Processes) { if ($pr.ExecutablePath -and $pr.Name -match '^PingInfoView') { $dirs += (Split-Path $pr.ExecutablePath) } }
    $found.Folders = @($dirs | Where-Object { $_ -and (Test-Path -LiteralPath $_) -and $_ -notmatch '^[A-Za-z]:\\?$' -and $_ -notmatch '\\Windows' } | Sort-Object -Unique)
    return $found
}
function Remove-PingInfoView($Found) {
    $done = @()
    foreach ($t in $Found.Tasks) {
        if ($t.Schtasks) { & schtasks.exe /Delete /TN $t.TaskName /F 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { $done += "scheduled task '$($t.TaskName)'" }; continue }
        try { Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop; $done += "scheduled task '$($t.TaskName)'" } catch {}
    }
    foreach ($r in $Found.RunKeys) { try { Remove-ItemProperty -Path $r.Key -Name $r.Name -ErrorAction Stop; $done += "start-at-login entry '$($r.Name)'" } catch {} }
    foreach ($l in $Found.Shortcuts) { try { Remove-Item -LiteralPath $l -Force -ErrorAction Stop; $done += "Startup shortcut '$(Split-Path $l -Leaf)'" } catch {} }
    foreach ($pr in $Found.Processes) { try { Stop-Process -Id $pr.ProcessId -Force -ErrorAction Stop; $done += "running $($pr.Name) (process $($pr.ProcessId))" } catch {} }
    # anything still running from those folders (it locks the .exe so the folder can't be deleted)
    foreach ($d in $Found.Folders) {
        Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and "$($_.Path)" -like "$d\*" } |
            ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop; $done += "running $($_.ProcessName)" } catch {} }
    }
    Start-Sleep -Milliseconds 800
    foreach ($d in $Found.Folders) {
        try { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop; $done += "folder $d" }
        catch { Write-Host "   Couldn't delete $d : $(Get-CleanError $_)" -ForegroundColor Yellow }
    }
    return $done
}

# ---------------- Setup (the Install button) ----------------
if ($Setup) {
    $psExe = (Get-Process -Id $PID).Path
    function Ask([string]$Q, [string]$Default) {
        $a = Read-Host $(if ("$Default" -ne '') { "$Q [$Default]" } else { $Q })
        if (-not "$a".Trim()) { return "$Default" }
        return "$a".Trim()
    }
    function Ask-Number([string]$Q, [int]$Default, [int]$Min, [int]$Max) {
        while ($true) {
            $a = Ask $Q "$Default"; $n = 0
            if ([int]::TryParse($a, [ref]$n) -and $n -ge $Min -and $n -le $Max) { return $n }
            Write-Host "   Please enter a whole number from $Min to $Max." -ForegroundColor Yellow
        }
    }

    Write-Host '=== COM3000 Monitor setup ===' -ForegroundColor Cyan

    # old PingInfoView watchdog on this PC?
    $piv = Find-PingInfoView
    $pivCount = $piv.Processes.Count + $piv.Tasks.Count + $piv.RunKeys.Count + $piv.Shortcuts.Count + $piv.Folders.Count
    if ($pivCount) {
        Write-Host "`nFound the old PingInfoView / Watchdog on this PC:" -ForegroundColor Yellow
        foreach ($x in $piv.Processes) { Write-Host "   running: $($x.Name) $(if ($x.CommandLine -match 'Watchdog') { '(Watchdog script)' })" }
        foreach ($x in $piv.Tasks)     { Write-Host "   scheduled task: $($x.TaskName)" }
        foreach ($x in $piv.RunKeys)   { Write-Host "   starts at login: $($x.Name)" }
        foreach ($x in $piv.Shortcuts) { Write-Host "   Startup shortcut: $(Split-Path $x -Leaf)" }
        foreach ($x in $piv.Folders)   { Write-Host "   folder: $x" }
        $ans = Read-Host 'Remove it? (Y/n)'
        if ("$ans".Trim() -notmatch '^(n|no)$') {
            $gone = Remove-PingInfoView $piv
            if ($gone) { Write-Host 'Removed:' -ForegroundColor Green; foreach ($g in $gone) { Write-Host "   $g" } }
            Write-Log "PingInfoView cleanup during setup: $($gone -join '; ')"
        } else { Write-Host 'Left in place.' }
    }

    Write-Host "`nPress Enter to keep the value shown in [brackets].`n"

    # 1. location name
    $placeholder = $SiteName -eq 'Location Name Here'
    do {
        $name = Ask '1. Location name (shown at the start of every alert)' $(if ($placeholder) { '' } else { $SiteName })
        $name = ($name -replace "[^A-Za-z0-9 ._#&()'-]", '').Trim()
        if (-not $name) { Write-Host '   A location name is needed, e.g. Hampton Inn Tulsa.' -ForegroundColor Yellow }
    } until ($name)

    # 2. COM3000 address
    $curIp = if ($PageUrl -match '^https?://([^/:]+)') { $Matches[1] } else { '192.168.3.18' }
    do {
        $ip = Ask '2. COM3000 IP address (the one you open in Chrome)' $curIp
        if ($ip -match '(\d{1,3}(\.\d{1,3}){3})') { $ip = $Matches[1] }   # a pasted web address is fine too
        $ok = $ip -match '^\d{1,3}(\.\d{1,3}){3}$'
        if (-not $ok) { Write-Host '   That does not look like an IP address (example: 192.168.3.18).' -ForegroundColor Yellow }
    } until ($ok)

    # 3. phone alert topic
    Write-Host "`n   Phone alerts use the free ntfy app. Use the SAME topic at every site to get all"
    Write-Host '   alerts in one feed (each alert starts with the location name).'
    do {
        $topic = Ask '3. ntfy topic' $NtfyTopic
        $ok = $topic -match '^[A-Za-z0-9_-]{1,64}$'
        if (-not $ok) { Write-Host '   Letters, numbers, - and _ only, no spaces.' -ForegroundColor Yellow }
    } until ($ok)

    # 4-6. timers
    Write-Host ''
    $interval = Ask-Number '4. Check every how many minutes?' $IntervalMinutes 1 60
    $delayDef = [Math]::Max($MinutesBeforeAlert, $interval)
    $delay    = Ask-Number '5. Alert after something has been down for how many minutes? (a reboot/card reset shorter than this stays quiet)' $delayDef $interval 240
    $remind   = Ask-Number '6. While something stays down, remind me every how many minutes? (0 = no reminders)' $ReminderMinutes 0 1440

    # 7. channel changes
    do {
        $cc = (Ask '7. When a channel assignment changes: phone, log, or off?' $ChannelChanges).ToLower()
        $ok = $cc -in @('phone', 'log', 'off')
        if (-not $ok) { Write-Host '   Type phone, log or off.' -ForegroundColor Yellow }
    } until ($ok)

    # channels to skip are asked AFTER the test scan (question 11); keep the current list until then
    $ignList = @($IgnoreChannels | Where-Object { "$_".Trim() })
    $streams = @{}; foreach ($k in @($InternalStreams.Keys)) { $streams[$k] = $InternalStreams[$k] }

    # 8-10. daily backup
    Write-Host "`n   Daily backup of the TuneAll 'Current Tuning Table' and the EPG list (one file, replaced each day)."
    $tries = 0
    $btShow = if ($BackupTime -eq 'off') { 'off' } else { ([datetime]::ParseExact($BackupTime, 'HH:mm', $Inv)).ToString('h:mm tt', $Inv) }
    do {
        $a = Ask '8. Backup time each day (e.g. 3:00 AM), or off' $btShow
        $ok = $true
        if ($a -match '^\s*off\s*$') { $bkTime = 'off' }
        else {
            $t = [datetime]::MinValue
            [string[]]$fmts = @('h:mm tt', 'h:mmtt', 'h tt', 'htt', 'H:mm', 'HH:mm', 'h:mm t', 'ht')
            if ([datetime]::TryParseExact(($a.ToUpper() -replace '\.', ''), $fmts, $Inv, [Globalization.DateTimeStyles]::AllowWhiteSpaces, [ref]$t)) { $bkTime = $t.ToString('HH:mm') }
            else { $ok = $false; Write-Host '   Please enter a time like 3:00 AM or 15:30, or off.' -ForegroundColor Yellow }
        }
        if (-not $ok -and ++$tries -ge 5) { $bkTime = $BackupTime; $ok = $true; Write-Host "   Keeping $btShow." -ForegroundColor Yellow }
    } until ($ok)
    $epgIpAns = ''; $drive = $DriveFolder
    if ($bkTime -ne 'off') {
        do {
            $e = Ask '9. EPG page IP address (Enter = same as the COM3000)' $(if ($EpgIp) { $EpgIp } else { $ip })
            if ($e -match '(\d{1,3}(\.\d{1,3}){3})') { $e = $Matches[1] }     # a pasted web address is fine too
            $ok = $e -match '^\d{1,3}(\.\d{1,3}){3}$'
            if (-not $ok) { Write-Host '   That does not look like an IP address.' -ForegroundColor Yellow }
        } until ($ok)
        $epgIpAns = if ($e -eq $ip) { '' } else { $e }
        $drive = Ask "10. Google Drive folder (auto = My Drive\COM3000 Backups\$name)" $(if ($DriveFolder) { $DriveFolder } else { 'auto' })
        if ($drive -ne 'auto' -and $drive -notmatch '^[A-Za-z]:\\') { Write-Host '   Not a full folder path - using auto.' -ForegroundColor Yellow; $drive = 'auto' }
    }

    # save the answers to com3000-settings.ps1 (kept when the script is updated)
    $q = { param($v) "'" + ($v -replace "'", "''") + "'" }
    $rbTime = $null; $erTime = $null; $erBlades = $null
    $writeSettings = { Set-Content -Path $SettingsFile -Encoding UTF8 -Value (@(
        '# COM3000 monitor settings for this site.'
        '# Written by "Install COM3000 Monitor" - run it again to change these, or edit here and save.'
        '# Keep the quotes and the = signs. Text after # is just a note. Changes apply on the next check'
        '# (except IntervalMinutes: after changing that, turn the monitor OFF and ON with the desktop icons).'
        '# Replacing com3000-monitor.ps1 with a newer version keeps this file.'
        ''
        "`$SiteName           = $(& $q $name)        # name at the start of every alert"
        "`$PageUrl            = $(& $q "http://$ip/cgi-bin/webcmd?screen=Overview")        # COM3000 Overview page"
        "`$NtfyTopic          = $(& $q $topic)        # ntfy topic the phones subscribe to"
        "`$IntervalMinutes    = $interval        # check every this many minutes"
        "`$MinutesBeforeAlert = $delay        # something must be down this long before an alert"
        "`$MinChannelsOut     = $(if ($MinChannelsOut -ge 1) { [int]$MinChannelsOut } else { 3 })        # fewer channels than this out at once: no phone alert ..."
        "`$FewChannelsMinutes = $(if ($null -ne $FewChannelsMinutes) { [int]$FewChannelsMinutes } else { 180 })        # ... unless one stays out this many minutes (0 = never)"
        "`$RainFadeHours      = $(if ($null -ne $RainFadeHours) { [int]$RainFadeHours } else { 3 })        # rain fade (3+ cards dropping): no alerts unless it lasts this many hours (0 = never)"
        "`$ReminderMinutes    = $remind        # 'still down' reminder every this many minutes (0 = off)"
        "`$ChannelReminders   = $(& $q $(if ("$ChannelReminders" -eq 'on') { 'on' } else { 'off' }))        # 'off' = channels get just an out + back alert, no 'still down' reminders"
        "`$ChannelChanges     = $(& $q $cc)        # channel changes: 'phone', 'log' or 'off'"
        "`$IgnoreChannels     = @($((@($ignList) | ForEach-Object { & $q $_ }) -join ', '))        # channels not watched, e.g. @('133-0', 'MCEL')"
        "`$BackupTime         = $(& $q $bkTime)        # daily backup time, 24-hour HH:mm (e.g. '03:00'), or 'off'"
        "`$EpgIp              = $(& $q $epgIpAns)        # EPG page address if not on the COM3000 ('' = same)"
        "`$DriveFolder        = $(& $q $drive)        # Google Drive folder for backups ('auto' = My Drive\COM3000 Backups\<site>)"
        "`$CardResetMinutes   = $(if ($null -ne $crm) { $crm } else { $CardResetMinutes })        # reset a card after this many minutes with no video (0 = off)"
        "`$SystemResetHost    = $(& $q $(if ($null -ne $srHost) { $srHost } else { $SystemResetHost }))        # COM3000 backend (WebStaX switch) for the whole-COM3000 reset ('' = off)"
        "`$SystemResetUser    = $(& $q $(if ($null -ne $srUser) { $srUser } else { $SystemResetUser }))        # backend username"
        "`$SystemResetSecret  = $(& $q $(if ($null -ne $srSecret) { $srSecret } else { $SystemResetSecret }))        # backend password, encrypted for this PC - change it with the installer"
        "`$SystemResetMinutes = $(if ($null -ne $srm) { $srm } else { $SystemResetMinutes })        # reset the whole COM3000 after a card is missing this many minutes (0 = off)"
        "`$InternalStreams    = @{ $((@($streams.Keys | Sort-Object) | ForEach-Object { "$(& $q $_) = $(& $q $streams[$_])" }) -join '; ') }        # internal channel name = address VLC plays"
        "`$StatusReports      = $(& $q $(if ("$StatusReports" -eq 'off') { 'off' } else { 'on' }))        # send status reports for the COM3000 Dashboard: 'on' or 'off'"
        "`$RebootTime         = $(& $q $(if ($rbTime) { $rbTime } else { $RebootTime }))        # restart this PC every day at this time, 24-hour HH:mm (e.g. '04:30'), or 'off'"
        "`$ExtraTabs          = $(& $q $(if ($null -ne $xtAns) { $xtAns } else { $ExtraTabs }))        # other pages the 'COM3000 Blades' icon opens, e.g. a streamer '192.168.3.200' (comma-separated)"
        "`$Wallpaper          = $(& $q $(if ($wpAns) { $wpAns } else { $Wallpaper }))        # 'blue' or 'gray' = plain desktop background with the location name, or 'off'"
        "`$NetRepair          = $(& $q $(if ("$NetRepair" -eq 'off') { 'off' } else { 'on' }))        # 'on' = when the internet drops, restart the network connection / renew / restart the PC to get it back"
        "`$EpgRefreshTime     = $(& $q $(if ($erTime) { $erTime } else { $EpgRefreshTime }))        # re-submit the EPG page(s) every morning at this time (24-hour HH:mm), or 'off'"
        "`$EpgRefreshBlades   = $(& $q $(if ($null -ne $erBlades) { $erBlades } else { $EpgRefreshBlades }))        # blades for the EPG refresh, e.g. '192.168.3.18' - blank = every blade that has an EPG"
    ) -join "`r`n") }
    & $writeSettings

    # New location or different COM3000? Clear the memory copied from another site
    # (otherwise the first check reports that site's channels as "changed").
    $oldIp = $curIp
    if ($placeholder -or $name -ne $SiteName -or $ip -ne $oldIp) {
        foreach ($f in @($StateFile, $LogFile, "$LogFile.old", $PauseFile, $ResetHistoryFile, (Join-Path $ScriptDir 'alert-history.jsonl'))) { Remove-Item $f -ErrorAction SilentlyContinue }
        Write-Host "`nNew location: cleared the monitor's memory, log and reset history from any previous site." -ForegroundColor Yellow
    }

    Write-Host "`nSaved settings:" -ForegroundColor Green
    Write-Host "   Location:        $name"
    Write-Host "   COM3000:         $ip"
    Write-Host "   ntfy topic:      $topic"
    Write-Host "   Check every:     $interval min"
    Write-Host "   Alert after:     $delay min down"
    Write-Host "   Reminders:       $(if ($remind -gt 0) { "every $remind min" } else { 'off' })"
    Write-Host "   Channel changes: $cc"
    if ($bkTime -eq 'off') { Write-Host '   Backups:         off' }
    else {
        Write-Host "   Backups:         daily at $(([datetime]::ParseExact($bkTime, 'HH:mm', $Inv)).ToString('h:mm tt', $Inv)), one file replaced each day"
        Write-Host "   EPG page:        $(if ($epgIpAns) { $epgIpAns } else { "$ip (same as COM3000)" })"
        Write-Host "   Google Drive:    $(if ($drive -eq 'auto') { "My Drive\COM3000 Backups\$name" } else { $drive })"
    }

    Write-Host "`nRunning a test..." -ForegroundColor Cyan
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Test

    # 11. channels to skip - asked now that you've seen every channel
    $low = @()
    try {
        $scan = Get-ComData (Get-PageHtml "http://$ip/cgi-bin/webcmd?screen=Overview")
        $low  = @($scan.Channels | Where-Object { -not $_.NoChannel -and $_.Mbps -lt $MinMbps })
    } catch { Write-Host "   (Couldn't re-read the channel list: $(Get-CleanError $_))" -ForegroundColor Yellow }
    Write-Host "`n--- Channels to skip ---" -ForegroundColor Cyan
    if ($low.Count -gt 0) {
        Write-Host "These channels are under $MinMbps Mbps right now (music channels normally are):"
        foreach ($c in $low) { Write-Host ("   {0,-7} {1,-18} {2}" -f $c.Virt, $c.Channel, $c.Rate) -ForegroundColor Yellow }
        Write-Host "Type  low  to skip all of them, list channels (e.g. 133-0, 134-0 or MCEL), or combine (low, 22-0)."
    } else {
        Write-Host 'No channels are low right now. You can still list channels to skip (e.g. 133-0, 134-0 or MCEL).'
    }
    Write-Host 'Type  none  to watch every channel. Enter keeps the list in brackets.'
    $curIgnore = ($ignList -join ', ')
    $ign = Ask '11. Channels to skip' $(if ($curIgnore) { $curIgnore } else { 'none' })
    $newList = New-Object System.Collections.ArrayList
    if ($ign -notmatch '^\s*none\s*$') {
        foreach ($tok in ($ign -split ',')) {
            $tok = $tok.Trim()
            if ($tok -ieq 'low') { foreach ($c in $low) { if (-not $newList.Contains($c.Virt)) { [void]$newList.Add($c.Virt) } }; continue }
            $tok = $tok -replace "[^A-Za-z0-9 .*_&+!-]", ''
            if ($tok -and -not $newList.Contains($tok)) { [void]$newList.Add($tok) }
        }
    }
    $ignList = @($newList)

    # 12. internal channels (made by the COM3000 from an outside stream, e.g. an HDMI encoder)
    try {
        $epgHostQ = if ($epgIpAns) { $epgIpAns } else { $ip }
        $em = [regex]::Match((Get-PageHtml "http://$epgHostQ/cgi-bin/webcmd?screen=EpgDisplay"), "(?is)<textarea[^>]*name=['""]?EpgList['""]?[^>]*>(.*?)</textarea>")
        $internals = @()
        if ($em.Success) {
            foreach ($line in (Get-HtmlText $em.Groups[1].Value)) {
                $n = [regex]::Match($line.Trim(), '^(\d+-\d+)\s+N(\S+)\s')
                if ($n.Success -and $n.Groups[2].Value -notmatch 'Electronic_Program_Guide|^EPG') { $internals += [pscustomobject]@{ Virt = $n.Groups[1].Value; Raw = $n.Groups[2].Value } }
            }
        }
        if ($internals.Count) {
            Write-Host "`n--- Internal channels ---" -ForegroundColor Cyan
            Write-Host 'These are made by the COM3000 from another source (like an HDMI encoder). To watch one in'
            Write-Host 'Channel Check, enter the stream address you would open in VLC (e.g. 239.100.2.226:769).'
            Write-Host 'Enter keeps what is in brackets; type none to make it not viewable.'
            foreach ($ic in $internals) {
                $cur = $null; foreach ($k in @($streams.Keys)) { if ($k -ieq $ic.Raw) { $cur = $streams[$k] } }
                $a = Ask "12. Stream for $($ic.Virt) $($ic.Raw -replace '_', ' ')" $(if ($cur) { $cur } else { 'none' })
                foreach ($k in @($streams.Keys)) { if ($k -ieq $ic.Raw) { $streams.Remove($k) } }
                if ($a -match '^\s*none\s*$') { continue }
                if ($a -match '^\d{1,3}(\.\d{1,3}){3}:\d+$') { $a = "udp://@$a" }
                elseif ($a -notmatch '^(udp|rtp|http|https|rtsp)://') { Write-Host '   Not a stream address - leaving it not viewable.' -ForegroundColor Yellow; continue }
                $streams[$ic.Raw] = $a
            }
        }
    } catch { Write-Host "   (Couldn't read the EPG list for internal channels: $(Get-CleanError $_))" -ForegroundColor Yellow }

    # 13. automatic card reset
    Write-Host "`n--- Automatic card reset ---" -ForegroundColor Cyan
    Write-Host 'When a card is still there but ALL its channels have no bitrate, the monitor can reset that card'
    Write-Host '(at most once per card per day) and tell you if it came back.'
    Write-Host '(It uses the same Reset as the button on a tuner''s CardEdit page. It never resets for a storm, or for a card that is gone.)'
    $crm = Ask-Number '13. Reset a card after how many minutes with no video? (0 = off)' $CardResetMinutes 0 240

    # 14-15. whole COM3000 reset (backend switch: Maintenance > Restart Device)
    Write-Host "`n--- Whole COM3000 reset ---" -ForegroundColor Cyan
    Write-Host 'When a card goes MISSING, the monitor can restart the whole COM3000 through its backend'
    Write-Host '(the WebStaX switch - Maintenance > Restart Device), at most once per day.'
    $srHost = $SystemResetHost; $srUser = $SystemResetUser; $srSecret = $SystemResetSecret; $srm = $SystemResetMinutes
    do {
        $a = Ask '14. COM3000 backend address (type none to turn this off)' $(if ($srHost) { $srHost } else { '192.168.10.2' })
        if ($a -match '(\d{1,3}(\.\d{1,3}){3}(:\d+)?)') { $a = $Matches[1] }      # a pasted web address is fine too
        $ok = ($a -match '^\s*none\s*$') -or ($a -match '^\d{1,3}(\.\d{1,3}){3}(:\d+)?$')
        if (-not $ok) { Write-Host '   Enter an IP address like 192.168.10.2, or none.' -ForegroundColor Yellow }
    } until ($ok)
    if ($a -match '^\s*none\s*$') { $srHost = ''; $srm = 0 }
    else {
        $srHost = $a
        for ($try = 1; $try -le 3; $try++) {
            $srUser = Ask '   Backend username' $srUser
            $pq = if ($srSecret) { '   Backend password (Enter = keep the saved one)' } else { '   Backend password' }
            if ([Console]::IsInputRedirected) { $plain = Read-Host $pq }      # only when answers are fed in automatically
            else { $sec = Read-Host $pq -AsSecureString; $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)) }
            if (-not $plain -and $srSecret) { try { $plain = Unprotect-ResetPassword $srSecret } catch { $plain = '' } }
            Write-Host '   Checking the login (this does NOT restart anything)...'
            try {
                Test-SystemResetLogin $srHost $srUser $plain
                $srSecret = Protect-ResetPassword $plain
                Write-Host '   Login OK - password saved, encrypted for this PC.' -ForegroundColor Green
                break
            } catch {
                Write-Host "   Login failed: $(Get-CleanError $_)" -ForegroundColor Yellow
                if ($try -eq 3) { Write-Host '   Leaving the whole COM3000 reset off for now - run the installer again to retry.' -ForegroundColor Yellow; $srHost = ''; $srm = 0 }
            }
        }
        if ($srHost) { $srm = Ask-Number '15. Reset the whole COM3000 after a card has been missing how many minutes? (0 = off)' $SystemResetMinutes 0 240 }
    }

    # 16. daily PC reboot
    Write-Host "`n   Daily PC reboot: restarts this PC once a day (clears Windows hiccups; the monitor starts again by itself)."
    # Other tasks that restart or SHUT DOWN this PC: by name, or by what they run
    $isShutdownCmd = { param($c) $c -match 'shutdown(\.exe)?"?\s.*[/-][sp]\b|Stop-Computer' }
    $isRebootCmd   = { param($c) $c -match 'shutdown(\.exe)?"?\s.*[/-]r\b|Restart-Computer' }
    $allTasks = @(); try { $allTasks = @(Get-ScheduledTask -ErrorAction Stop) } catch { Write-Host "   (Couldn't look for other reboot/shutdown tasks - Windows Management (WMI) isn't answering on this PC.)" -ForegroundColor Yellow }
    $found = @($allTasks | Where-Object { $_.TaskName -ne $RebootTaskName -and $_.State -ne 'Disabled' -and $_.TaskPath -notlike '\Microsoft\*' } | ForEach-Object {
        $cmds = @($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' | '
        $kind = if (& $isShutdownCmd $cmds) { 'shutdown' } elseif ((& $isRebootCmd $cmds) -or $_.TaskName -match 'reboot|restart') { 'reboot' } elseif ($_.TaskName -match 'shut ?down|power ?off') { 'shutdown' } else { '' }
        if ($kind) {
            $next = try { (Get-ScheduledTaskInfo -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction Stop).NextRunTime } catch { $null }
            [pscustomobject]@{ Task = $_; Kind = $kind; Next = $next }
        }
    })
    $others    = @($found | Where-Object { $_.Kind -eq 'reboot' })
    $shutdowns = @($found | Where-Object { $_.Kind -eq 'shutdown' })
    $nearBackup = {   # is this time within 20 minutes of the backup time?
        param($When)
        if ($bkTime -eq 'off' -or -not $When) { return $false }
        $gap = [math]::Abs(([datetime]::ParseExact($When.ToString('HH:mm'), 'HH:mm', $Inv) - [datetime]::ParseExact($bkTime, 'HH:mm', $Inv)).TotalMinutes)
        return ([math]::Min($gap, 1440 - $gap) -lt 20)
    }
    $turnOff = { param($o) try { Disable-ScheduledTask -TaskName $o.Task.TaskName -TaskPath $o.Task.TaskPath -ErrorAction Stop | Out-Null; Write-Host "   Turned off '$($o.Task.TaskName)'." -ForegroundColor Green } catch { Write-Host "   Couldn't turn off '$($o.Task.TaskName)': $(Get-CleanError $_)" -ForegroundColor Yellow } }

    # A PC that shuts itself OFF can't monitor anything until someone turns it back on.
    foreach ($o in $shutdowns) {
        $w = if ($o.Next) { $o.Next.ToString('h:mm tt') } else { '?' }
        Write-Host "   WARNING: '$($o.Task.TaskName)' SHUTS THIS PC OFF (next at $w). While it's off: no alerts, no resets, no backup." -ForegroundColor Red
        $d = Read-Host "   Turn that task off? (Y/n)"
        if ("$d".Trim() -notmatch '^(n|no)$') { & $turnOff $o }
    }
    foreach ($o in $others) {
        $w = if ($o.Next) { $o.Next.ToString('h:mm tt') } else { '?' }
        Write-Host "   This PC already has a reboot task: '$($o.Task.TaskName)' (next run $w)." -ForegroundColor Yellow
        if (& $nearBackup $o.Next) { Write-Host '   That is within 20 minutes of the backup time - better to use the COM3000 reboot at another time.' -ForegroundColor Yellow }
    }
    if ($others) { Write-Host '   Answer off to keep using it, or give a time to use the COM3000 one instead.' -ForegroundColor Yellow }
    $rbShow = if ($RebootTime -eq 'off') { 'off' } else { ([datetime]::ParseExact($RebootTime, 'HH:mm', $Inv)).ToString('h:mm tt', $Inv) }
    $tries = 0
    do {
        $a = Ask '16. Reboot this PC every day at (e.g. 4:30 AM), or off' $rbShow
        $ok = $true
        if ($a -match '^\s*off\s*$') { $rbTime = 'off' }
        else {
            $t = [datetime]::MinValue
            [string[]]$fmts = @('h:mm tt', 'h:mmtt', 'h tt', 'htt', 'H:mm', 'HH:mm', 'h:mm t', 'ht')
            if ([datetime]::TryParseExact(($a.ToUpper() -replace '\.', ''), $fmts, $Inv, [Globalization.DateTimeStyles]::AllowWhiteSpaces, [ref]$t)) {
                $rbTime = $t.ToString('HH:mm')
                if ($bkTime -ne 'off') {
                    $gap = [math]::Abs(([datetime]::ParseExact($rbTime, 'HH:mm', $Inv) - [datetime]::ParseExact($bkTime, 'HH:mm', $Inv)).TotalMinutes)
                    if ([math]::Min($gap, 1440 - $gap) -lt 20) { $ok = $false; Write-Host '   That is within 20 minutes of the backup time - pick a time at least 20 minutes away.' -ForegroundColor Yellow }
                }
            } else { $ok = $false; Write-Host '   Please enter a time like 4:30 AM, or off.' -ForegroundColor Yellow }
        }
        if (-not $ok -and ++$tries -ge 5) { $rbTime = $RebootTime; $ok = $true; Write-Host "   Keeping $rbShow." -ForegroundColor Yellow }
    } until ($ok)
    if ($rbTime -ne 'off' -and $others) {
        $d = Read-Host "   Turn off the other reboot task(s) so the PC doesn't restart twice a day? (Y/n)"
        if ("$d".Trim() -notmatch '^(n|no)$') {
            foreach ($o in $others) { & $turnOff $o }
        }
    }

    # 17. daily EPG refresh (re-press Submit on the EPG page so AEP boxes reload the guide)
    Write-Host "`n   Daily EPG refresh: every morning, re-submit the EPG page as it is (same list, same checkboxes),"
    Write-Host '   like pressing Submit, so AEP boxes reload the guide. Runs in the background; phone alert only if it fails.'
    $erShow = if ($EpgRefreshTime -eq 'off') { 'off' } else { ([datetime]::ParseExact($EpgRefreshTime, 'HH:mm', $Inv)).ToString('h:mm tt', $Inv) }
    $tries = 0
    do {
        $a = Ask '17. Refresh the EPG every day at (e.g. 5:30 AM), or off' $erShow
        $ok = $true
        if ($a -match '^\s*off\s*$') { $erTime = 'off' }
        else {
            $t = [datetime]::MinValue
            [string[]]$fmts = @('h:mm tt', 'h:mmtt', 'h tt', 'htt', 'H:mm', 'HH:mm', 'h:mm t', 'ht')
            if ([datetime]::TryParseExact(($a.ToUpper() -replace '\.', ''), $fmts, $Inv, [Globalization.DateTimeStyles]::AllowWhiteSpaces, [ref]$t)) {
                $erTime = $t.ToString('HH:mm')
                foreach ($other in @(@('backup', $bkTime), @('daily PC reboot', $rbTime))) {
                    if ("$($other[1])" -notmatch '^\d\d:\d\d$') { continue }
                    $gap = [math]::Abs(([datetime]::ParseExact($erTime, 'HH:mm', $Inv) - [datetime]::ParseExact($other[1], 'HH:mm', $Inv)).TotalMinutes)
                    if ([math]::Min($gap, 1440 - $gap) -lt 20) { $ok = $false; Write-Host "   That is within 20 minutes of the $($other[0]) time - pick a time at least 20 minutes away." -ForegroundColor Yellow }
                }
            } else { $ok = $false; Write-Host '   Please enter a time like 5:30 AM, or off.' -ForegroundColor Yellow }
        }
        if (-not $ok -and ++$tries -ge 5) { $erTime = $EpgRefreshTime; $ok = $true; Write-Host "   Keeping $erShow." -ForegroundColor Yellow }
    } until ($ok)
    if ($erTime -ne 'off') {
        $erBlades = (Ask '    Which blades? IP addresses like 192.168.3.18,192.168.3.20 (Enter = every blade that has an EPG)' $(if ("$EpgRefreshBlades".Trim()) { $EpgRefreshBlades } else { '' })).Trim()
        $erBlades = (@($erBlades -split '[,\s]+' | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }) -join ',')
    }

    # 18. desktop background
    $wa = Ask '18. Plain desktop background with the location name, so the icons are easy to see: blue, gray or no' $(if ("$Wallpaper" -eq 'off') { 'no' } elseif ("$Wallpaper" -eq 'gray') { 'gray' } else { 'blue' })
    $wpAns = if ($wa -match '^\s*(n|no|off)\s*$') { 'off' } elseif ($wa -match '^\s*(g|gray|grey)\s*$') { 'gray' } else { 'blue' }

    # 19. extra pages for the Blades icon (streamers etc.)
    $xa = Ask '19. Other IPs to open with the COM3000 blades, e.g. a streamer (like 192.168.3.200, comma-separated), or none' $(if ("$ExtraTabs".Trim()) { $ExtraTabs } else { 'none' })
    $xtAns = (@($xa -split '[,\s]+' | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+(:\d+)?$' }) -join ',')

    & $writeSettings
    $IgnoreChannels = $ignList
    $watching = if ($scan) { @($scan.Channels | Where-Object { -not (Test-Ignored $_) }).Count } else { '?' }
    Write-Host ("Skipping: {0}" -f $(if ($ignList) { $ignList -join ', ' } else { 'nothing' })) -ForegroundColor Green
    Write-Host "Watching $watching channels." -ForegroundColor Green
    Write-Host ''
    $go = Read-Host 'Does that look right? Install the monitor now? (Y/n)'
    if ("$go".Trim() -match '^(n|no)$') {
        Write-Host 'Not installed. Run "Install COM3000 Monitor" again when ready.' -ForegroundColor Yellow
    } else {
        & $psExe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Install
        if ($wpAns -ne 'off') { $Wallpaper = $wpAns; Set-ComWallpaper $name }
        if ($bkTime -ne 'off' -and (Start-DriveCopy)) { Write-Host "Copying today's backup to Google Drive now..." }
        Write-Host "`nDone. Keep this folder where it is - the monitor runs the script from here:" -ForegroundColor Green
        Write-Host "  $ScriptDir"
        Write-Host "To change any of these answers later, just run Install COM3000 Monitor again."
    }
    return
}

# ---------------- Install / Uninstall ----------------
if ($Uninstall) {
    if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
        Write-Host "The monitor is not installed on this PC (no task named '$TaskName')." -ForegroundColor Yellow
        return
    }
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue     # end a running/stuck check too
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Unregister-ScheduledTask -TaskName $DriveTaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "Removed scheduled task '$TaskName'. The monitor is off." -ForegroundColor Green
        # tell the dashboard (and the other sites) this site was turned off on purpose
        if ("$StatusReports" -ne 'off') {
            try {
                $sum = Get-ResetSummary
                $rep = [ordered]@{ v = 1; site = $SiteName; pc = $env:COMPUTERNAME; t = (Get-Date).ToString('o'); page = 'off'
                                   cards = @(); outN = 0; out = @(); resets = $sum.Months; recent = $sum.Recent; slotResets = $sum.BySlot; slotMonths = $sum.BySlotMonth; allRes = $sum.All }
                Send-Ntfy "$NtfyServer/$(Get-StatusTopic)" ([Text.Encoding]::UTF8.GetBytes(($rep | ConvertTo-Json -Depth 6 -Compress))) @{ Title = "status $SiteName"; Priority = 'min'; Tags = 'bar_chart' }
                $st = Load-State; $st.statusSig = ''; Save-State $st      # report again as soon as it's turned back on
                Write-Host 'The COM3000 Dashboard now shows this site as "Monitor off".'
            } catch { Write-Host "(Couldn't tell the dashboard: $(Get-CleanError $_))" -ForegroundColor Yellow }
        }
    } catch {
        Write-Host "Could NOT remove the monitor: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Close this window, open PowerShell with "Run as administrator", and run -Uninstall again.' -ForegroundColor Red
    }
    return
}

if ($Install) {
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                   -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
                   -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                   -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch {}     # end a stuck check, if any
    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    } catch {
        # Windows Management (WMI/CIM) not answering on some PCs - set the task up with schtasks.exe instead
        $why = $_.Exception.Message
        $tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \`"$PSCommandPath\`""
        $out = (& schtasks.exe /Create /TN $TaskName /SC MINUTE /MO $IntervalMinutes /RU SYSTEM /RL HIGHEST /F /TR $tr 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Could NOT install the monitor: $why / $out" -ForegroundColor Red
            Write-Host 'Close this window, open PowerShell with "Run as administrator", and run -Install again.' -ForegroundColor Red
            return
        }
        Write-Host '(Installed with schtasks - Windows Management (WMI) is not answering on this PC; a restart usually fixes that.)' -ForegroundColor Yellow
    }
    Write-Host "Installed. The monitor checks every $IntervalMinutes minutes, even when no one is logged in." -ForegroundColor Green
    Write-Host "Log file: $LogFile"
    try { New-DesktopShortcuts } catch { Write-Host "(Couldn't create desktop shortcuts: $($_.Exception.Message))" -ForegroundColor Yellow }
    if ($BackupTime -ne 'off') {
        try { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null } catch {}
        try {
            $u = Register-DriveCopyTask
            Write-Host "Daily backup at $(([datetime]::ParseExact($BackupTime, 'HH:mm', $Inv)).ToString('h:mm tt', $Inv)) to the desktop folder 'COM3000 Backups', copied to Google Drive as $u." -ForegroundColor Green
        } catch {
            Write-Host "(Backups will still be saved to the desktop, but the Google Drive copy couldn't be set up: $($_.Exception.Message))" -ForegroundColor Yellow
        }
    } else {
        Unregister-ScheduledTask -TaskName $DriveTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    # daily PC reboot
    try {
        if ("$RebootTime" -match '^\d\d:\d\d$') {
            $rbAt = [datetime]::ParseExact($RebootTime, 'HH:mm', $Inv)
            $rbAction = New-ScheduledTaskAction -Execute 'shutdown.exe' -Argument '/r /f /t 60 /c "Daily COM3000 PC reboot - restarting in 1 minute."'
            $rbTrigger = New-ScheduledTaskTrigger -Daily -At $rbAt
            $rbPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $rbSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
            try { Register-ScheduledTask -TaskName $RebootTaskName -Action $rbAction -Trigger $rbTrigger -Principal $rbPrincipal -Settings $rbSettings -Force -ErrorAction Stop | Out-Null }
            catch {
                $o2 = (& schtasks.exe /Create /TN $RebootTaskName /SC DAILY /ST $($rbAt.ToString('HH:mm', $Inv)) /RU SYSTEM /RL HIGHEST /F /TR 'shutdown.exe /r /f /t 60' 2>&1 | Out-String).Trim()
                if ($LASTEXITCODE -ne 0) { throw "$($_.Exception.Message) / $o2" }
            }
            Write-Host "Daily PC reboot at $($rbAt.ToString('h:mm tt', $Inv))." -ForegroundColor Green
        } else {
            Unregister-ScheduledTask -TaskName $RebootTaskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    } catch { Write-Host "(Couldn't set up the daily reboot: $(Get-CleanError $_))" -ForegroundColor Yellow }
    Send-Alert 'monitor installed' "Watching $PageUrl every $IntervalMinutes min. (version $ScriptVersion)" 'default' 'white_check_mark'
    return
}

# ---------------- Pause / Resume ----------------
if ($Resume) {
    Remove-Item $PauseFile -ErrorAction SilentlyContinue
    Write-Host 'Monitoring resumed.'
    Write-Log 'Pause ended by -Resume.'
    Write-DesktopLog 'MONITORING RESUMED'
    return
}
if ($Pause -gt 0) {
    $until = (Get-Date).AddMinutes($Pause)
    Set-Content -Path $PauseFile -Value $until.ToString('o')
    Write-Host "Alerts paused until $($until.ToString('h:mm tt')). Run with -Resume to end early."
    Write-Log "Paused for $Pause minutes."
    Write-DesktopLog "PAUSED for $Pause minutes (until $($until.ToString('h:mm tt')))"
    return
}

# ---------------- One check ----------------
# WATCHDOG: a background check must never get stuck (Windows then skips every later check).
# If this check is still running after 4 minutes, log where it was and end it; the next
# check starts normally a minute later.
function Set-Step([string]$Text) { try { [ComWatchdog]::Step = $Text } catch {} }
if (-not $Test -and -not $Status) {
    try {
        $wdDll = Join-Path $ScriptDir 'com3000-watchdog.dll'
        if (-not ('ComWatchdog' -as [type])) {
            if (Test-Path $wdDll) { Add-Type -Path $wdDll -ErrorAction Stop }
            else {
                Add-Type -OutputAssembly $wdDll -OutputType Library -ErrorAction Stop -TypeDefinition @'
public static class ComWatchdog {
    public static string Step = "starting";
    static System.Threading.Timer timer;
    public static void Start(int seconds, string logFile) {
        timer = new System.Threading.Timer(delegate(object o) {
            try {
                System.IO.File.AppendAllText(logFile, System.DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") +
                    "  Check took over " + seconds + " s and was stopped (it was " + Step + "). The next check starts normally." + System.Environment.NewLine);
            } catch { }
            System.Diagnostics.Process.GetCurrentProcess().Kill();
        }, null, seconds * 1000, System.Threading.Timeout.Infinite);
    }
}
'@
                Add-Type -Path $wdDll -ErrorAction Stop
            }
        }
        [ComWatchdog]::Start(240, $LogFile)
    } catch { Write-Log "Watchdog not available: $(Get-CleanError $_)" }
}
Set-Step 'loading its saved state'
$state = Load-State
if ($Status) {
    Write-Host "COM3000 status - $SiteName   (monitor version $ScriptVersion)" -ForegroundColor Cyan
    # is the background monitor running? look at when it last wrote a check to monitor.log
    $last = $null
    if (Test-Path $LogFile) {
        $hit = Get-Content $LogFile -Tail 300 | Where-Object { $_ -match '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)  (OK -|Check failed|Paused until|This PC is off the network|Internet |Check took over)' } | Select-Object -Last 1
        if ($hit) { $last = [datetime]::ParseExact($hit.Substring(0, 19), 'yyyy-MM-dd HH:mm:ss', $Inv) }
    }
    $offNet = $hit -and $hit -match '  (This PC is off the network|Internet )'
    if ($hit -and $hit -match 'Check took over' -and ((Get-Date) - $last).TotalMinutes -le ($IntervalMinutes * 2 + 4)) {
        Write-Host ("Monitor: ON, but its checks are getting stuck - last one at {0}: {1}" -f $last.ToString('h:mm tt'), $hit.Substring(21)) -ForegroundColor Yellow
    } elseif ($offNet -and ((Get-Date) - $last).TotalMinutes -le ($IntervalMinutes * 2 + 1)) {
        Write-Host ("Monitor: ON, but this PC has NO INTERNET - last check {0}: {1}" -f $last.ToString('h:mm tt'), ($hit.Substring(21) -replace '\s+-\s+skipping.*$', '')) -ForegroundColor Yellow
    } elseif ($last -and ((Get-Date) - $last).TotalMinutes -le ($IntervalMinutes * 2 + 1)) {
        Write-Host ("Monitor: ON - last background check at {0}, every {1} min" -f $last.ToString('h:mm tt'), $IntervalMinutes) -ForegroundColor Green
    } elseif ($last) {
        Write-Host ("Monitor: OFF or not running - last background check was {0}" -f $last.ToString('MM/dd h:mm tt')) -ForegroundColor Red
    } else {
        Write-Host 'Monitor: OFF - no background checks found yet' -ForegroundColor Red
    }
    $rbTask = Get-ScheduledTask -TaskName $RebootTaskName -ErrorAction SilentlyContinue
    Write-Host "Daily EPG refresh: $(if ("$EpgRefreshTime" -match '^\d\d:\d\d$') { "$(([datetime]::ParseExact($EpgRefreshTime, 'HH:mm', $Inv)).ToString('h:mm tt', $Inv)) on $(if ("$EpgRefreshBlades".Trim()) { $EpgRefreshBlades } else { 'every blade that has an EPG' })" } else { 'off' })"
    # (this window isn't run as administrator, so Windows may hide the task from it - also ask schtasks and the settings)
    if (-not $rbTask) { & schtasks.exe /Query /TN $RebootTaskName 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { $rbTask = $true } }
    if ($rbTask) {
        $rbNext = try { (Get-ScheduledTaskInfo -TaskName $RebootTaskName -ErrorAction Stop).NextRunTime.ToString('ddd h:mm tt') } catch { if ("$RebootTime" -match '^\d\d:\d\d$') { 'every day at ' + ([datetime]::ParseExact($RebootTime, 'HH:mm', $Inv)).ToString('h:mm tt', $Inv) } else { 'on' } }
        Write-Host "Daily PC reboot: $rbNext"
    } elseif ("$RebootTime" -match '^\d\d:\d\d$') { Write-Host "Daily PC reboot: every day at $(([datetime]::ParseExact($RebootTime, 'HH:mm', $Inv)).ToString('h:mm tt', $Inv))" }
    else { Write-Host 'Daily PC reboot: off' }
    if ($BackupTime -eq 'off') { Write-Host 'Backups: off' }
    else {
        $lastFile = Get-ChildItem -Path $BackupDir -Filter '*COM3000 backup*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
        $lb = if ($lastFile) { "$($lastFile.LastWriteTime.ToString('ddd MM/dd h:mm tt')) ($($lastFile.Name))" } else { 'none yet' }
        Write-Host "Backups: daily at $(([datetime]::ParseExact($BackupTime, 'HH:mm', $Inv)).ToString('h:mm tt', $Inv)) - last one $lb"
        $ds = if (Test-Path $DriveStatusFile) { (Get-Content $DriveStatusFile -Raw).Trim() } else { 'not run yet' }
        Write-Host "Google Drive copy: $ds" -ForegroundColor $(if ($ds -match 'OK') { 'Gray' } else { 'Yellow' })
    }
    $outNow = @($state.alerted.Keys | ForEach-Object { if ($state.labels[$_]) { $state.labels[$_] } else { $_ } })
    if ($outNow.Count -gt 0) {
        Write-Host "Currently alerted as down:" -ForegroundColor Red
        foreach ($o in $outNow) { Write-Host "  $o" -ForegroundColor Red }
    }
} elseif ($Test) { Write-Host "COM3000 monitor test - $SiteName" -ForegroundColor Cyan }

# ---- Clear test resets (button: "Clear Test Resets") ----
if ($ClearResets) {
    try {
        Set-Content -Path $ResetHistoryFile -Value 'time,kind,slot,how' -Encoding ASCII -ErrorAction Stop
        $st = Load-State
        foreach ($n in 'resetDay', 'resetAt', 'nvSince', 'gnSince') { $st[$n] = @{} }
        $st.sysResetDay = ''; $st.sysSkipDay = ''; $st.sysResetAt = ''; $st.sysResetSlots = ''; $st.pdSince = ''
        $st.netReboot = ''      # test PC restarts (internet self-fix) don't count against the 2-a-day limit
        $st.statusSig = ''      # send a fresh report to the dashboard on the next check
        Save-State $st
        Remove-Item $PauseFile -ErrorAction SilentlyContinue
        Write-Log 'Reset history cleared (test resets removed) - automatic resets ready again'
        Write-Host "Done for $SiteName." -ForegroundColor Green
        Write-Host '  - Reset history cleared: the dashboard shows 0 resets for this site within a few minutes.'
        Write-Host '  - Automatic card and whole COM3000 resets are ready again (the one-per-day limits are cleared).'
        Write-Host '  - Any pause from a test reset is over: alerts are back on.'
        Write-Host '  - Test PC restarts (no-internet fix) are cleared: it can restart again right away.'
    } catch {
        Write-Host "Could not clear the reset history: $(Get-CleanError $_)" -ForegroundColor Red
        Write-Host 'Use the Clear Test Resets button, which asks for administrator permission.' -ForegroundColor Red
    }
    return
}

# ---- Internet self-repair: when this PC can't reach the internet, try to get it back ----
#   10 min down: restart the network connection   15 min: renew the address (DHCP) and clear DNS
#   25 min: restart the PC - at most twice in 24 hours, 6 hours apart. Still down 2 hours later: try the steps again.
#   One message when it's back.
function Test-Internet {
    $hosts = @(@(([uri]$NtfyServer).Host, 443), @('1.1.1.1', 443), @('8.8.8.8', 443))
    $tests = @(foreach ($h in $hosts) { $tc = New-Object Net.Sockets.TcpClient; [pscustomobject]@{ Tc = $tc; Task = $(try { $tc.ConnectAsync($h[0], $h[1]) } catch { $null }) } })
    try { [void][Threading.Tasks.Task]::WaitAll(@($tests | Where-Object { $_.Task } | ForEach-Object { $_.Task }), 4000) } catch {}
    $ok = [bool]@($tests | Where-Object { $_.Task -and $_.Task.Status -eq 'RanToCompletion' -and $_.Tc.Connected }).Count
    foreach ($t in $tests) { try { $t.Tc.Close() } catch {} }
    return $ok
}
function Get-Gateway { try { return "$(@(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric)[0].NextHop)" } catch { return '' } }
function Test-Ping([string]$Ip) { if (-not $Ip) { return $false }; try { return ((New-Object Net.NetworkInformation.Ping).Send($Ip, 1500).Status -eq 'Success') } catch { return $false } }
if ("$NetRepair" -ne 'off' -and -not $ReadOnly -and -not $Test -and -not $Status) {
    Set-Step 'checking the internet'
    $now = Get-Date
    if (Test-Internet) {
        if ($state.netDown) {
            $since = [datetime]::Parse($state.netDown, $Inv, [Globalization.DateTimeStyles]::RoundtripKind)
            $mins = [int]($now - $since).TotalMinutes
            # what fixed it: the step tried in the last 5 minutes, otherwise it came back on its own
            $at = [datetime]::MinValue; [void][datetime]::TryParse("$($state.netStepAt)", $Inv, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$at)
            $fresh = ($now - $at).TotalMinutes -le 5
            $how = if ($fresh -and $state.netStep -eq 1) { 'it came back right after the PC restarted its network connection' }
                   elseif ($fresh -and $state.netStep -eq 2) { 'it came back right after the PC renewed its network address' }
                   elseif ($state.netStep -eq 3 -and ($now - $at).TotalMinutes -le 15) { 'it came back after the PC restarted itself' }
                   elseif ($state.netCut) { "it came back on its own - this PC couldn't reach the router or the COM3000 either, so check its network cable / switch port" }
                   else { 'it came back on its own - most likely the router or the internet service' }
            $t = @("$($state.netTried)" -split ',') + @(0, 0, 0)
            $tried = @(); if ([int]$t[0]) { $tried += "network restart x$([int]$t[0])" }; if ([int]$t[1]) { $tried += "address renew x$([int]$t[1])" }; if ([int]$t[2]) { $tried += "PC restart x$([int]$t[2])" }
            $triedTxt = if ($tried) { $tried -join ', ' } else { 'nothing yet' }
            Write-Log "Internet back after $mins min - $how (tried: $triedTxt)"
            $paused = $false; if (Test-Path $PauseFile) { $pu = [datetime]::MinValue; [void][datetime]::TryParse((Get-Content $PauseFile -Raw).Trim(), $Inv, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$pu); $paused = (Get-Date) -lt $pu }
            if ($mins -ge 10 -and -not $paused) {
                Send-Alert 'internet back' "$SiteName PC was offline for $mins min ($($since.ToString('h:mm tt')) - $($now.ToString('h:mm tt'))) - $how.$(if ($tried) { " The PC tried: $triedTxt." })" 'low' 'globe_with_meridians'
            }
            $state.netDown = ''; $state.netCycle = ''; $state.netCut = ''; $state.netStep = 0; $state.netStepAt = ''; $state.netTried = ''
        }
    } else {
        if (-not $state.netDown) { $state.netDown = $now.ToString('o'); $state.netCycle = ''; $state.netStep = 0; $state.netTried = ''; Write-Log "Internet not reachable from this PC - watching it. (monitor version $ScriptVersion)" }
        $since = [datetime]::Parse($(if ($state.netCycle) { $state.netCycle } else { $state.netDown }), $Inv, [Globalization.DateTimeStyles]::RoundtripKind)
        $down = ($now - $since).TotalMinutes
        $addTry = { param($k) $t = @("$($state.netTried)" -split ',') + @(0, 0, 0); $c = @([int]$t[0], [int]$t[1], [int]$t[2]); $c[$k]++; $state.netTried = $c -join ',' }
        $gw = Get-Gateway; $gwOk = Test-Ping $gw; $comOk = Test-HostPort (Get-ComMainIp)
        if ($state.netStep -lt 1 -and $down -ge 10) {
            Set-Step 'restarting the network connection'
            $ads = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Disabled' })
            foreach ($a in $ads) { try { Restart-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop } catch {} }
            $state.netStep = 1; $state.netStepAt = $now.ToString('o'); & $addTry 0
            Write-Log "Internet down $([int]$down) min (router $gw $(if ($gwOk) { 'answers' } else { 'not answering' }), COM3000 $(if ($comOk) { 'answers' } else { 'not answering' })) - restarted the network connection ($(@($ads | ForEach-Object { $_.Name }) -join ', '))."
        } elseif ($state.netStep -eq 1 -and $down -ge 15) {
            Set-Step 'renewing the network address'
            try { & ipconfig.exe /renew | Out-Null } catch {}
            try { & ipconfig.exe /flushdns | Out-Null } catch {}
            $state.netStep = 2; $state.netStepAt = $now.ToString('o'); & $addTry 1
            Write-Log "Internet still down ($([int]$down) min) - renewed the network address and cleared DNS."
        } elseif ($state.netStep -eq 2 -and $down -ge 25) {
            # restarts asked for in the last 24 hours - only ones Windows really did (it started up after the request)
            $bootAt = [datetime]::MaxValue; try { $bootAt = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch {}
            $recent = @("$($state.netReboot)" -split ',' | Where-Object { $_ } | ForEach-Object { $t = [datetime]::MinValue; if ([datetime]::TryParse($_, $Inv, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$t) -and ($now - $t).TotalHours -lt 24 -and $bootAt -ge $t) { $_ } })
            $lastBoot = [datetime]::MinValue; foreach ($r in $recent) { $t = [datetime]::Parse($r, $Inv, [Globalization.DateTimeStyles]::RoundtripKind); if ($t -gt $lastBoot) { $lastBoot = $t } }
            if ($recent.Count -lt 2 -and ($now - $lastBoot).TotalHours -ge 6) {
                $state.netStep = 3; $state.netBootOk = ''; $state.netStepAt = $now.ToString('o'); $state.netReboot = (@($recent) + $now.ToString('o')) -join ','; & $addTry 2
                Save-State $state
                Write-Log "Internet down $([int]$down) min (router $gw $(if ($gwOk) { 'answers' } else { 'not answering' }), COM3000 $(if ($comOk) { 'answers' } else { 'not answering' })) - restarting the PC ($($recent.Count + 1) of 2 allowed in 24 hours)."
                # shutdown.exe, like the daily reboot (Restart-Computer can quietly fail when run by the background task)
                $out = (& shutdown.exe /r /f /t 30 /d p:4:1 /c 'COM3000 Monitor: no internet for 25 minutes - restarting this PC to get it back.' 2>&1 | Out-String).Trim()
                if ($LASTEXITCODE -ne 0) {
                    Write-Log "shutdown.exe didn't work (code $LASTEXITCODE $out) - trying Restart-Computer."
                    try { Restart-Computer -Force -ErrorAction Stop } catch { Write-Log "The PC could NOT be restarted: $(Get-CleanError $_)" }
                }
                return
            }
            $state.netStep = 4; $state.netStepAt = $now.ToString('o')
            Write-Log "Internet still down ($([int]$down) min). Not restarting the PC again yet (at most twice a day, 6 hours apart) - restarts counted: $(if ($recent.Count) { ($recent | ForEach-Object { ([datetime]::Parse($_, $Inv, [Globalization.DateTimeStyles]::RoundtripKind)).ToString('MM/dd h:mm tt') }) -join ', ' } else { 'none' }); Windows last started $(if ($bootAt -ne [datetime]::MaxValue) { $bootAt.ToString('MM/dd h:mm tt') } else { 'unknown' })."

        } elseif ($state.netStep -eq 3 -and -not $state.netBootOk) {
            # first check after asking for the restart: did Windows actually restart?
            $state.netBootOk = 'checked'
            try {
                $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
                $asked = [datetime]::Parse($state.netStepAt, $Inv, [Globalization.DateTimeStyles]::RoundtripKind)
                if ($boot -lt $asked) {
                    Write-Log "The PC restart did NOT happen (last start $($boot.ToString('MM/dd h:mm tt'))) - not counting it."
                    $state.netReboot = (@("$($state.netReboot)" -split ',' | Where-Object { $_ -and $_ -ne $state.netStepAt }) -join ',')
                    $t = @("$($state.netTried)" -split ',') + @(0, 0, 0); $state.netTried = (@([int]$t[0], [int]$t[1], [Math]::Max(0, [int]$t[2] - 1)) -join ',')
                } else { Write-Log "PC restarted at $($boot.ToString('h:mm tt')) - internet still down." }
            } catch {}
        } elseif ($state.netStep -ge 3) {
            # still down 2 hours after the last try: go through the steps again (the PC restart still only twice a day)
            $at = [datetime]::MinValue; [void][datetime]::TryParse("$($state.netStepAt)", $Inv, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$at)
            if (($now - $at).TotalMinutes -ge 120) {
                $state.netCycle = $now.AddMinutes(-10).ToString('o'); $state.netStep = 0
                Write-Log 'Internet still down 2 hours after the last try - going through the steps again.'
            }
        }
        # this PC can't reach the router OR the COM3000: it's cut off (cable, switch port, its own network) -
        # the COM3000 is not the problem, so don't count the cards as down (no false 'card offline/back' alerts)
        if (-not $gwOk -and -not $comOk) {
            $state.netCut = 'yes'
            foreach ($k in @($state.counts.Keys)) { $state.counts[$k] = 0 }
            $state.failCount = 0; $state.pdSince = ''
            Save-State $state
            Write-Log "This PC is off the network (router and COM3000 not answering) - skipping the COM3000 check."
            return
        }
    }
}

# ---- Self-update from GitHub (about once an hour) ----
if ("$AutoUpdate" -ne 'off' -and "$UpdateUrl" -match '^https://' -and -not $ReadOnly -and -not $Test -and -not $Status) {
    $lastUpd = [datetime]::MinValue; [void][datetime]::TryParse("$($state.updCheckAt)", $Inv, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$lastUpd)
    if (((Get-Date) - $lastUpd).TotalMinutes -ge 60) {
        Set-Step 'checking for a newer version'
        $state.updCheckAt = (Get-Date).ToString('o'); Save-State $state
        try {
            $rq = [System.Net.HttpWebRequest]::Create("$($UpdateUrl)?t=$([DateTime]::UtcNow.Ticks)")
            $rq.Timeout = 20000; $rq.ReadWriteTimeout = 20000; $rq.UserAgent = 'COM3000-monitor-update'
            $rs = $rq.GetResponse()
            try { $ms = New-Object IO.MemoryStream; $rs.GetResponseStream().CopyTo($ms); $bytes = $ms.ToArray() } finally { $rs.Close() }
            $txt = [Text.Encoding]::UTF8.GetString($bytes)
            $newVer = [regex]::Match($txt, "(?m)^\`$ScriptVersion = '([^']+)'").Groups[1].Value
            if ($newVer -and $newVer -gt $ScriptVersion) {
                # only a complete, error-free copy of THIS program
                $errs = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($txt, [ref]$null, [ref]$errs)
                $ok = ($bytes.Length -gt 100000) -and ($txt -match 'COM3000 Channel Monitor') -and ($txt -match '(?s)# ---- END OF COM3000 MONITOR ----[^\r\n]*\s*$') -and -not @($errs).Count
                if ($ok) {
                    $cur = $PSCommandPath
                    $new = Join-Path $ScriptDir 'com3000-monitor.new.ps1'
                    [IO.File]::WriteAllBytes($new, $bytes)
                    Copy-Item -LiteralPath $cur -Destination (Join-Path $ScriptDir 'com3000-monitor.previous.ps1') -Force
                    Move-Item -LiteralPath $new -Destination $cur -Force
                    Write-Log "Updated itself: version $ScriptVersion -> $newVer (old copy kept as com3000-monitor.previous.ps1). The next check uses the new version."
                    $state.statusSig = ''      # tell the dashboard the new version straight away
                } else {
                    Write-Log "Found version $newVer online but it didn't pass the checks (incomplete or has errors) - not using it."
                }
            }
        } catch { Write-Log "Update check skipped: $(Get-CleanError $_)" }
    }
}

if (Test-Path $PauseFile) {
    $until = [datetime]::MinValue
    [void][datetime]::TryParse((Get-Content $PauseFile -Raw).Trim(), $Inv, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$until)
    if ($ReadOnly -and (Get-Date) -lt $until) {
        Write-Host "Alerts are PAUSED until $($until.ToString('h:mm tt'))." -ForegroundColor Yellow
    } elseif ((Get-Date) -lt $until) {
        # paused: skip checks and restart the down-counters so nothing alerts the moment the pause ends
        foreach ($k in @($state.counts.Keys)) { $state.counts[$k] = 0 }
        $state.failCount = 0
        Set-Step 'sending the dashboard report (paused)'
        Send-StatusReport $state @{ Page = 'paused'; Via = ''; Paused = $until.ToString('o'); Err = ''; Cards = @(); Out = @(); Watched = 0 }
        Save-State $state
        Write-Log "Paused until $($until.ToString('MM/dd h:mm tt')) - skipping check."
        if ($Test) { Write-Host 'Monitor is currently paused. Run with -Resume first.' -ForegroundColor Yellow }
        return
    }
    if (-not $ReadOnly) {
        Remove-Item $PauseFile -ErrorAction SilentlyContinue
        Write-Log 'Pause expired, monitoring resumed.'
    }
}

# ---- Cards / devices on the network ----
# Uses the cards listed on the Overview page (remembered from the last good read,
# so a card is still checked if the page itself can't be loaded) plus $Cards.
function Invoke-DeviceChecks($s, [switch]$Defer) {
    $script:CardUp      = @{}
    $script:CardDownNew = New-Object System.Collections.ArrayList
    $script:CardBack    = New-Object System.Collections.ArrayList
    $devices = [ordered]@{}
    if ($WatchCards) { foreach ($k in ($s.devices.Keys | Sort-Object)) { $devices[$k] = $s.devices[$k] } }
    foreach ($k in $Cards.Keys) { $devices[$k] = $Cards[$k] }

    $down = New-Object System.Collections.ArrayList
    $back = New-Object System.Collections.ArrayList
    $keys = @{}
    if ($Test -and $devices.Count -gt 0) { Write-Host "`nChecking cards on the network..." -ForegroundColor Cyan }
    foreach ($ip in $devices.Keys) {
        $key  = "card:$ip"
        $keys[$key] = $true
        $name = "$($devices[$ip]) ($ip)"
        $up   = Test-Card $ip
        $script:CardUp[$ip] = $up
        if ($Test) {
            Write-Host ("  {0,-30} {1}" -f $name, $(if ($up) { 'online' } else { 'NOT RESPONDING' })) -ForegroundColor $(if ($up) { 'Gray' } else { 'Red' })
        }
        switch (Update-Item $s $key (-not $up) "$name offline") {
            'down' { [void]$down.Add($name); [void]$script:CardDownNew.Add($ip) }
            'up'   { [void]$back.Add("$name back online (offline since $($s.alerted[$key]))"); Clear-Item $s $key }
        }
    }
    foreach ($k in @($s.counts.Keys + $s.alerted.Keys)) { if ($k -like 'card:*' -and -not $keys.ContainsKey($k)) { Clear-Item $s $k } }
    if ($Defer) { foreach ($b in $back) { [void]$script:CardBack.Add($b) }; return }   # sent together with the channel alerts
    if ($down.Count -gt 0) {
        Send-Alert $(if ($down.Count -eq 1) { 'card offline' } else { "$($down.Count) cards offline" }) ($down -join "`n") 'urgent' 'rotating_light'
    }
    if ($back.Count -gt 0) {
        Send-Alert $(if ($back.Count -eq 1) { 'card back online' } else { "$($back.Count) cards back online" }) ($back -join "`n") 'default' 'white_check_mark'
    }
}

# ---- Overview page ----
try {
    if ($Test) { Write-Host "`nLoading $PageUrl (can take up to a minute)..." -ForegroundColor Cyan }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Set-Step 'reading the COM3000 Overview page'
    if (-not $Test) {
        # normal checks: if the main card is offline, read the page from another card
        $ov = Get-ComOverview; $html = $ov.Html
        if ($script:ComHostNow) { Write-Log "Main card $(Get-ComMainIp) not answering - read the COM3000 page from card $($script:ComHostNow)" }
    } else { $html = Get-PageHtml $PageUrl }
    if ($Test) { Write-Host ("  Got {0:N0} characters in {1:N0} seconds. Reading channels..." -f $html.Length, $sw.Elapsed.TotalSeconds) }
    try { $data = Get-ComData $html } catch {
        if ($Test) {
            $dump = Join-Path $ScriptDir 'overview-page.html'
            Set-Content -Path $dump -Value $html -Encoding UTF8
            Write-Host "Saved the page to $dump - send this file over so the reader can be adjusted." -ForegroundColor Yellow
        }
        throw
    }
} catch {
    $pageErr = Get-CleanError $_
    $state.failCount++
    Write-Log "Check failed ($($state.failCount)): $(Get-CleanError $_)"
    if ($state.failCount -ge $ChecksToAlert -and -not $state.failAlerted) {
        Send-Alert 'COM3000 unreachable' "Can't read the COM3000 page for $MinutesBeforeAlert+ minutes.`n$(Get-CleanError $_)" 'urgent' 'rotating_light'
        $state.failAlerted = $true
        $state.lastSent['page'] = (Get-Date).ToString('o')
    }
    Set-Step 'checking the cards on the network'
    Invoke-DeviceChecks $state
    Set-Step 'deciding on a whole COM3000 reset'
    # The COM3000 page itself is served by a card (e.g. the card in slot 1). If that card is
    # pulled or dead, the page goes away too - treat that as a missing card for the
    # automatic whole COM3000 reset (same minutes, same once-per-day limit).
    if (-not $ReadOnly -and -not $Test -and $SystemResetMinutes -gt 0 -and "$SystemResetHost".Trim()) {
        $now = Get-Date; $today = $now.ToString('yyyy-MM-dd')
        $pd = [datetime]::MinValue
        if (-not $state.pdSince -or -not [datetime]::TryParse("$($state.pdSince)", $Inv, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$pd)) { $state.pdSince = $now.ToString('o'); $pd = $now }
        $mins = [int]($now - $pd).TotalMinutes
        $backendUp = $false
        $bh = "$SystemResetHost".Trim(); $bp = 80
        if ($bh -match '^(.+):(\d+)$') { $bh = $Matches[1]; $bp = [int]$Matches[2] }
        try { $tc = New-Object Net.Sockets.TcpClient; $backendUp = $tc.ConnectAsync($bh, $bp).Wait(3000) -and $tc.Connected; $tc.Close() } catch {}
        if (-not $backendUp) {
            Write-Log "COM3000 page down $mins min - the backend ($SystemResetHost) does not answer either, so this PC may be off the network; no reset sent"
        } elseif ($state.sysResetAt) {
            $at = [datetime]::MinValue; [void][datetime]::TryParse("$($state.sysResetAt)", $Inv, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$at)
            if (($now - $at).TotalMinutes -ge 10) {
                Send-Alert 'COM3000 reset did not help' "The COM3000 page is still not reachable 10 minutes after the COM3000 reset at $($at.ToString('h:mm tt')). It needs a visit." 'urgent' 'rotating_light'
                $state.sysResetAt = ''; $state.sysResetSlots = ''
            }
        } elseif ($mins -lt $SystemResetMinutes) {
            Write-Log "COM3000 page down $mins min - whole COM3000 reset after $SystemResetMinutes min$(if ($state.sysResetDay -eq $today) { ' (but the one automatic reset for today is already used)' })"
        } elseif ($state.sysResetDay -eq $today) {
            if ($state.sysSkipDay -ne $today) {
                $state.sysSkipDay = $today
                Write-Log 'Whole COM3000 reset NOT sent: page down, but the automatic reset already ran today'
                Send-Alert 'COM3000 reset skipped' "The COM3000 page has been down $SystemResetMinutes+ min, but the automatic COM3000 reset already ran today (one per day). Use the Reset panel if it needs another." 'high' 'warning'
            }
        } else {
            $state.sysResetDay = $today
            try {
                Invoke-SystemReset
                $state.sysResetAt = $now.ToString('o'); $state.sysResetSlots = 'page'; $state.pdSince = ''
                Write-Log 'Whole COM3000 reset sent: COM3000 page not reachable'; Add-ResetHistory 'whole' 'page' 'auto'
                Send-Alert 'COM3000 reset sent' "The COM3000 page has been unreachable $SystemResetMinutes+ min (the card serving it may be out) - the whole COM3000 was reset. All channels will be off for several minutes; alerts are paused 10 minutes. (One automatic COM3000 reset per day.)" 'high' 'arrows_counterclockwise'
                Set-ResetPause 10
            } catch {
                Send-Alert 'COM3000 reset failed' "The COM3000 page is unreachable, but the COM3000 reset could not be sent: $(Get-CleanError $_)" 'urgent' 'rotating_light'
            }
        }
    }
    Send-Reminders $state $false
    Send-StatusReport $state @{ Page = 'down'; Via = ''; Paused = ''; Err = $pageErr; Cards = @(); Out = @(); Watched = 0 }
    Save-State $state
    if ($Test) { Write-Host "`nTest failed - see message above." -ForegroundColor Red }
    return
}

if ($state.failAlerted) {
    Send-Alert 'COM3000 reachable again' 'The COM3000 page is responding again.' 'default' 'white_check_mark'
}
$state.failCount = 0; $state.failAlerted = $false; $state.pdSince = ''

# remember the cards listed on the page (kept even if a card later disappears from
# the page, so a dead card still alerts), then check them.
# To forget a card that was removed for good, delete monitor-state.json.
if ($data.Slots.Count -gt 0 -or $data.QamIps.Count -gt 0) {
    foreach ($sl in $data.Slots) {
        if ($sl.Ip -notmatch '^\d+\.\d+\.\d+\.\d+$' -or $sl.Ip -eq '0.0.0.0') { continue }
        $label = "Card slot $($sl.Slot)"
        # if this slot used to be at a different address, forget the old one
        foreach ($old in @($state.devices.Keys)) {
            if ($state.devices[$old] -eq $label -and $old -ne $sl.Ip) { $state.devices.Remove($old); Clear-Item $state "card:$old" }
        }
        $state.devices[$sl.Ip] = $label
    }
}
# The QAM card lives on the COM3000's internal 192.168.6.x network, which this PC
# usually can't reach - so it isn't pinged. If it fails, every channel's bitrate
# drops to 0 and the channel alerts fire instead.
foreach ($ip in @($state.devices.Keys)) { if ($state.devices[$ip] -eq 'QAM card') { $state.devices.Remove($ip) } }
Invoke-DeviceChecks $state -Defer

# ---- Card status (the Status column: SWM error, tuners not registered) ----
$statusDown = New-Object System.Collections.ArrayList
$statusBack = New-Object System.Collections.ArrayList
$statusKeys = @{}
$statusText = @{ 1 = 'SWM error'; 2 = 'Not all tuners were registered' }
foreach ($sl in $data.Slots) {
    $key = "status:$($sl.Slot)"
    $statusKeys[$key] = $true
    $bad = $statusText.ContainsKey($sl.Err)
    $label = "Card slot $($sl.Slot) ($($sl.Ip)): $(if ($bad) { $statusText[$sl.Err] } else { 'OK' })"
    if ($Test) { Write-Host ("  Card slot {0} status: {1}" -f $sl.Slot, $(if ($bad) { $statusText[$sl.Err] } else { 'OK' })) -ForegroundColor $(if ($bad) { 'Red' } else { 'Gray' }) }
    switch (Update-Item $state $key $bad $label) {
        'down' { [void]$statusDown.Add($label) }
        'up'   { [void]$statusBack.Add("Card slot $($sl.Slot) ($($sl.Ip)) status back to OK (error since $($state.alerted[$key]))"); Clear-Item $state $key }
    }
}
foreach ($k in @($state.counts.Keys + $state.alerted.Keys)) { if ($k -like 'status:*' -and -not $statusKeys.ContainsKey($k)) { Clear-Item $state $k } }
if ($statusDown.Count -gt 0) { Send-Alert 'card error' ($statusDown -join "`n") 'urgent' 'rotating_light' }
if ($statusBack.Count -gt 0) { Send-Alert 'card error cleared' ($statusBack -join "`n") 'default' 'white_check_mark' }

# ---- Channels ----
$channels  = $data.Channels
$newlyOut  = New-Object System.Collections.ArrayList
$dropped   = New-Object System.Collections.ArrayList
$recovered = New-Object System.Collections.ArrayList
$changed   = New-Object System.Collections.ArrayList
$seen      = @{}
$slotWatched = @{}; $slotDown = @{}
$dashOut = New-Object System.Collections.ArrayList; $dashOutSlot = @{}; $script:DashLow = 0
$ignored   = 0
if ($Test) { Write-Host "`nChannels:" -ForegroundColor Cyan }

foreach ($c in $channels) {
    if (Test-Ignored $c) {
        $ignored++
        $state.names.Remove($c.Key)
        if ($Test) { Write-Host ("  {0,-6} {1,-20} {2,9}  (ignored)" -f $c.Virt, $c.Channel, $c.Rate) -ForegroundColor DarkGray }
        continue
    }
    $seen[$c.Key] = $true
    if ($state.missing.ContainsKey($c.Key)) {
        # this channel had gone missing (NA) and is back on the page - wait for the
        # same number of good checks as everything else before saying so
        $rk = "ret:$($c.Key)"
        $state.good[$rk] = [int]$state.good[$rk] + 1
        if ($state.good[$rk] -ge [Math]::Max(1, $ChecksToRecover)) {
            [void]$recovered.Add("Ch $($c.Virt)  $($c.Channel) is back on the COM3000 (missing since $($state.missing[$c.Key]))")
            $state.missing.Remove($c.Key)
            $state.good.Remove($rk)
        }
    }
    if ($c.NoChannel) {
        # the page still holds the channel the tuner had; fall back to the last name we saw
        $was = if ($c.Was -match '^\d+\s+\S') { $c.Was } elseif ($state.names[$c.Key]) { $state.names[$c.Key] } else { $c.Was }
        $c.Channel = if ($was) { "NO CHANNEL SELECTED (was $was)" } else { 'NO CHANNEL SELECTED' }
    } else {
        # A real change = the DIRECTV channel NUMBER changed (e.g. 202 -> 360), seen on 2 checks
        # in a row. A blank/different name on the same number is just the COM3000 refreshing.
        $old    = $state.names[$c.Key]
        $oldNum = if ($old -match '^(\d+)') { $Matches[1] } else { '' }
        $newNum = if ($c.Channel -match '^(\d+)') { $Matches[1] } else { '' }
        $hasName = $c.Channel -match '^\d+\s+\S'
        if ($old -and $oldNum -and $newNum -and $oldNum -ne $newNum) {
            # must hold for the same delay as other alerts ($MinutesBeforeAlert, at least 2 checks)
            $p = "$($state.pending[$c.Key])" -split '\|'
            $n = if ($p[0] -eq $newNum) { [int]$p[1] + 1 } else { 1 }
            if ($n -ge [Math]::Max(2, $ChecksToAlert)) {
                $where = if ($c.Slot) { " - slot $($c.Slot) tuner $($c.Tuner)" } else { '' }
                [void]$changed.Add("Ch $($c.Virt)  $old -> $($c.Channel)$where")
                $state.names[$c.Key] = $c.Channel
                $state.pending.Remove($c.Key)
            } else {
                $state.pending[$c.Key] = "$newNum|$n"     # not sure yet - keep watching
            }
        } else {
            $state.pending.Remove($c.Key)
            # same channel number: keep the stored name unless we now have a better one
            if (-not $old -or ($hasName -and $old -ne $c.Channel)) { $state.names[$c.Key] = $c.Channel }
            elseif (-not $hasName) { $c.Channel = $old }
        }
    }
    $label = Get-ChannelLabel $c
    $down  = $c.NoChannel -or $c.Mbps -lt $MinMbps
    $state.slotOf[$c.Key] = "$($c.Slot)"
    $slotWatched["$($c.Slot)"] = [int]$slotWatched["$($c.Slot)"] + 1
    if ($down -and -not $c.NoChannel) { $slotDown["$($c.Slot)"] = [int]$slotDown["$($c.Slot)"] + 1 }
    if ($Test) {
        Write-Host ("  {0,-6} {1,-20} {2,9}  SNR {3,-3} slot {4} tuner {5}" -f $c.Virt, $c.Channel, $c.Rate, $c.Snr, $c.Slot, $c.Tuner) -ForegroundColor $(if ($down) { 'Red' } else { 'Gray' })
    }
    switch (Update-Item $state $c.Key $down $label) {
        'down' { if ($c.NoChannel) { [void]$dropped.Add($label) } else { [void]$newlyOut.Add([pscustomobject]@{ Label = $label; Short = "$($c.Virt) $($c.Channel)"; Slot = "$($c.Slot)"; Key = $c.Key }) } }
        'up'   {
            if ($state.held.ContainsKey($c.Key)) { Write-Log "Back (no alert was sent - only a few channels were out): $label" }
            else { [void]$recovered.Add("$label (out since $($state.alerted[$c.Key]))") }
            Clear-Item $state $c.Key
        }
    }
    if ($state.alerted.ContainsKey($c.Key)) {
        # say WHY: no channel picked on the tuner, or just a low bitrate (often a blacked-out game)
        $why = if ($c.NoChannel) { '' } else { " - low bitrate ($($c.Rate))" }
        [void]$dashOut.Add("$($c.Virt) $($c.Channel)$why"); $dashOutSlot["$($c.Slot)"] = [int]$dashOutSlot["$($c.Slot)"] + 1
        if (-not $c.NoChannel) { $script:DashLow++ }
    }
}

if ($changed.Count -gt 0 -and $ChannelChanges -ne 'off') {
    $t = if ($changed.Count -eq 1) { 'channel changed' } else { "$($changed.Count) channels changed" }
    Send-Alert $t ($changed -join "`n") 'low' 'arrows_counterclockwise' -LogOnly:($ChannelChanges -eq 'log')
}

if ($dropped.Count -gt 0) {
    $t = if ($dropped.Count -eq 1) { 'channel removed' } else { "$($dropped.Count) channels removed" }
    Send-Alert $t (($dropped -join "`n") + "`nNo channel is selected on this tuner - DIRECTV may have dropped it from the lineup.") 'urgent' 'rotating_light'
}

# Channels we were watching that are no longer on the page (tuner set to unused / NA,
# or its card dropped out): alert once, then stop tracking them.
$missing = New-Object System.Collections.ArrayList
foreach ($k in @($state.missing.Keys)) { if (-not $seen.ContainsKey($k)) { $state.good.Remove("ret:$k") } }
foreach ($k in @($state.names.Keys)) {
    if ($seen.ContainsKey($k)) { continue }
    $sl = "$($state.slotOf[$k])"
    $slotWatched[$sl] = [int]$slotWatched[$sl] + 1
    $slotDown[$sl]    = [int]$slotDown[$sl] + 1
    $state.counts[$k] = [int]$state.counts[$k] + 1
    if ($state.counts[$k] -ge $ChecksToAlert) {
        $virt = ($k -replace '^ch:', '') -replace '#\d+$', ''
        [void]$missing.Add([pscustomobject]@{ Label = "Ch $virt  $($state.names[$k]) - no longer on the COM3000"; Short = "$virt $($state.names[$k])"; Slot = $sl; Missing = $true })
        $state.missing[$k] = (Get-Date -Format 'MM/dd h:mm tt')
        Clear-Item $state $k
        $state.names.Remove($k)
    }
}
foreach ($k in @($state.slotOf.Keys)) { if (-not $seen.ContainsKey($k) -and -not $state.names.ContainsKey($k)) { $state.slotOf.Remove($k) } }
# tidy up anything else that is no longer on the page
foreach ($k in @($state.counts.Keys + $state.alerted.Keys)) { if ($k -like 'ch:*' -and -not $seen.ContainsKey($k) -and -not $state.names.ContainsKey($k)) { Clear-Item $state $k } }

# ---- Work out WHY things are out, then send one message ----
#   - a card that stopped answering        -> "Card slot 2 is offline - 16 channels affected"
#   - most of ONE card's channels out       -> card or its satellite feed
#   - most channels out on EVERY card       -> satellite signal (weather / dish), not a card
$slotIp = @{}
foreach ($ip in $state.devices.Keys) { if ($state.devices[$ip] -match '^Card slot (\S+)$') { $slotIp[$Matches[1]] = $ip } }
$onPage = @{}; foreach ($sl in $data.Slots) { $onPage["$($sl.Slot)"] = $true }
function Test-SlotDown([string]$Sl) {
    $ip = $slotIp[$Sl]
    if ($ip -and $script:CardUp.ContainsKey($ip) -and -not $script:CardUp[$ip]) { return $true }
    return ($ip -and -not $onPage.ContainsKey($Sl))
}
# ---- Only a few channels out: hold the alert (no phone) unless $MinChannelsOut+ are out at once,
#      or one of them stays out $FewChannelsMinutes minutes. A card/satellite problem always alerts.
$cardTrouble = $script:CardDownNew.Count -gt 0 -or @($slotWatched.Keys | Where-Object { Test-SlotDown $_ }).Count -gt 0
$nOutNow = @($state.alerted.Keys | Where-Object { $_ -like 'ch:*' }).Count
$minOut = [Math]::Max(1, [int]$MinChannelsOut)

# ---- Rain fade: channels dropping on 3+ cards (or every card) while all the cards are answering ----
#      No phone alerts while it lasts (and for 30 min after), no card resets. Only if it goes on
#      $RainFadeHours hours: one alert, because then it's probably the dish / LNB / cable, not rain.
$parseRT = { param($t) $d = [datetime]::MinValue; [void][datetime]::TryParse("$t", $Inv, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$d); $d }
$downSlots = @($slotDown.Keys | Where-Object { [int]$slotDown[$_] -gt 0 }).Count
$totDownNow = 0; foreach ($sl in $slotDown.Keys) { $totDownNow += [int]$slotDown[$sl] }
$rainPattern = (-not $cardTrouble) -and $slotWatched.Count -ge 2 -and $totDownNow -ge 3 -and $downSlots -ge [Math]::Min(3, $slotWatched.Count)
$nowR = Get-Date
if ($rainPattern) {
    if (-not $state.rainSince) { $state.rainSince = $nowR.ToString('o'); Write-Log "Rain fade / weak signal: $totDownNow channels dropping on $downSlots cards, cards all answering - no phone alerts while it lasts." }
    $state.rainLast = $nowR.ToString('o')
}
$script:RainMode = (-not $cardTrouble) -and $state.rainSince -and (($nowR - (& $parseRT $state.rainLast)).TotalMinutes -lt 30)
if ($state.rainSince -and -not $script:RainMode -and -not $cardTrouble) {
    Write-Log "Rain fade over (signal normal for 30 min) - it started $((& $parseRT $state.rainSince).ToString('h:mm tt')). Normal alerts again."
    $state.rainSince = ''; $state.rainLast = ''; $state.rainAlerted = ''
}

if ($script:RainMode) {
    foreach ($e in @($newlyOut)) { $state.held[$e.Key] = $nowR.ToString('o'); Write-Log "Out (rain fade - no alert): $($e.Label)" }
    $newlyOut = New-Object System.Collections.ArrayList
    $rainHrs = ($nowR - (& $parseRT $state.rainSince)).TotalHours
    if ([double]$RainFadeHours -gt 0 -and $rainHrs -ge [double]$RainFadeHours -and -not $state.rainAlerted -and $nOutNow -ge $minOut) {
        $state.rainAlerted = $nowR.ToString('o')
        $outNames = @($state.alerted.Keys | Where-Object { $_ -like 'ch:*' } | ForEach-Object { "$($_ -replace '^ch:', '' -replace '#\d+$', '') $($state.names[$_])".Trim() } | Sort-Object { [int]($_ -replace '-.*$', '') })
        Send-Alert 'satellite signal problem' ("Channels have been dropping on several cards for $([int]$RainFadeHours)+ hours (since $((& $parseRT $state.rainSince).ToString('h:mm tt'))) - longer than rain usually lasts. Check the dish, LNB and cables.`nOut now ($($outNames.Count)): " + ($outNames -join ', ')) 'high' 'satellite'
    }
} elseif (-not $cardTrouble -and $nOutNow -lt $minOut) {
    foreach ($e in @($newlyOut)) { $state.held[$e.Key] = (Get-Date).ToString('o'); Write-Log "Out, holding the alert (only $nOutNow channel$(if ($nOutNow -ne 1) { 's' }) out): $($e.Label)" }
    $newlyOut = New-Object System.Collections.ArrayList
    # still out after $FewChannelsMinutes: alert after all
    if ([int]$FewChannelsMinutes -gt 0) {
        foreach ($k in @($state.held.Keys)) {
            $t = [datetime]::MinValue; [void][datetime]::TryParse("$($state.held[$k])", $Inv, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$t)
            if (((Get-Date) - $t).TotalMinutes -ge [int]$FewChannelsMinutes -and $state.alerted.ContainsKey($k)) {
                $lb = if ($state.labels[$k]) { $state.labels[$k] } else { $k -replace '^ch:', 'Ch ' }
                [void]$newlyOut.Add([pscustomobject]@{ Label = "$lb - out $(if ([int]$FewChannelsMinutes % 60 -eq 0) { "$([int]$FewChannelsMinutes / 60)+ hours" } else { "$([int]$FewChannelsMinutes)+ min" })"; Short = ("$($k -replace '^ch:', '' -replace '#\d+$', '') $($state.names[$k])").Trim(); Slot = "$($state.slotOf[$k])"; Key = $k })
                $state.held.Remove($k)
            }
        }
    }
} elseif ($state.held.Count) {
    # enough channels out now (or a card problem): include the ones that were being held
    foreach ($k in @($state.held.Keys)) {
        if ($state.alerted.ContainsKey($k) -and -not @($newlyOut | Where-Object { $_.Key -eq $k }).Count) {
            $lb = if ($state.labels[$k]) { $state.labels[$k] } else { $k -replace '^ch:', 'Ch ' }
            [void]$newlyOut.Add([pscustomobject]@{ Label = $lb; Short = ("$($k -replace '^ch:', '' -replace '#\d+$', '') $($state.names[$k])").Trim(); Slot = "$($state.slotOf[$k])"; Key = $k })
        }
        $state.held.Remove($k)
    }
}
$events  = @(@($newlyOut) + @($missing) | Sort-Object { [int]($_.Short -replace '-.*$', '') })
$badSlot = @{}
foreach ($sl in $slotWatched.Keys) {
    if ($slotWatched[$sl] -ge 2 -and ([int]$slotDown[$sl] / $slotWatched[$sl]) -ge 0.75) { $badSlot[$sl] = $true }
}
$anyCardDown = @($slotWatched.Keys | Where-Object { Test-SlotDown $_ }).Count -gt 0
$weather = (($slotWatched.Count -ge 2) -and ($badSlot.Count -eq $slotWatched.Count) -and -not $anyCardDown) -or $script:RainMode

if ($events.Count -gt 0 -or $script:CardDownNew.Count -gt 0) {
    $lines = New-Object System.Collections.ArrayList
    $title = ''
    if ($weather -and $events.Count -gt 0) {
        $totDown = 0; $totAll = 0
        foreach ($sl in $slotWatched.Keys) { $totDown += [int]$slotDown[$sl]; $totAll += $slotWatched[$sl] }
        $title = 'satellite signal problem?'
        [void]$lines.Add("$totDown of $totAll channels are out on ALL cards, and the cards are still answering - most likely weather or the dish/LNB, not a card.")
        [void]$lines.Add("Out: " + (($events | ForEach-Object { $_.Short }) -join ', '))
    } else {
        $handled = @{}
        foreach ($sl in ($slotWatched.Keys + @($slotIp.Keys) | Sort-Object -Unique)) {
            $slEvents = @($events | Where-Object { $_.Slot -eq $sl })
            $ip = $slotIp[$sl]
            $newCard = $ip -and ($script:CardDownNew -contains $ip)
            if (Test-SlotDown $sl) {
                if (-not $newCard -and $slEvents.Count -eq 0) { continue }
                $n = [int]$slotDown[$sl]
                $affect = if ($n -gt 0) { " - $n channel$(if ($n -ne 1) { 's' }) affected" } else { " (not answering on the network; its channels still show video on the COM3000)" }
                [void]$lines.Add("Card slot $sl ($ip) is offline$affect")
                if ($slEvents.Count -gt 0) { [void]$lines.Add("   " + (($slEvents | ForEach-Object { $_.Short }) -join ', ')) }
                if (-not $title) { $title = 'card offline' }
            } elseif ($badSlot.ContainsKey($sl) -and $slEvents.Count -ge 2) {
                [void]$lines.Add("Card slot $sl$(if ($ip) { " ($ip)" }): $([int]$slotDown[$sl]) of $($slotWatched[$sl]) channels out - the card is answering, so check that card and its satellite feed")
                [void]$lines.Add("   " + (($slEvents | ForEach-Object { $_.Short }) -join ', '))
                if (-not $title) { $title = 'card problem?' }
            } else { continue }
            foreach ($e in $slEvents) { $handled[$e.Short] = $true }
        }
        # other devices from $Cards that went offline
        foreach ($ip in $script:CardDownNew) {
            if ($slotIp.Values -contains $ip) { continue }
            [void]$lines.Add("$($Cards[$ip]) ($ip) is offline")
            if (-not $title) { $title = 'device offline' }
        }
        $rest = @($events | Where-Object { -not $handled.ContainsKey($_.Short) })
        foreach ($e in $rest) { [void]$lines.Add($e.Label) }
        if (@($rest | Where-Object { $_.Missing }).Count -gt 0) {
            [void]$lines.Add("(Missing = the tuner is set to unused (NA) or its card dropped out. You'll get a message if it comes back.)")
        }
        if (-not $title) {
            $nOut = @($rest | Where-Object { -not $_.Missing }).Count; $nMiss = $rest.Count - $nOut
            $title = if ($nOut -eq 0) { if ($nMiss -eq 1) { 'channel missing' } else { "$nMiss channels missing" } } elseif ($rest.Count -eq 1) { 'channel out' } else { "$($rest.Count) channels out" }
        } elseif ($script:CardDownNew.Count -gt 1) { $title = "$($script:CardDownNew.Count) cards offline" }
    }
    if ($lines.Count -gt 0) {
        # a single channel out (nothing else) is a normal alert, not an urgent one
        $single = ($title -eq 'channel out' -and $lines.Count -eq 1)
        if ($single) { Send-Alert $title ($lines -join "`n") 'default' 'warning' } else { Send-Alert $title ($lines -join "`n") 'urgent' 'rotating_light' }
    }
}

$backLines = @($script:CardBack) + @($recovered)
if ($backLines.Count -gt 0) {
    if ($recovered.Count -gt 8) {
        # keep big recoveries short: one line with the channel list
        $short = $recovered | ForEach-Object { if ($_ -match '^Ch (\S+)\s+(.+?)\s+(\(|is back)') { "$($Matches[1]) $($Matches[2])" } else { $_ } }
        $backLines = @($script:CardBack) + @("$($recovered.Count) channels back: " + ($short -join ', '))
    }
    $title = if ($script:CardBack.Count -gt 0) { if ($script:CardBack.Count -eq 1) { 'card back online' } else { "$($script:CardBack.Count) cards back online" } }
             elseif ($recovered.Count -eq 1) { 'channel back' } else { "$($recovered.Count) channels back" }
    Send-Alert $title ($backLines -join "`n") 'default' 'white_check_mark'
}

# ---- Automatic card reset: card still there, but no video on its channels ----
if (-not $ReadOnly -and -not $Test -and $CardResetMinutes -gt 0) {
    $now = Get-Date; $today = $now.ToString('yyyy-MM-dd')
    $parseT = { param($t) $d = [datetime]::MinValue; [void][datetime]::TryParse("$t", $Inv, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$d); $d }
    foreach ($sl in @($slotWatched.Keys | Sort-Object)) {
        $ip = $slotIp[$sl]
        if (-not $ip) { continue }
        $noVideo = $badSlot.ContainsKey($sl) -and -not $weather -and -not (Test-SlotDown $sl)
        # follow up on a reset that was sent
        if ($state.resetAt[$sl]) {
            $at = & $parseT $state.resetAt[$sl]
            if (-not $noVideo) {
                Send-Alert 'card back after reset' "Card slot $sl ($ip) has video again after the reset at $($at.ToString('h:mm tt'))." 'default' 'white_check_mark'
                $state.resetAt.Remove($sl); $state.nvSince.Remove($sl)
            } elseif (($now - $at).TotalMinutes -ge 10) {
                Send-Alert 'card reset did not help' "Card slot $sl ($ip) still has no video 10 minutes after the reset. It needs a visit." 'urgent' 'rotating_light'
                $state.resetAt.Remove($sl)
            }
            continue
        }
        if (-not $noVideo) { $state.nvSince.Remove($sl); continue }
        if (-not $state.nvSince[$sl]) { $state.nvSince[$sl] = $now.ToString('o'); continue }
        $mins = [int]($now - (& $parseT $state.nvSince[$sl])).TotalMinutes
        if ($mins -lt $CardResetMinutes) { Write-Log "Card slot $sl ($ip) no video $mins min - card reset after $CardResetMinutes min$(if ($state.resetDay[$sl] -eq $today) { ' (but its one automatic reset for today is already used)' })"; continue }
        if ($state.resetDay[$sl] -eq $today) {      # one automatic reset per card per day
            if ($state.resetDay["skip$sl"] -ne $today) { $state.resetDay["skip$sl"] = $today; Write-Log "Card reset NOT sent: slot $sl ($ip) no video, but its automatic reset already ran today"; Send-Alert 'card reset skipped' "Card slot $sl ($ip) has had no video for $mins min, but its automatic reset already ran today (one per card per day). Use the Reset panel if it needs another." 'high' 'warning' }
            continue
        }
        $state.resetDay[$sl] = $today
        if (-not "$CardResetCommand".Trim()) {
            Send-Alert 'card reset (practice)' "Card slot $sl ($ip) has had no video for $mins min. An automatic card reset would be sent now - the reset command isn't set up yet, so nothing was done." 'high' 'test_tube'
            continue
        }
        $url = $CardResetCommand -replace '\{ip\}', $ip -replace '\{slot\}', $sl -replace '\{com\}', (Get-ComIp)
        try {
            [void](Get-PageHtml $url)
            $state.resetAt[$sl] = $now.ToString('o')
            Write-Log "Card reset sent: slot $sl ($ip) - $url"; Add-ResetHistory 'card' $sl 'auto'
            Send-Alert 'card reset sent' "Card slot $sl ($ip) had no video for $mins min - reset sent. (One automatic reset per card per day.)" 'high' 'arrows_counterclockwise'
        } catch {
            Send-Alert 'card reset failed' "Card slot $sl ($ip) has no video, but the reset could not be sent: $(Get-CleanError $_)" 'urgent' 'rotating_light'
        }
    }
}

# ---- Automatic whole COM3000 reset: a card is GONE (not answering / missing from the COM3000) ----
if (-not $ReadOnly -and -not $Test) {
    $now = Get-Date; $today = $now.ToString('yyyy-MM-dd')
    $parseT = { param($t) $d = [datetime]::MinValue; [void][datetime]::TryParse("$t", $Inv, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$d); $d }
    # follow up on a reset that was sent (runs once the 10-minute quiet period is over)
    if ($state.sysResetAt) {
        $at = & $parseT $state.sysResetAt
        if (($now - $at).TotalMinutes -ge 10) {
            if ("$($state.sysResetSlots)" -eq 'page') { Send-Alert 'back after COM3000 reset' "The COM3000 page is back after the COM3000 reset at $($at.ToString('h:mm tt'))." 'default' 'white_check_mark' }
            $slots = @("$($state.sysResetSlots)" -split ',' | Where-Object { $_ -and $_ -ne 'page' })
            $still = @($slots | Where-Object { Test-SlotDown $_ })
            $back  = @($slots | Where-Object { $still -notcontains $_ })
            if ($back.Count)  { Send-Alert 'back after COM3000 reset' ("Card slot " + ($back -join ', ') + " is back after the COM3000 reset at $($at.ToString('h:mm tt')).") 'default' 'white_check_mark' }
            if ($still.Count) { Send-Alert 'COM3000 reset did not help' ("Card slot " + ($still -join ', ') + " is still missing 10 minutes after the COM3000 reset. It needs a visit.") 'urgent' 'rotating_light' }
            $state.sysResetAt = ''; $state.sysResetSlots = ''
        }
    } elseif (-not ($SystemResetMinutes -gt 0 -and "$SystemResetHost".Trim())) {
        $downNow = @($slotIp.Keys | Where-Object { Test-SlotDown $_ })
        if ($downNow.Count) { Write-Log ("Card slot " + ($downNow -join ', ') + " missing - automatic COM3000 reset is OFF (" + $(if (-not "$SystemResetHost".Trim()) { 'backend not set up' } else { 'minutes = 0' }) + ")") }
    } else {
        $gone = @()
        foreach ($sl in @($slotIp.Keys | Sort-Object)) {
            if (Test-SlotDown $sl) {
                if (-not $state.gnSince[$sl]) { $state.gnSince[$sl] = $now.ToString('o') }
                elseif (($now - (& $parseT $state.gnSince[$sl])).TotalMinutes -ge $SystemResetMinutes) { $gone += $sl }
            } else { $state.gnSince.Remove($sl) }
        }
        foreach ($sl in @($state.gnSince.Keys)) {
            if ($gone -contains $sl) { continue }
            $mins = [int]($now - (& $parseT $state.gnSince[$sl])).TotalMinutes
            Write-Log "Card slot $sl missing $mins min - whole COM3000 reset after $SystemResetMinutes min$(if ($state.sysResetDay -eq $today) { ' (but the one automatic reset for today is already used)' })"
        }
        if ($gone.Count -and $state.sysResetDay -eq $today -and $state.sysSkipDay -ne $today) {
            $state.sysSkipDay = $today
            Write-Log "Whole COM3000 reset NOT sent: card slot $($gone -join ', ') missing, but the automatic reset already ran today"
            Send-Alert 'COM3000 reset skipped' ("Card slot " + ($gone -join ', ') + " has been missing $SystemResetMinutes+ min, but the automatic COM3000 reset already ran today (one per day). Use the Reset panel if it needs another.") 'high' 'warning'
        }
        if ($gone.Count -and $state.sysResetDay -ne $today) {
            $state.sysResetDay = $today
            try {
                Invoke-SystemReset
                $state.sysResetAt = $now.ToString('o'); $state.sysResetSlots = ($gone -join ',')
                foreach ($sl in $gone) { $state.gnSince.Remove($sl) }
                Write-Log "Whole COM3000 reset sent: card slot $($gone -join ', ') missing"; Add-ResetHistory 'whole' ($gone -join ' ') 'auto'
                Send-Alert 'COM3000 reset sent' ("Card slot " + ($gone -join ', ') + " missing $SystemResetMinutes+ min - the whole COM3000 was reset. All channels will be off for several minutes; alerts are paused 10 minutes. (One automatic COM3000 reset per day.)") 'high' 'arrows_counterclockwise'
                Set-ResetPause 10
            } catch {
                Send-Alert 'COM3000 reset failed' ("Card slot " + ($gone -join ', ') + " is missing, but the COM3000 reset could not be sent: $(Get-CleanError $_)") 'urgent' 'rotating_light'
            }
        }
    }
}

Send-Reminders $state $true

$outNow = @($state.alerted.Keys | ForEach-Object { $_ -replace '^(ch|card|status):', '' })
Write-Log ("OK - {0} channels watched, {1} ignored, out: {2}" -f $seen.Count, $ignored, $(if ($outNow) { $outNow -join ', ' } else { 'none' }))
# ---- Daily backup (and a backup on every -Test) ----
if (-not $ReadOnly -and $BackupTime -ne 'off') {
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $due = $false
    $bt = [datetime]::MinValue
    if ([datetime]::TryParseExact("$today $BackupTime", 'yyyy-MM-dd HH:mm', $Inv, [Globalization.DateTimeStyles]::None, [ref]$bt)) {
        $due = ((Get-Date) -ge $bt) -and ($state.lastBackup -ne $today)
    }
    if ($Test -or $due) {
        if ($Test) { Write-Host "`nBacking up TuneAll and EPG..." -ForegroundColor Cyan }
        try {
            $b = Invoke-Backup
            # only the scheduled run counts as "today's backup" - a test backup doesn't replace it
            if ($due) { $state.lastBackup = $today; $state.backupFails = 0 }
            Write-Log "Backup saved: $($b.File) ($($b.TuneLines) tune lines, $($b.EpgLines) EPG lines)"
            if ($Test) { Write-Host "  Saved $($b.TuneLines) Tune all lines and $($b.EpgLines) EPG lines to:`n  $($b.File)" -ForegroundColor Green }
            $started = Start-DriveCopy
            if ($Test) {
                if ($started) { Write-Host '  Google Drive copy started - check Drive in a minute or two.' }
                else { Write-Host '  Google Drive copy is not set up yet (it is set up when the monitor is installed).' -ForegroundColor Yellow }
            }
        } catch {
            if ($due) { $state.backupFails++ }
            $err = Get-CleanError $_
            Write-Log "Backup failed ($($state.backupFails)): $err"
            if ($Test) { Write-Host "  Backup FAILED: $err" -ForegroundColor Red }
            if (-not $Test -and $state.backupFails -ge 3 -and $state.backupAlerted -ne $today) {
                Send-Alert 'backup failed' "Today's TuneAll/EPG backup could not be saved after $($state.backupFails) tries.`n$err`nIt will keep trying." 'high' 'floppy_disk'
                $state.backupAlerted = $today
            }
        }
    }
}

# ---- Daily EPG refresh: re-press Submit on the EPG page(s), in the background ----
if ($script:EpgSubmitEnabled -and -not $ReadOnly -and -not $Test -and "$EpgRefreshTime" -match '^\d\d:\d\d$') {
    $now = Get-Date; $today = $now.ToString('yyyy-MM-dd')
    $et = [datetime]::ParseExact("$today $EpgRefreshTime", 'yyyy-MM-dd HH:mm', $Inv)
    $nx = [datetime]::MinValue; [void][datetime]::TryParse("$($state.epgRefNext)", $Inv, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$nx)
    if ($now -ge $et -and $state.epgRefDay -ne $today -and $now -ge $nx) {
        Set-Step 'refreshing the EPG'
        $res = @(Invoke-EpgRefresh)
        $bad = @($res | Where-Object { -not $_.Ok })
        if ($res.Count -and -not $bad) {
            $state.epgRefDay = $today; $state.epgRefFails = 0; $state.epgRefNext = ''; $state.epgRefAt = $now.ToString('o'); $state.epgRefOk = 'ok'
            Write-Log ("EPG refreshed: " + (($res | ForEach-Object { "$($_.Host) ($($_.Lines) lines)" }) -join ', '))
        } else {
            $state.epgRefFails++
            $why = if ($bad) { ($bad | ForEach-Object { $_.Err }) -join "`n" } else { 'No blade with an EPG list was found.' }
            Write-Log "EPG refresh failed (try $($state.epgRefFails)): $($why -replace "`n", ' / ')"
            if ($state.epgRefFails -ge 2) {
                # tried twice, 5 minutes apart: tell someone, then leave it until tomorrow
                Send-Alert 'EPG refresh failed' "This morning's EPG refresh didn't work:`n$why`nAEP boxes may be missing guide info - check the EPG page." 'high' 'warning'
                $state.epgRefDay = $today; $state.epgRefFails = 0; $state.epgRefNext = ''; $state.epgRefAt = $now.ToString('o'); $state.epgRefOk = 'failed'
            } else {
                $state.epgRefNext = $now.AddMinutes(5).ToString('o')        # try again in 5 minutes
            }
        }
    }
}

# report to the COM3000 Dashboard
Set-Step 'sending the dashboard report'
try {
    $dashCards = @(foreach ($sl in @($slotIp.Keys | Sort-Object { [int]("$_" -replace '\D', '') })) {
        [ordered]@{ s = "$sl"; ip = $slotIp[$sl]; up = (-not (Test-SlotDown $sl)); n = [int]$slotWatched["$sl"]; out = [int]$dashOutSlot["$sl"] }
    })
    # ---- EPG check for the dashboard (every 30 min): which channels the EPG has wrong - no phone alert ----
    if (-not $Test) {
        $lastEpgChk = [datetime]::MinValue; [void][datetime]::TryParse("$($state.epgCheckAt)", $Inv, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$lastEpgChk)
        if (((Get-Date) - $lastEpgChk).TotalMinutes -ge 30) {
            Set-Step 'checking the EPG against the Overview'
            $state.epgCheckAt = (Get-Date).ToString('o'); Save-State $state      # saved now: if this gets stuck, it isn't retried every minute
            $epgDeadline = (Get-Date).AddSeconds(90)
            try {
                $epgHost = if ("$EpgIp".Trim()) { "$EpgIp".Trim() } else { Get-ComIp }
                $bladeEpgs = @{}
                foreach ($h in @(@($epgHost) + @(Get-ComHosts) | Where-Object { $_ } | Select-Object -Unique)) {
                    if ((Get-Date) -gt $epgDeadline) { Write-Log 'EPG check: blades too slow - skipped the rest this time.'; break }
                    if (-not (Test-HostPort $h)) { continue }
                    try { $bladeEpgs[$h] = Get-PageHtml "http://$h/cgi-bin/webcmd?screen=EpgDisplay" } catch {}
                }
                if ($bladeEpgs.ContainsKey($epgHost)) {
                    $epgCh = Get-PickerChannels $html $bladeEpgs[$epgHost]
                    Set-PickerBladeChecks $epgCh $html $bladeEpgs
                    $bad = @($epgCh | Where-Object { $_.Guide -eq 'X' })
                    $state.epgBad = $bad.Count
                    $state.epgBadList = (@($bad | Select-Object -First 12 | ForEach-Object { "$($_.Virt) $($_.Name)".Trim() }) -join ', ')
                    if ($bad.Count) { Write-Log "EPG check: $($bad.Count) channel(s) wrong in the EPG: $($state.epgBadList)" }
                }
            } catch { Write-Log "EPG check skipped: $(Get-CleanError $_)" }
        }
    }
    Send-StatusReport $state @{ Page = 'ok'; Via = $script:ComHostNow; Paused = ''; Err = ''; Cards = $dashCards; Out = @($dashOut); Low = $script:DashLow; Watched = $seen.Count }
} catch { Write-Log "Dashboard report skipped: $(Get-CleanError $_)" }

Save-State $state

if ($Status) {
    Write-Host "`nWatching $($seen.Count) channels ($ignored ignored) on $($data.TunerCount) tuners - unused tuners (NA) are skipped. Red = under $MinMbps Mbps right now." -ForegroundColor Cyan
} elseif ($Test) {
    Write-Host "`nRead $($channels.Count) channels on $($data.TunerCount) tuners (unused tuners skipped). Anything under $MinMbps Mbps is shown in red." -ForegroundColor Cyan
    Send-Alert 'monitor test' "Test from $env:COMPUTERNAME - watching $($seen.Count) channels." 'default' 'test_tube'
    Write-Host 'A test notification was sent - check your phone.' -ForegroundColor Cyan
}
# ---- END OF COM3000 MONITOR ----   (the self-update checks for this line, so it knows the file arrived complete)
