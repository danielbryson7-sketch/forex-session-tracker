param(
  [string]$SourcePath = (Join-Path $PSScriptRoot 'data/qqq-source.json'),
  [string]$OutputPath = (Join-Path $PSScriptRoot 'data/qqq-backtest-6mo.json')
)

$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'qqq-indicator-engine.ps1')
if (-not (Test-Path $SourcePath)) { throw 'QQQ source data is missing. Provide a licensed data/qqq-source.json file or pass -SourcePath.' }
$source=Get-Content -Raw $SourcePath | ConvertFrom-Json -AsHashtable -DateKind String
$ledger=@{ trades=@() }
$state=New-V2State
$start=if ($source.requested_from) { [DateTimeOffset]::Parse([string]$source.requested_from) } else { [DateTimeOffset]::MinValue }
$regularBars=New-Object 'System.Collections.Generic.List[object]'
$arms=New-Object 'System.Collections.Generic.List[object]'
$swings=New-Object 'System.Collections.Generic.List[object]'
$sessions=@{}
$swingRecorded=@{}
$priorPending=''

foreach ($raw in @($source.bars)) {
  $dt=[DateTimeOffset]::FromUnixTimeMilliseconds([long]$raw.t)
  $ny=[TimeZoneInfo]::ConvertTime($dt,$script:V2Ny)
  $minutes=$ny.Hour*60+$ny.Minute
  if ($minutes -lt 570 -or $minutes -ge 960) { continue }
  $day=$ny.ToString('yyyy-MM-dd')
  $sessions[$day]=$true
  $bar=@{ time=$dt.ToString('o'); dt=$dt; open=[double]$raw.o; high=[double]$raw.h;
    low=[double]$raw.l; close=[double]$raw.c; askOpen=[double]$raw.o;
    askHigh=[double]$raw.h; askLow=[double]$raw.l; askClose=[double]$raw.c }
  Invoke-V2Bar $ledger $state 'QQQ' $bar $start
  if ($state.swingReady -and -not $swingRecorded.ContainsKey($day)) {
    $swings.Add(@{ day=$day; high=[double]$state.swingHigh.price; highTime=[string]$state.swingHigh.time;
      low=[double]$state.swingLow.price; lowTime=[string]$state.swingLow.time;
      confirmedAt=[string]$state.swingConfirmedAt;
      directionSource=[string]$state.swingDirectionSource;
      direction=if ($state.swingDirection -eq 1) { 'bullish' } else { 'bearish' } })
    $swingRecorded[$day]=$true
  }
  if ($state.pending -and [string]$state.pending.signalTime -ne $priorPending) {
    $p=$state.pending
    $arms.Add(@{ time=[string]$p.signalTime; direction=if ($p.direction -eq 1) { 'long' } else { 'short' };
      close=[double]$p.signalPrice; entry=[double]$p.entry; zoneLow=[double]$p.zoneLow;
      zoneHigh=[double]$p.zoneHigh; ema20=[double]$p.ema20; ema50=[double]$p.ema50;
      atrRatio=[double]$p.atrRatio })
  }
  $priorPending=if ($state.pending) { [string]$state.pending.signalTime } else { '' }
  $regularBars.Add(@($bar.time,$bar.open,$bar.high,$bar.low,$bar.close,[int]$state.bias,
    $(if ($state.ote) { [double]$state.ote.low } else { $null }),
    $(if ($state.ote) { [double]$state.ote.high } else { $null }),
    $(if ($state.ote) { [double]$state.ote.p705 } else { $null })))

  # QQQ positions have the one-trading-day limit selected for this symbol.
  if ($minutes -eq 945 -and $state.position) {
    Close-V2Position $ledger $state 'QQQ' ([double]$bar.close) 'session_close' $dt.AddMinutes(15)
  }
}

$trades=@($ledger.trades | ForEach-Object {
  @{ direction=$_.direction; signalTime=$_.signalTime; entryTime=$_.entryTime;
    exitTime=$_.exitTime; entry=[double]$_.entry; stop=$null;
    target=[double]$_.tp1; exit=[double]$_.exit; exitReason=$_.exitReason;
    points=[double]$_.netPips; armEma20=$_.armEma20; armEma50=$_.armEma50;
    armAtrRatio=$_.armAtrRatio; entryZoneLow=$_.entryZoneLow;
    entryZoneHigh=$_.entryZoneHigh; signalOpen=$_.signalOpen;
    signalClose=$_.signalClose }
})
$wins=@($trades | Where-Object { $_.points -gt 0 })
$losses=@($trades | Where-Object { $_.points -lt 0 })
$net=($trades | Measure-Object -Property points -Sum).Sum
$grossWins=($wins | Measure-Object -Property points -Sum).Sum
$grossLosses=($losses | Measure-Object -Property points -Sum).Sum
$output=@{
  symbol='QQQ'; source='Massive 15-minute adjusted trade aggregates';
  requestedFrom=[string]$source.requested_from; requestedThrough=[string]$source.requested_through;
  rules=@{ session='09:30–16:00 America/New_York'; entryWindows='after swing confirmation through 15:30 bar, New York';
    maxEntriesPerDay=2; maxOpen=1; maxHolding='one trading day';
    dailyRange='high and low of the first four regular-session M15 candles, fixed at 10:30 New York';
    fibDirection='low before high is bullish; high before low is bearish; if both extremes share a candle, its body color breaks the tie';
    filters='Daily Supertrend 10×3; EMA20/50 aligned; ATR14/ATR50 ≤ 1.4';
    entry='OTE touch and rejection arms; later 70.5% touch enters';
    exit='first-four-candle range extreme target or session close; no stop loss';
    stopDistanceMultiplier=$null;
    pricing='Massive aggregate OHLC, no spread, slippage, fees, or fill-size simulation' };
  summary=@{ bars=$regularBars.Count; sessions=$sessions.Count; openingRangeSessions=$swings.Count;
    sameBarTieBreaks=@($swings | Where-Object { $_.directionSource -eq 'same-bar-body-tie-break' }).Count; arms=$arms.Count;
    trades=$trades.Count; wins=$wins.Count; losses=$losses.Count;
    flats=$trades.Count-$wins.Count-$losses.Count;
    netPoints=[Math]::Round([double]$net,2);
    grossWinPoints=[Math]::Round([double]$grossWins,2);
    grossLossPoints=[Math]::Round([double]$grossLosses,2) };
  bars=@($regularBars.ToArray()); swings=@($swings.ToArray()); arms=@($arms.ToArray()); trades=$trades
}
$directory=Split-Path $OutputPath
[IO.Directory]::CreateDirectory($directory) | Out-Null
$output | ConvertTo-Json -Depth 12 -Compress | Set-Content -Encoding utf8 $OutputPath
Write-Host "QQQ backtest: $($output.summary.bars) M15 regular-session bars; $($output.summary.sessions) sessions; $($output.summary.arms) arms; $($output.summary.trades) trades; $($output.summary.wins) wins; $($output.summary.losses) losses; $($output.summary.netPoints) net points."
