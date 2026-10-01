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
. (Join-Path $PSScriptRoot 'daily-summary-v2.ps1')
$script:slackWebhookUrl = [string]$env:SLACK_WEBHOOK_URL
$script:slackBotToken = [string]$env:SLACK_BOT_TOKEN
$script:slackChannelId = [string]$env:SLACK_CHANNEL_ID
$privatePath = Join-Path $PSScriptRoot 'slack-credentials.local.ps1'
if (Test-Path $privatePath) { . $privatePath }
$script:threadedMode = -not [string]::IsNullOrWhiteSpace($script:slackBotToken) -and -not [string]::IsNullOrWhiteSpace($script:slackChannelId)
if (-not $DryRun -and -not $script:threadedMode -and ($script:slackWebhookUrl -notmatch '^https://hooks\.slack\.com/services/[^/]+/[^/]+/[^/]+$')) {
  throw 'Set SLACK_BOT_TOKEN and SLACK_CHANNEL_ID for threaded alerts, or set a Slack incoming webhook for flat alerts.'
}
if (-not $DryRun -and -not $script:threadedMode -and ($script:slackBotToken -or $script:slackChannelId)) {
  throw 'Threaded Slack alerts need both SLACK_BOT_TOKEN and SLACK_CHANNEL_ID.'
}
$script:oandaToken = [string]$env:OANDA_API_TOKEN
$script:oandaAccount = [string]$env:OANDA_ACCOUNT_ID
$script:oandaEnvironment = if ($env:OANDA_ENVIRONMENT -eq 'live') { 'live' } else { 'practice' }
if ($script:threadedMode -and (Test-Path (Join-Path $PSScriptRoot 'credentials-v2.local.ps1'))) {
  . (Join-Path $PSScriptRoot 'credentials-v2.local.ps1')
  $script:oandaToken = [string]$script:token
  $script:oandaAccount = [string]$script:account
  $script:oandaEnvironment = [string]$script:environment
}

function Format-NyTime($Value) {
  if (-not $Value) { return 'unknown time' }
  return [TimeZoneInfo]::ConvertTime([DateTimeOffset]::Parse([string]$Value),$nyZone).ToString('MM/dd HH:mm') + ' NY'
}

function Format-Price([string]$Pair,$Value) {
  $digits = if ($Pair.EndsWith('/JPY')) { 3 } else { 5 }
  return ([double]$Value).ToString("F$digits",[Globalization.CultureInfo]::InvariantCulture)
}

function Send-Slack([string]$Message,[string]$ThreadTs = '') {
  if ($DryRun) {
    Write-Host "DRY RUN ($ThreadTs): $Message"
    return @{ ts='dry-run-parent'; channel='dry-run-channel' }
  }
  if ($script:threadedMode) {
    $payload = @{ channel=$script:slackChannelId; text=$Message; unfurl_links=$false }
    if ($ThreadTs) { $payload.thread_ts = $ThreadTs }
    $body = $payload | ConvertTo-Json -Compress -Depth 4
    $headers = @{ Authorization = "Bearer $($script:slackBotToken)" }
    $response = Invoke-RestMethod -Uri 'https://slack.com/api/chat.postMessage' -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 20
    if (-not $response.ok -or -not $response.ts -or -not $response.channel) {
      throw "Slack chat.postMessage failed: $($response.error)"
    }
    return @{ ts=[string]$response.ts; channel=[string]$response.channel }
  }
  $body = @{ text = $Message } | ConvertTo-Json -Compress -Depth 4
  $result = Invoke-WebRequest -Uri $script:slackWebhookUrl -Method Post -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 20 -UseBasicParsing
  if ($result.StatusCode -ne 200 -or [string]$result.Content -ne 'ok') { throw 'Slack did not accept the notification.' }
  return $null
}

function Update-SlackParent([string]$Message,[string]$Timestamp) {
  if ($DryRun) { Write-Host "DRY RUN parent update ($Timestamp): $Message"; return }
  if (-not $script:threadedMode) { return }
  $payload = @{ channel=$script:slackChannelId; ts=$Timestamp; text=$Message } | ConvertTo-Json -Compress -Depth 4
  $headers = @{ Authorization = "Bearer $($script:slackBotToken)" }
  $response = Invoke-RestMethod -Uri 'https://slack.com/api/chat.update' -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $payload -TimeoutSec 20
  if (-not $response.ok) { throw "Slack chat.update failed: $($response.error)" }
}

function Get-TradeChart($Position,[ValidateSet('entry','close')][string]$Mode = 'entry') {
  if (-not $script:oandaToken) { throw 'OANDA token is unavailable for the Slack chart.' }
  $pair = [string]$Position.pair
  if ($pair -notmatch '^[A-Z]{3}/[A-Z]{3}$') { throw 'Invalid forex pair for the Slack chart.' }
  $entry = [DateTimeOffset]::Parse([string]$Position.entryTime)
  $signal = [DateTimeOffset]::Parse([string]$Position.signalTime)
  $end = if ($Mode -eq 'close') { [DateTimeOffset]::Parse([string]$Position.exitTime) } else { $entry }
  $begin = $entry.AddHours(-4).AddMinutes(-45)
  if ($signal -lt $begin) { $begin = $signal }
  $chartDir = Join-Path $PSScriptRoot 'data/slack-charts'
  [IO.Directory]::CreateDirectory($chartDir) | Out-Null
  $stem = "$($pair.Replace('/',''))-$($entry.ToUnixTimeSeconds())-$Mode"
  if ($Mode -eq 'close') { $stem += "-$($end.ToUnixTimeSeconds())" }
  $jsonPath = Join-Path $chartDir "$stem.json"
  $pngPath = Join-Path $chartDir "$stem.png"
  if (Test-Path $pngPath) { return $pngPath }
  $hostName = if ($script:oandaEnvironment -eq 'live') { 'api-fxtrade.oanda.com' } else { 'api-fxpractice.oanda.com' }
  $from = [uri]::EscapeDataString($begin.UtcDateTime.ToString('o'))
  $to = [uri]::EscapeDataString($end.AddMinutes(15).AddSeconds(1).UtcDateTime.ToString('o'))
  $instrument = $pair.Replace('/','_')
  $url = "https://$hostName/v3/instruments/$instrument/candles?price=BA&granularity=M15&from=$from&to=$to"
  $headers = @{ Authorization="Bearer $($script:oandaToken)"; 'Accept-Datetime-Format'='RFC3339' }
  $response = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 25
  $bars = @($response.candles | Where-Object { $_.complete -and $_.bid -and [DateTimeOffset]::Parse([string]$_.time) -le $end } | ForEach-Object {
    @{ time=[string]$_.time; open=[double]$_.bid.o; high=[double]$_.bid.h; low=[double]$_.bid.l; close=[double]$_.bid.c }
  })
  if ($bars.Count -lt 2) { throw "OANDA returned fewer than two completed M15 bars for $pair." }
  $chart = @{ mode=$Mode; pair=$pair; direction=$Position.direction; signalTime=$Position.signalTime; signalPrice=$Position.signalPrice;
    entryTime=$Position.entryTime; entryPrice=$Position.entry; entryTarget=$Position.entryTarget;
    zoneLow=$Position.entryZoneLow; zoneHigh=$Position.entryZoneHigh; bars=$bars }
  if ($Mode -eq 'close') {
    $chart.exitTime=$Position.exitTime; $chart.exitPrice=$Position.exit; $chart.exitReason=$Position.exitReason;
    $chart.netPips=$Position.netPips
  }
  [IO.File]::WriteAllText($jsonPath,($chart | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
  try {
    $renderer = Join-Path $PSScriptRoot 'render-slack-trade-chart.py'
    & python3 $renderer $jsonPath $pngPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $pngPath)) { throw "Could not render the $pair trade chart." }
  } finally { Remove-Item -LiteralPath $jsonPath -ErrorAction SilentlyContinue }
  return $pngPath
}

function Send-SlackChart([string]$Message,[string]$ThreadTs,[string]$ChartPath,[string]$Pair,[ValidateSet('entry','close')][string]$Mode = 'entry') {
  if ($DryRun) { Write-Host "DRY RUN chart in thread $ThreadTs : $ChartPath"; return }
  $bytes = [IO.File]::ReadAllBytes($ChartPath)
  $headers = @{ Authorization="Bearer $($script:slackBotToken)" }
  $filename = [IO.Path]::GetFileName($ChartPath)
  $description = if ($Mode -eq 'close') { "$Pair M15 chart with OTE zone, A arm, L or S entry, exit dot, and trade path" } else { "$Pair M15 candles, OTE zone, A arm, and L or S entry" }
  $uploadRequest = @{ filename=$filename; length=[string]$bytes.Length; alt_txt=$description }
  $first = Invoke-RestMethod -Uri 'https://slack.com/api/files.getUploadURLExternal' -Method Post -Headers $headers -ContentType 'application/x-www-form-urlencoded' -Body $uploadRequest -TimeoutSec 20
  if (-not $first.ok -or -not $first.upload_url -or -not $first.file_id) { throw "Slack file upload initialization failed: $($first.error)" }
  $upload = Invoke-WebRequest -Uri ([string]$first.upload_url) -Method Post -Body $bytes -ContentType 'image/png' -TimeoutSec 30 -UseBasicParsing
  if ($upload.StatusCode -ne 200) { throw 'Slack did not accept the chart bytes.' }
  $complete = @{ files=@(@{ id=[string]$first.file_id; title="$Pair M15 $Mode chart" }); channel_id=$script:slackChannelId;
    thread_ts=$ThreadTs; initial_comment=$Message } | ConvertTo-Json -Depth 5 -Compress
  $last = Invoke-RestMethod -Uri 'https://slack.com/api/files.completeUploadExternal' -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $complete -TimeoutSec 30
  if (-not $last.ok) { throw "Slack chart share failed: $($last.error)" }
}

function Send-SlackDailyProgress($Report,[string]$Key) {
  if (-not $script:threadedMode) {
    Write-Warning 'The daily OTE progress image needs a Slack bot token and channel ID.'
    return
  }
  $chartDir = Join-Path $PSScriptRoot 'data/slack-charts'
  [IO.Directory]::CreateDirectory($chartDir) | Out-Null
  $jsonPath = Join-Path $chartDir "daily-progress-$Key.json"
  $pngPath = Join-Path $chartDir "daily-progress-$Key.png"
  [IO.File]::WriteAllText($jsonPath,($Report | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
  try {
    & python3 (Join-Path $PSScriptRoot 'render-daily-progress.py') $jsonPath $pngPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $pngPath)) { throw 'Could not render the daily OTE progress chart.' }
  } finally { Remove-Item -LiteralPath $jsonPath -ErrorAction SilentlyContinue }
  if ($DryRun) { Write-Host "DRY RUN daily OTE progress chart: $pngPath"; return }
  $bytes = [IO.File]::ReadAllBytes($pngPath)
  $headers = @{ Authorization="Bearer $($script:slackBotToken)" }
  $first = Invoke-RestMethod -Uri 'https://slack.com/api/files.getUploadURLExternal' -Method Post -Headers $headers -ContentType 'application/x-www-form-urlencoded' -Body @{
    filename=[IO.Path]::GetFileName($pngPath); length=[string]$bytes.Length; alt_txt='Daily OTE distance and pip capture progress by traded forex pair'
  } -TimeoutSec 20
  if (-not $first.ok -or -not $first.upload_url -or -not $first.file_id) { throw "Slack daily chart upload initialization failed: $($first.error)" }
  $upload = Invoke-WebRequest -Uri ([string]$first.upload_url) -Method Post -Body $bytes -ContentType 'image/png' -TimeoutSec 30 -UseBasicParsing
  if ($upload.StatusCode -ne 200) { throw 'Slack did not accept the daily chart bytes.' }
  $payload = @{ files=@(@{ id=[string]$first.file_id; title="Daily OTE progress $Key" }); channel_id=$script:slackChannelId;
    initial_comment=":bar_chart: *Daily OTE distance and pips captured — $Key*" } | ConvertTo-Json -Depth 5 -Compress
  $last = Invoke-RestMethod -Uri 'https://slack.com/api/files.completeUploadExternal' -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $payload -TimeoutSec 30
  if (-not $last.ok) { throw "Slack daily chart share failed: $($last.error)" }
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

function Message-Arm([string]$Pair,$Pending,[bool]$InOte = $false) {
  $side = if ([string]$Pending.direction -in @('1','long','LONG')) { 'LONG' } else { 'SHORT' }
  $entry = Format-Price $Pair $Pending.entry
  $icons = if ($InOte) { ':v2-armed: :v2-in-ote:' } else { ':v2-armed:' }
  return "$icons *$Pair armed $side* · $(Format-NyTime $Pending.signalTime)`n70.5% entry waiting at $entry · signal close $(Format-Price $Pair $Pending.signalPrice)"
}

function Get-ArmKey([string]$Pair,$Item) {
  return "$Pair|$($Item.signalTime)"
}

function Get-ArmFromTrade($Trade) {
  return @{ direction=if ([string]$Trade.direction -eq 'long') { 1 } else { -1 }; signalTime=$Trade.signalTime;
    signalPrice=$Trade.signalPrice; entry=$Trade.entryTarget }
}

function Message-Parent($Trade,[ValidateSet('open','closed')][string]$Stage,[bool]$InOte = $false) {
  $pair = [string]$Trade.pair
  $side = ([string]$Trade.direction).ToUpperInvariant()
  $directionEmoji = if ($side -eq 'LONG') { ':v2-long:' } else { ':v2-short:' }
  $oteEmoji = if ($InOte -and $Stage -eq 'open') { ':v2-in-ote: ' } else { '' }
  $icons = ":v2-armed: $oteEmoji$directionEmoji"
  $status = "OPEN $side"
  if ($Stage -eq 'closed') {
    $exitReason = [string]$Trade.exitReason
    $exitEmoji = switch ($exitReason) {
      'tp1' { ':v2-take-profit:' }
      'gap_tp1' { ':v2-take-profit:' }
      'stop' { ':v2-stop-loss:' }
      'gap_stop' { ':v2-stop-loss:' }
      default { ':checkered_flag:' }
    }
    $icons += " $exitEmoji"
    $status = "CLOSED $side · $($exitReason.ToUpperInvariant())"
  }
  $text = "$icons *$pair $status*`nArmed $(Format-NyTime $Trade.signalTime) · signal close $(Format-Price $pair $Trade.signalPrice) · 70.5% $(Format-Price $pair $Trade.entryTarget)"
  $text += "`nOpened $(Format-NyTime $Trade.entryTime) at $(Format-Price $pair $Trade.entry)"
  if ($Stage -eq 'closed') {
    $pips = [double]$Trade.netPips
    $signedPips = if ($pips -ge 0) { '+' } else { '' }
    $text += " · closed $(Format-NyTime $Trade.exitTime) at $(Format-Price $pair $Trade.exit) ($signedPips$($pips.ToString('F1',[Globalization.CultureInfo]::InvariantCulture)) pips)"
  }
  return $text
}

function Set-ParentStage($State,$Trade,[ValidateSet('open','closed')][string]$Stage) {
  if (-not $script:threadedMode) { return }
  $armKey = Get-ArmKey ([string]$Trade.pair) $Trade
  $thread = $State.threads[$armKey]
  if (-not $thread -or -not $thread.ts) { throw "Missing Slack parent for $armKey." }
  if ($thread.stage -eq $Stage -or $thread.stage -eq 'closed') { return }
  $inOte = $Stage -eq 'open' -and [bool]$thread.inOte
  Update-SlackParent (Message-Parent $Trade $Stage $inOte) ([string]$thread.ts)
  $thread.stage = $Stage
  if ($Stage -eq 'closed') { $thread.inOte = $false }
  Save-State $State
}

function Ensure-Thread($State,[string]$Pair,$Trade) {
  $armKey = Get-ArmKey $Pair $Trade
  if (-not $armKey -or -not $Trade.signalTime) { throw "Cannot thread $Pair trade without its signal time." }
  if (-not $State.threads) { $State.threads = @{} }
  if ($State.threads.ContainsKey($armKey)) { return [string]$State.threads[$armKey].ts }
  $arm = Get-ArmFromTrade $Trade
  $armText = Message-Arm $Pair $arm
  $posted = Send-Slack $armText
  if (-not $posted.ts) { throw "Slack did not return a parent timestamp for $Pair." }
  $State.threads[$armKey] = @{ ts=$posted.ts; channel=$posted.channel; stage='armed'; inOte=$false; armText=$armText }
  Save-State $State
  return [string]$posted.ts
}

function Message-Open($Position) {
  $pair = [string]$Position.pair
  $practice = if ($Position.practice.status) { [string]$Position.practice.status } else { 'PAPER_ONLY' }
  $side = ([string]$Position.direction).ToUpperInvariant()
  $fill = if ($Position.practice.fillPrice) { " at $(Format-Price $pair $Position.practice.fillPrice)" } else { '' }
  $fillTime = if ($Position.practice.fillTime) { " · $(Format-NyTime $Position.practice.fillTime)" } else { '' }
  return ":large_blue_circle: *TRADE OPENED — $pair $side*`nPaper entry: *$(Format-Price $pair $Position.entry)* · entry candle $(Format-NyTime $Position.entryTime) · 70.5% OTE retouch`nTP $(Format-Price $pair $Position.tp1) · SL $(Format-Price $pair $Position.stop)`nOANDA practice: $practice$fill$fillTime"
}

function Message-Close($Trade) {
  $pair = [string]$Trade.pair
  $pips = [double]$Trade.netPips
  $sign = if ($pips -ge 0) { '+' } else { '' }
  $icon = if ($pips -ge 0) { ':white_check_mark:' } else { ':red_circle:' }
  return "$icon *$pair $(([string]$Trade.direction).ToUpperInvariant()) closed $sign$($pips.ToString('F1',[Globalization.CultureInfo]::InvariantCulture)) pips* · $(Format-NyTime $Trade.exitTime)`nReason $($Trade.exitReason) · entry $(Format-Price $pair $Trade.entry) → exit $(Format-Price $pair $Trade.exit)"
}

function Get-LiveOteMarks([string[]]$Pairs) {
  $marks = @{}
  if (-not $Pairs.Count -or -not $script:oandaToken -or -not $script:oandaAccount) { return $marks }
  $hostName = if ($script:oandaEnvironment -eq 'live') { 'api-fxtrade.oanda.com' } else { 'api-fxpractice.oanda.com' }
  $instruments = (@($Pairs | Sort-Object -Unique) | ForEach-Object { $_.Replace('/','_') }) -join ','
  $accountId = [uri]::EscapeDataString($script:oandaAccount)
  $url = "https://$hostName/v3/accounts/$accountId/pricing?instruments=$([uri]::EscapeDataString($instruments))"
  $response = Invoke-RestMethod -Uri $url -Headers @{ Authorization="Bearer $($script:oandaToken)" } -TimeoutSec 20
  foreach ($quote in @($response.prices)) {
    if ($quote.status -ne 'tradeable' -or -not $quote.bids -or -not $quote.asks) { continue }
    $quoteTime = [DateTimeOffset]::Parse([string]$quote.time)
    if ([Math]::Abs(([DateTimeOffset]::UtcNow-$quoteTime).TotalSeconds) -gt 60) { continue }
    $pair = ([string]$quote.instrument).Replace('_','/')
    $marks[$pair] = ([double]$quote.bids[0].price+[double]$quote.asks[0].price)/2.0
  }
  return $marks
}

function Refresh-OteStatus($State,$Snapshot,$Ledger) {
  if (-not $script:threadedMode -or $DryRun) { return }
  $active = @()
  foreach ($key in @($Snapshot.armed.Keys)) {
    if (-not $State.threads.ContainsKey($key) -or $State.threads[$key].stage -eq 'closed') { continue }
    $item = $Snapshot.armed[$key]
    $zone = $Ledger.pairs[$item.pair].ote
    $valid = $zone -and $zone.asOf -and
      ([DateTimeOffset]::UtcNow-[DateTimeOffset]::Parse([string]$zone.asOf)).TotalMinutes -le 30 -and
      [double]$zone.high -gt [double]$zone.low
    $active += @{ key=$key; pair=$item.pair; stage='armed'; item=$item.pending;
      low=if ($valid) { [double]$zone.low } else { $null }; high=if ($valid) { [double]$zone.high } else { $null } }
  }
  foreach ($key in @($Snapshot.open.Keys)) {
    $position = $Snapshot.open[$key]
    $armKey = Get-ArmKey ([string]$position.pair) $position
    if (-not $State.threads.ContainsKey($armKey) -or $State.threads[$armKey].stage -eq 'closed') { continue }
    $active += @{ key=$armKey; pair=$position.pair; stage='open'; item=$position;
      low=$position.entryZoneLow; high=$position.entryZoneHigh }
  }
  $marks = @{}
  if ($active.Count) {
    try { $marks = Get-LiveOteMarks @($active | ForEach-Object { $_.pair }) }
    catch { Write-Warning "Could not check live OTE quotes: $($_.Exception.Message)"; return }
  }
  foreach ($item in $active) {
    $thread = $State.threads[$item.key]
    $inside = $false
    if ($marks.ContainsKey($item.pair) -and $null -ne $item.low -and $null -ne $item.high) {
      $midpoint = [double]$marks[$item.pair]
      $inside = $midpoint -ge [double]$item.low -and $midpoint -le [double]$item.high
    }
    if ([bool]$thread.inOte -eq $inside) { continue }
    $message = if ($item.stage -eq 'armed') { Message-Arm $item.pair $item.item $inside }
      else { Message-Parent $item.item 'open' $inside }
    Update-SlackParent $message ([string]$thread.ts)
    $thread.inOte = $inside
    Save-State $State
  }
  $activeKeys = [Collections.Generic.HashSet[string]]::new([string[]]@($active | ForEach-Object { $_.key }))
  foreach ($key in @($State.threads.Keys)) {
    $thread = $State.threads[$key]
    if ($thread.stage -ne 'armed' -or -not $thread.inOte -or $activeKeys.Contains($key) -or -not $thread.armText) { continue }
    Update-SlackParent ([string]$thread.armText) ([string]$thread.ts)
    $thread.inOte = $false
    Save-State $State
  }
}

function Send-DailySummaryIfDue($State,$Ledger) {
  $now = [DateTimeOffset]::UtcNow
  $local = [TimeZoneInfo]::ConvertTime($now,$nyZone)
  if ($local.DayOfWeek -in @([DayOfWeek]::Saturday,[DayOfWeek]::Sunday)) { return }
  $cutoffNy = $local.Date.AddHours(17)
  if ($local.DateTime -lt $cutoffNy.AddMinutes(3)) { return }
  $key = $cutoffNy.ToString('yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
  if ($State.lastDailySummaryKey -eq $key) {
    if ($script:threadedMode -and $State.lastDailyChartKey -ne $key -and $State.lastDailyChartData) {
      try {
        Send-SlackDailyProgress $State.lastDailyChartData $key
        $State.lastDailyChartKey = $key
        Save-State $State
        Write-Host "Posted V2 daily OTE progress chart for $key."
      } catch { Write-Warning "Daily OTE progress chart for $key failed: $($_.Exception.Message)" }
    }
    return
  }
  $cutoffUtc = [TimeZoneInfo]::ConvertTimeToUtc($cutoffNy,$nyZone)
  if (-not $Ledger.updatedAt -or ([DateTimeOffset]::Parse([string]$Ledger.updatedAt)).UtcDateTime -lt $cutoffUtc.AddMinutes(1)) {
    Write-Warning "V2 daily summary for $key is waiting for the worker to scan the 17:00 New York close."
    return
  }
  $message = Get-V2DailySummary $Ledger $cutoffNy
  $chartData = Get-V2DailyProgress $Ledger $cutoffNy
  $null = Send-Slack $message
  $State.lastDailySummaryKey = $key
  $State.lastDailyChartData = $chartData
  Save-State $State
  Write-Host "Posted V2 daily Slack summary for $key."
  if ($script:threadedMode -and @($chartData.rows).Count) {
    try {
      Send-SlackDailyProgress $chartData $key
      $State.lastDailyChartKey = $key
      Save-State $State
      Write-Host "Posted V2 daily OTE progress chart for $key."
    } catch { Write-Warning "Daily OTE progress chart for $key failed: $($_.Exception.Message)" }
  } else {
    $State.lastDailyChartKey = $key
    Save-State $State
  }
}

function Scan-Once {
  $ledger = Read-Ledger
  $snapshot = Get-Snapshot $ledger
  if (-not (Test-Path $StatePath)) {
    $state = @{ seenClosed=@($snapshot.closed.Keys); seenOpen=@($snapshot.open.Keys); seenArm=@($snapshot.armed.Keys); threads=@{}; initializedAt=[DateTimeOffset]::UtcNow.ToString('o') }
    Save-State $state
    Write-Host 'Slack V2 notifier initialized from current ledger; old trades will not be reposted.'
    return
  }
  $state = Get-Content -Raw $StatePath | ConvertFrom-Json -AsHashtable -DateKind String
  if (-not $state.threads) { $state.threads = @{} }
  $seenClosed = [Collections.Generic.HashSet[string]]::new([string[]]@($state.seenClosed))
  $seenOpen = [Collections.Generic.HashSet[string]]::new([string[]]@($state.seenOpen))
  $seenArm = [Collections.Generic.HashSet[string]]::new([string[]]@($state.seenArm))
  foreach ($key in @($snapshot.armed.Keys | Sort-Object)) {
    if ($seenArm.Contains($key)) { continue }
    $item = $snapshot.armed[$key]
    if ($script:threadedMode) {
      if (-not $state.threads.ContainsKey($key)) {
        $armText = Message-Arm $item.pair $item.pending
        $posted = Send-Slack $armText
        $state.threads[$key] = @{ ts=$posted.ts; channel=$posted.channel; stage='armed'; inOte=$false; armText=$armText }
        Save-State $state
      }
    } else { $null = Send-Slack (Message-Arm $item.pair $item.pending) }
    [void]$seenArm.Add($key)
    $state.seenArm = @($seenArm); Save-State $state
  }
  foreach ($key in @($snapshot.open.Keys | Sort-Object)) {
    if ($seenOpen.Contains($key)) { continue }
    $position = $snapshot.open[$key]
    $parentTs = if ($script:threadedMode) { Ensure-Thread $state $position.pair $position } else { '' }
    if ($script:threadedMode) { Set-ParentStage $state $position 'open' }
    if ($script:threadedMode -and -not $DryRun) {
      try {
        $chartPath = Get-TradeChart $position 'entry'
        Send-SlackChart (Message-Open $position) $parentTs $chartPath $position.pair 'entry'
      } catch {
        Write-Warning "Slack chart failed for $($position.pair): $($_.Exception.Message). Posting the entry text instead."
        $null = Send-Slack (Message-Open $position) $parentTs
      }
    } else { $null = Send-Slack (Message-Open $position) $parentTs }
    [void]$seenOpen.Add($key)
    $state.seenOpen = @($seenOpen); Save-State $state
  }
  foreach ($key in @($snapshot.closed.Keys | Sort-Object)) {
    if ($seenClosed.Contains($key)) { continue }
    $trade = $snapshot.closed[$key]
    $parentTs = if ($script:threadedMode) { Ensure-Thread $state $trade.pair $trade } else { '' }
    if ($script:threadedMode) { Set-ParentStage $state $trade 'closed' }
    if ($script:threadedMode -and -not $DryRun) {
      try {
        $chartPath = Get-TradeChart $trade 'close'
        Send-SlackChart (Message-Close $trade) $parentTs $chartPath $trade.pair 'close'
      } catch {
        Write-Warning "Slack closing chart failed for $($trade.pair): $($_.Exception.Message). Posting the close text instead."
        $null = Send-Slack (Message-Close $trade) $parentTs
      }
    } else { $null = Send-Slack (Message-Close $trade) $parentTs }
    [void]$seenClosed.Add($key)
    $state.seenClosed = @($seenClosed); Save-State $state
  }
  Refresh-OteStatus $state $snapshot $ledger
  Send-DailySummaryIfDue $state $ledger
}

if ($TestSend) {
  $null = Send-Slack ':satellite: V2 forex Slack connection is working. Future live arm, entry, and exit events will appear here.'
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
