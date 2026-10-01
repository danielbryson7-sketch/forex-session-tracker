param(
  [switch]$Once,
  [switch]$DryRun,
  [switch]$TestSend,
  [ValidateRange(5,300)][int]$PollSeconds = 20,
  [string]$LedgerPath = (Join-Path $PSScriptRoot 'data/paper-ledger-v2.json'),
  [string]$StatePath = (Join-Path $PSScriptRoot 'data/slack-v2-state.json')
)

$ErrorActionPreference = 'Stop'
$nyZone = [TimeZoneInfo]::FindSystemTimeZoneById('America/New_York')
$script:slackWebhookUrl = [string]$env:SLACK_WEBHOOK_URL
$privatePath = Join-Path $PSScriptRoot 'slack-credentials.local.ps1'
if (Test-Path $privatePath) { . $privatePath }
if (-not $DryRun -and ($script:slackWebhookUrl -notmatch '^https://hooks\.slack\.com/services/[^/]+/[^/]+/[^/]+$')) {
  throw 'Set a Slack incoming webhook in the ignored slack-credentials.local.ps1 file or SLACK_WEBHOOK_URL.'
}

function Format-NyTime($Value) {
  if (-not $Value) { return 'unknown time' }
  return [TimeZoneInfo]::ConvertTime([DateTimeOffset]::Parse([string]$Value),$nyZone).ToString('MM/dd HH:mm') + ' NY'
}

function Format-Price([string]$Pair,$Value) {
  $digits = if ($Pair.EndsWith('/JPY')) { 3 } else { 5 }
  return ([double]$Value).ToString("F$digits",[Globalization.CultureInfo]::InvariantCulture)
}

function Send-Slack([string]$Message) {
  if ($DryRun) { Write-Host "DRY RUN: $Message"; return }
  $body = @{ text = $Message } | ConvertTo-Json -Compress -Depth 4
  $result = Invoke-WebRequest -Uri $script:slackWebhookUrl -Method Post -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 20 -UseBasicParsing
  if ($result.StatusCode -ne 200 -or [string]$result.Content -ne 'ok') { throw 'Slack did not accept the notification.' }
}

function Save-State($State) {
  if ($DryRun) { return }
  $directory = Split-Path -Parent $StatePath
  [IO.Directory]::CreateDirectory($directory) | Out-Null
  $temporary = "$StatePath.$PID.tmp"
  [IO.File]::WriteAllText($temporary,($State | ConvertTo-Json -Compress -Depth 8),[Text.UTF8Encoding]::new($false))
  [IO.File]::Move($temporary,$StatePath,$true)
}

function Read-Ledger {
  if (-not (Test-Path $LedgerPath)) { throw "V2 ledger is missing: $LedgerPath" }
  $ledger = Get-Content -Raw $LedgerPath | ConvertFrom-Json -AsHashtable -DateKind String
  if ($ledger.version -ne 2) { throw 'Slack notifier expected the V2 paper ledger.' }
  return $ledger
}

function Get-Snapshot($Ledger) {
  $closed = @{}
  foreach ($trade in @($Ledger.trades)) {
    if ($trade.origin -ne 'live') { continue }
    $key = "$($trade.pair)|$($trade.entryTime)|$($trade.exitTime)"
    $closed[$key] = $trade
  }
  $open = @{}
  $armed = @{}
  foreach ($pair in @($Ledger.pairs.Keys)) {
    if ($pair -notmatch '^[A-Z]{3}/[A-Z]{3}$') { continue }
    $entry = $Ledger.pairs[$pair]
    if ($entry.position -and $entry.position.origin -eq 'live') {
      $key = "$pair|$($entry.position.entryTime)"
      $open[$key] = $entry.position
    }
    if ($entry.pending -and -not $entry.position) {
      $key = "$pair|$($entry.pending.signalTime)"
      $armed[$key] = @{ pair=$pair; pending=$entry.pending }
    }
  }
  return @{ closed=$closed; open=$open; armed=$armed }
}

function Message-Arm([string]$Pair,$Pending) {
  $side = if ([int]$Pending.direction -eq 1) { 'LONG' } else { 'SHORT' }
  $entry = Format-Price $Pair $Pending.entry
  return ":large_orange_diamond: *$Pair armed $side* · $(Format-NyTime $Pending.signalTime)`n70.5% entry waiting at $entry · signal close $(Format-Price $Pair $Pending.signalPrice)"
}

function Message-Open($Position) {
  $pair = [string]$Position.pair
  $practice = if ($Position.practice.status) { [string]$Position.practice.status } else { 'PAPER_ONLY' }
  $side = ([string]$Position.direction).ToUpperInvariant()
  return ":large_blue_circle: *$pair $side opened* · $(Format-NyTime $Position.entryTime)`nEntry $(Format-Price $pair $Position.entry) · TP $(Format-Price $pair $Position.tp1) · SL $(Format-Price $pair $Position.stop) · OANDA practice: $practice"
}

function Message-Close($Trade) {
  $pair = [string]$Trade.pair
  $pips = [double]$Trade.netPips
  $sign = if ($pips -ge 0) { '+' } else { '' }
  $icon = if ($pips -ge 0) { ':white_check_mark:' } else { ':red_circle:' }
  return "$icon *$pair $(([string]$Trade.direction).ToUpperInvariant()) closed $sign$($pips.ToString('F1',[Globalization.CultureInfo]::InvariantCulture)) pips* · $(Format-NyTime $Trade.exitTime)`nReason $($Trade.exitReason) · entry $(Format-Price $pair $Trade.entry) → exit $(Format-Price $pair $Trade.exit)"
}

function Scan-Once {
  $snapshot = Get-Snapshot (Read-Ledger)
  if (-not (Test-Path $StatePath)) {
    $state = @{ seenClosed=@($snapshot.closed.Keys); seenOpen=@($snapshot.open.Keys); seenArm=@($snapshot.armed.Keys); initializedAt=[DateTimeOffset]::UtcNow.ToString('o') }
    Save-State $state
    Write-Host 'Slack V2 notifier initialized from current ledger; old trades will not be reposted.'
    return
  }
  $state = Get-Content -Raw $StatePath | ConvertFrom-Json -AsHashtable -DateKind String
  $seenClosed = [Collections.Generic.HashSet[string]]::new([string[]]@($state.seenClosed))
  $seenOpen = [Collections.Generic.HashSet[string]]::new([string[]]@($state.seenOpen))
  $seenArm = [Collections.Generic.HashSet[string]]::new([string[]]@($state.seenArm))
  foreach ($key in @($snapshot.armed.Keys | Sort-Object)) {
    if ($seenArm.Contains($key)) { continue }
    $item = $snapshot.armed[$key]
    Send-Slack (Message-Arm $item.pair $item.pending)
    [void]$seenArm.Add($key)
    $state.seenArm = @($seenArm); Save-State $state
  }
  foreach ($key in @($snapshot.open.Keys | Sort-Object)) {
    if ($seenOpen.Contains($key)) { continue }
    Send-Slack (Message-Open $snapshot.open[$key])
    [void]$seenOpen.Add($key)
    $state.seenOpen = @($seenOpen); Save-State $state
  }
  foreach ($key in @($snapshot.closed.Keys | Sort-Object)) {
    if ($seenClosed.Contains($key)) { continue }
    Send-Slack (Message-Close $snapshot.closed[$key])
    [void]$seenClosed.Add($key)
    $state.seenClosed = @($seenClosed); Save-State $state
  }
}

if ($TestSend) {
  Send-Slack ':satellite: V2 forex Slack connection is working. Future live arm, entry, and exit events will appear here.'
  return
}

$lockPath = Join-Path $PSScriptRoot 'data/slack-v2-notifier.lock'
[IO.Directory]::CreateDirectory((Split-Path -Parent $lockPath)) | Out-Null
try { $lock = [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
catch [IO.IOException] { throw 'The V2 Slack notifier is already running.' }
try {
  do {
    try { Scan-Once }
    catch { Write-Warning "Slack V2 notification scan failed: $($_.Exception.Message)" }
    if ($Once) { break }
    Start-Sleep -Seconds $PollSeconds
  } while ($true)
} finally { $lock.Dispose() }
