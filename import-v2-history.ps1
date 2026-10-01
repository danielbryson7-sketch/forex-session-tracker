param(
  [string]$SourcePath = (Join-Path $PSScriptRoot 'data/replay-trades.csv'),
  [string]$LedgerPath = (Join-Path $PSScriptRoot 'data/paper-ledger-v2.json')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ledger-io.ps1')
. (Join-Path $PSScriptRoot 'indicator-engine-v2.ps1')
if (-not (Test-Path $SourcePath)) { throw "History file was not found: $SourcePath" }
if (-not (Test-Path $LedgerPath)) { throw "V2 ledger was not found: $LedgerPath" }
$source = [IO.Path]::GetFullPath($SourcePath)
$rows = @(Import-Csv $source)
if (-not $rows.Count) { throw 'The history file contains no trades.' }

$lock = Enter-PaperLedgerLock $LedgerPath
try {
  $ledger = Get-Content -Raw $LedgerPath | ConvertFrom-Json -AsHashtable -DateKind String
  if ($ledger.version -ne 2 -or $ledger.engine -ne 'daily-ote-st-ema-atr-v3.pine') {
    throw 'The destination is not the v2 EMA/ATR paper ledger.'
  }
  $liveStart = [DateTimeOffset]::Parse([string]$ledger.startedAt)
  $seen = [System.Collections.Generic.HashSet[string]]::new()
  foreach ($trade in @($ledger.trades)) {
    $key = '{0}|{1:o}' -f $trade.pair, [DateTimeOffset]::Parse([string]$trade.entryTime)
    [void]$seen.Add($key)
  }
  $incoming = [System.Collections.Generic.List[object]]::new()
  foreach ($row in $rows) {
    $symbol = [string]$row.symbol
    if ($symbol -notmatch '^[A-Z]{6}$') { throw "Invalid pair in history: $symbol" }
    $pair = $symbol.Substring(0,3) + '/' + $symbol.Substring(3,3)
    $entryTime = [DateTimeOffset]::Parse([string]$row.entry_time)
    $exitTime = [DateTimeOffset]::Parse([string]$row.exit_time)
    if ($exitTime -gt $liveStart) { throw "$pair history ends after the live v2 ledger started." }
    if ($exitTime -lt $entryTime) { throw "$pair has an exit before its entry." }
    $key = '{0}|{1:o}' -f $pair, $entryTime
    if ($seen.Contains($key)) { continue }
    [void]$seen.Add($key)
    $direction = if ([int]$row.direction -eq 1) { 'long' } elseif ([int]$row.direction -eq -1) { 'short' } else { throw "Invalid trade side for $pair" }
    $reason = switch ([string]$row.reason) {
      'target' { 'tp1' }
      'stop' { 'stop' }
      'gap target' { 'gap_tp1' }
      'gap stop' { 'gap_stop' }
      default { throw "Unknown exit reason for $pair`: $($row.reason)" }
    }
    $pips = [Math]::Round([double]$row.pips,1)
    $incoming.Add(@{
      pair = $pair; direction = $direction; origin = 'historical-replay'; pricing = 'midpoint'
      historySource = $source; engine = 'daily-ote-st-ema-atr-v3.pine'
      entryTime = $entryTime.ToString('o'); exitTime = $exitTime.ToString('o')
      signalTime = ([DateTimeOffset]::Parse([string]$row.signal_time)).ToString('o')
      signalDay = Get-V2DayKey $entryTime
      entry = [double]$row.entry; entryTarget = [double]$row.entry
      tp1 = [double]$row.target; stop = [double]$row.stop; exit = [double]$row.exit
      exitReason = $reason; grossPips = $pips; netPips = $pips
      targetRule = 'prior-day-extreme'; entryRule = 'later-m15-705-touch'
      reason = 'Historical v2 replay on completed OANDA M15 midpoint candles; EMA20/50 and ATR14/50 filters'
      maxFavorablePips = $null; maxAdversePips = $null
    })
  }
  if ($incoming.Count -gt 0) {
    $backup = "$LedgerPath.before-history-import"
    if (-not (Test-Path $backup)) { Copy-Item $LedgerPath $backup }
    $ledger.trades = @($ledger.trades) + @($incoming.ToArray())
    $ledger.historyImportedAt = [DateTimeOffset]::UtcNow.ToString('o')
    $ledger.historySource = $source
    $ledger.historyCount = @($ledger.trades | Where-Object { $_.origin -eq 'historical-replay' }).Count
    Save-PaperLedger $LedgerPath $ledger
  }
  $historical = @($ledger.trades | Where-Object { $_.origin -eq 'historical-replay' })
  $net = ($historical | Measure-Object -Property netPips -Sum).Sum
  Write-Host "V2 history: added $($incoming.Count); $($historical.Count) historical trades; $([Math]::Round([double]$net,1)) pips."
} finally { $lock.Dispose() }
