param([int]$Port = 8771)

$ErrorActionPreference = 'Stop'
$pairs = @(
  'EUR/USD','GBP/USD','USD/JPY','USD/CHF','USD/CAD','AUD/USD','NZD/USD',
  'EUR/GBP','EUR/JPY','EUR/CHF','EUR/CAD','EUR/AUD','EUR/NZD',
  'GBP/JPY','GBP/CHF','GBP/CAD','GBP/AUD','GBP/NZD',
  'AUD/JPY','AUD/CHF','AUD/CAD','AUD/NZD',
  'NZD/JPY','NZD/CHF','NZD/CAD','CAD/JPY','CAD/CHF','CHF/JPY'
)
$nyZone = [TimeZoneInfo]::FindSystemTimeZoneById('America/New_York')
$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(35)
$script:token = [string]$env:OANDA_API_TOKEN
$script:account = [string]$env:OANDA_ACCOUNT_ID
$script:environment = if ($env:OANDA_ENVIRONMENT -eq 'live') { 'live' } else { 'practice' }
if (Test-Path (Join-Path $PSScriptRoot 'credentials-v2.local.ps1')) {
  . (Join-Path $PSScriptRoot 'credentials-v2.local.ps1')
}
. (Join-Path $PSScriptRoot 'ledger-io.ps1')
. (Join-Path $PSScriptRoot 'practice-execution-v2.ps1')
$script:history = @{}
$script:historyWeek = ''
$script:quoteCache = @{ key = ''; expires = [DateTimeOffset]::MinValue; marks = @{} }

function Get-WeekWindow {
  $now = [DateTimeOffset]::UtcNow
  $local = [TimeZoneInfo]::ConvertTime($now, $nyZone)
  $sunday = $local.Date.AddDays(-[int]$local.DayOfWeek)
  $currentEnd = [TimeZoneInfo]::ConvertTimeToUtc($sunday.AddDays(5).AddHours(17), $nyZone)
  if ($now.UtcDateTime -lt $currentEnd) { $sunday = $sunday.AddDays(-7) }
  $start = [TimeZoneInfo]::ConvertTimeToUtc($sunday.AddHours(17), $nyZone)
  $end = [TimeZoneInfo]::ConvertTimeToUtc($sunday.AddDays(5).AddHours(17), $nyZone)
  return @{ start = $start; end = $end; now = $now.UtcDateTime }
}

function Resolve-Account {
  if ($script:account) { return }
  if (-not $script:token) { throw 'Enter your OANDA token in Settings.' }
  $environments = if ($script:environment -eq 'live') { @('live','practice') } else { @('practice','live') }
  foreach ($candidate in $environments) {
    $hostName = if ($candidate -eq 'live') { 'api-fxtrade.oanda.com' } else { 'api-fxpractice.oanda.com' }
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, "https://$hostName/v3/accounts")
    $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $script:token)
    try {
      $response = $client.SendAsync($request).GetAwaiter().GetResult()
      try {
        if (-not $response.IsSuccessStatusCode) { continue }
        $payload = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
        if ($payload.accounts.Count -gt 0) {
          $script:account = [string]$payload.accounts[0].id
          $script:environment = $candidate
          return
        }
      } finally { $response.Dispose() }
    } finally { $request.Dispose() }
  }
  throw 'OANDA did not return an accessible account for this token.'
}

function Get-OandaCandles([string]$Pair, [datetime]$From, [datetime]$To, [int]$Count = 0, [ValidateSet('M15','H4')][string]$Granularity = 'M15') {
  Resolve-Account
  if ($pairs -notcontains $Pair) { throw 'Unsupported currency pair.' }
  $hostName = if ($script:environment -eq 'live') { 'api-fxtrade.oanda.com' } else { 'api-fxpractice.oanda.com' }
  $instrument = $Pair.Replace('/', '_')
  $accountId = [uri]::EscapeDataString($script:account)
  $url = "https://$hostName/v3/accounts/$accountId/instruments/$instrument/candles?price=BA&granularity=$Granularity"
  if ($Count -gt 0) { $url += "&count=$Count" }
  else {
    $url += '&from=' + [uri]::EscapeDataString($From.ToUniversalTime().ToString('o'))
    $url += '&to=' + [uri]::EscapeDataString($To.ToUniversalTime().ToString('o'))
  }
  $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $url)
  $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $script:token)
  $request.Headers.TryAddWithoutValidation('Accept-Datetime-Format', 'RFC3339') | Out-Null
  try {
    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    try {
      if (-not $response.IsSuccessStatusCode) { throw "OANDA returned HTTP $([int]$response.StatusCode) for $Pair." }
      $payload = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
      if ($null -eq $payload.candles) { throw "OANDA returned no candle list for $Pair." }
      return @($payload.candles | Where-Object { $null -ne $_.bid } | ForEach-Object {
        @{ time = [string]$_.time; complete = [bool]$_.complete;
          open = ([double]$_.bid.o+[double]$_.ask.o)/2; high = ([double]$_.bid.h+[double]$_.ask.h)/2;
          low = ([double]$_.bid.l+[double]$_.ask.l)/2; close = ([double]$_.bid.c+[double]$_.ask.c)/2 }
      })
    } finally { $response.Dispose() }
  } finally { $request.Dispose() }
}

function Merge-Candles([object[]]$Existing, [object[]]$Incoming) {
  $byTime = @{}
  foreach ($row in $Existing) { $byTime[[string]$row[0]] = $row }
  foreach ($candle in $Incoming) {
    if (-not $candle.complete) { continue }
    $byTime[[string]$candle.time] = [object[]]@($candle.time,$candle.open,$candle.high,$candle.low,$candle.close)
  }
  $result = [System.Collections.Generic.List[object]]::new()
  foreach ($time in @($byTime.Keys | Sort-Object)) { $result.Add([object[]]$byTime[$time]) }
  return ,($result.ToArray())
}

function Get-SessionBoxes([object[]]$Rows) {
  $sessions = @{}
  $days = @{}
  for ($i = 0; $i -lt $Rows.Count; $i++) {
    $row = $Rows[$i]
    $local = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::Parse([string]$row[0]), $nyZone)
    $minute = $local.Hour * 60 + $local.Minute
    if ($minute -ge 1200 -or $minute -lt 120) { $id = 'asia'; $name = 'Asia'; $color = '#376699' }
    elseif ($minute -ge 1020) { $id = 'open'; $name = 'Market open'; $color = '#1e6274' }
    elseif ($minute -lt 480) { $id = 'london'; $name = 'London'; $color = '#8a6bb4' }
    else { $id = 'newYork'; $name = 'New York'; $color = '#bd8651' }
    $dayDate = $local.Date
    if ($minute -ge 1020) { $dayDate = $dayDate.AddDays(1) }
    $day = $dayDate.ToString('yyyy-MM-dd')
    $key = "$day|$id"
    if (-not $sessions.ContainsKey($key)) {
      $sessions[$key] = @{ day = $day; session = @{ id = $id; name = $name; color = $color };
        first = $i; last = $i; high = [double]$row[2]; low = [double]$row[3]; count = 0 }
    }
    $box = $sessions[$key]
    $box.last = $i; $box.high = [Math]::Max($box.high, [double]$row[2])
    $box.low = [Math]::Min($box.low, [double]$row[3]); $box.count++
    if (-not $days.ContainsKey($day)) {
      $days[$day] = @{ day = $day; first = $i; last = $i;
        high = [double]$row[2]; low = [double]$row[3] }
    }
    $daily = $days[$day]
    $daily.last = $i; $daily.high = [Math]::Max($daily.high, [double]$row[2])
    $daily.low = [Math]::Min($daily.low, [double]$row[3])
  }
  return @{ sessions = @($sessions.Values | Sort-Object first); days = @($days.Values | Sort-Object first) }
}

function Get-MarketState {
  $week = Get-WeekWindow
  $weekKey = $week.start.ToString('o')
  if ($script:historyWeek -ne $weekKey) { $script:history = @{}; $script:historyWeek = $weekKey }
  $data = @{}; $boxData = @{}; $errors = @()
  foreach ($pair in $pairs) {
    $existing = if ($script:history.ContainsKey($pair)) { [object[]]$script:history[$pair] } else { [object[]]@() }
    $from = if ($existing.Count) { [DateTimeOffset]::Parse([string]$existing[-1][0]).UtcDateTime.AddMinutes(-15) } else { $week.start }
    try {
      $incoming = @(Get-OandaCandles -Pair $pair -From $from -To $week.now)
      $existing = Merge-Candles -Existing $existing -Incoming $incoming
      $script:history[$pair] = $existing
    } catch { $errors += @{ pair = $pair; message = $_.Exception.Message } }
    $data[$pair] = $existing
    $boxData[$pair] = Get-SessionBoxes -Rows $existing
  }
  return @{ interval = 'M15'; previousWeek = @{ start = $week.start.ToString('o'); end = $week.end.ToString('o') };
    asOf = [DateTimeOffset]::UtcNow.ToString('o'); symbols = $pairs; pairs = $data; boxes = $boxData; errors = $errors }
}

function Get-LiveState([string]$Pair) {
  $candles = @(Get-OandaCandles -Pair $Pair -From ([datetime]::UtcNow) -To ([datetime]::UtcNow) -Count 3)
  $existing = if ($script:history.ContainsKey($Pair)) { [object[]]$script:history[$Pair] } else { [object[]]@() }
  if (-not $existing.Count) {
    $week = Get-WeekWindow
    $existing = Merge-Candles -Existing @() -Incoming @(Get-OandaCandles -Pair $Pair -From $week.start -To $week.now)
  }
  $existing = Merge-Candles -Existing $existing -Incoming $candles
  $script:history[$Pair] = $existing
  $forming = @($candles | Where-Object { -not $_.complete } | Select-Object -Last 1)
  $forBoxes = $existing
  if ($forming.Count -and -not @($existing | Where-Object { $_[0] -eq $forming[0].time }).Count) {
    $c = $forming[0]
    $withForming = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $existing) { $withForming.Add([object[]]$row) }
    $withForming.Add([object[]]@($c.time,$c.open,$c.high,$c.low,$c.close))
    $forBoxes = $withForming.ToArray()
  }
  return @{ pair = $Pair; asOf = [DateTimeOffset]::UtcNow.ToString('o'); bars = $candles;
    boxes = (Get-SessionBoxes -Rows $forBoxes) }
}

function Get-MobileChartState([string]$Pair) {
  # Sixteen completed M15 candles are the most recent four trading hours.
  $candles = @(Get-OandaCandles -Pair $Pair -From ([datetime]::UtcNow) -To ([datetime]::UtcNow) -Count 20)
  $completed = @($candles | Where-Object { $_.complete } | Select-Object -Last 16)
  if (-not $completed.Count) { throw "No completed M15 candles are available for $Pair." }
  $ledgerPath = Join-Path $PSScriptRoot 'data/paper-ledger-v2.json'
  $engine = $null
  if (Test-Path $ledgerPath) {
    $ledger = Get-Content -Raw $ledgerPath | ConvertFrom-Json -AsHashtable -DateKind String
    if ($ledger.pairs.ContainsKey($Pair)) {
      $state = $ledger.pairs[$Pair]
      $engine = @{ bias = $state.bias; ote = $state.ote; position = $state.position; asOf = $state.lastBar }
    }
  }
  $rows = [System.Collections.Generic.List[object]]::new()
  foreach ($candle in $completed) {
    $rows.Add([object[]]@([string]$candle.time,[double]$candle.open,[double]$candle.high,[double]$candle.low,[double]$candle.close))
  }
  return @{ pair = $Pair; interval = 'M15'; bars = $rows.ToArray(); engine = $engine; asOf = [DateTimeOffset]::UtcNow.ToString('o') }
}

function Get-H4State([string]$Pair) {
  $candles = @(Get-OandaCandles -Pair $Pair -From ([datetime]::UtcNow) -To ([datetime]::UtcNow) -Count 200 -Granularity 'H4')
  $rows = [System.Collections.Generic.List[object]]::new()
  foreach ($candle in $candles) {
    if ($candle.complete) { $rows.Add([object[]]@($candle.time,$candle.open,$candle.high,$candle.low,$candle.close)) }
  }
  return @{ pair = $Pair; interval = 'H4'; asOf = [DateTimeOffset]::UtcNow.ToString('o'); bars = $rows.ToArray() }
}

function Get-DxyState {
  $path = Join-Path $PSScriptRoot 'data/dxy-history.csv'
  if (-not (Test-Path $path)) { throw 'DXY history file is missing.' }
  $todayNY = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow,$nyZone).Date
  $bars = @(
    Import-Csv -Path $path | ForEach-Object {
      $day = [datetime]::ParseExact([string]$_.Date,'MM/dd/yyyy',[Globalization.CultureInfo]::InvariantCulture)
      $bar = @{ date = $day.ToString('yyyy-MM-dd'); open = [double]$_.Open;
        high = [double]$_.High; low = [double]$_.Low; close = [double]$_.Price;
        changePercent = [string]$_.'Change %'; partial = $day -ge $todayNY }
      if ($bar.high -lt [Math]::Max($bar.open,$bar.close) -or $bar.low -gt [Math]::Min($bar.open,$bar.close)) {
        throw "DXY CSV has an invalid OHLC row for $($bar.date)."
      }
      $bar
    } | Sort-Object date
  )
  # The source lists a short Sunday bar separately. Use full weekdays for daily trend and OTE.
  $completed = @($bars | Where-Object { -not $_.partial -and ([datetime]$_.date).DayOfWeek -notin @('Saturday','Sunday') })
  $bias = @{ kind = 'mixed'; reason = 'At least ten completed daily bars are needed.'; date = $null }
  if ($completed.Count -ge 10) {
    $last = $completed[-1]
    $ma5 = (@($completed | Select-Object -Last 5 | ForEach-Object { [double]$_.close }) | Measure-Object -Average).Average
    $previous5 = (@($completed | Select-Object -Skip ($completed.Count-10) -First 5 | ForEach-Object { [double]$_.close }) | Measure-Object -Average).Average
    $ma10 = (@($completed | Select-Object -Last 10 | ForEach-Object { [double]$_.close }) | Measure-Object -Average).Average
    $kind = if ($ma5 -gt $previous5 -and [double]$last.close -gt $ma10) { 'bullish' }
      elseif ($ma5 -lt $previous5 -and [double]$last.close -lt $ma10) { 'bearish' }
      else { 'mixed' }
    $bias = @{ kind = $kind; date = $last.date;
      reason = "Last completed close $([Math]::Round([double]$last.close,2)); latest 5-day average $([Math]::Round($ma5,2)); prior 5-day average $([Math]::Round($previous5,2)); 10-day average $([Math]::Round($ma10,2))." }
  }
  $ote = $null
  if ($completed.Count -and $bias.kind -in @('bullish','bearish')) {
    $day = $completed[-1]
    $range = [double]$day.high-[double]$day.low
    if ($range -gt 0) {
      $level = { param($fraction) if ($bias.kind -eq 'bullish') { [double]$day.high-$fraction*$range }
        else { [double]$day.low+$fraction*$range } }
      $p62 = & $level .62; $p705 = & $level .705; $p79 = & $level .79
      $ote = @{ date = $day.date; direction = $bias.kind; high = [double]$day.high; low = [double]$day.low;
        zoneLow = [Math]::Min($p62,$p79); zoneHigh = [Math]::Max($p62,$p79);
        p62 = [Math]::Round($p62,4); p705 = [Math]::Round($p705,4); p79 = [Math]::Round($p79,4);
        basis = 'Daily range estimate; intraday high/low sequence is unavailable in this CSV.' }
    }
  }
  return @{ symbol = 'DXY'; interval = 'D1'; source = 'User-supplied historical CSV';
    sourceUpdatedAt = (Get-Item $path).LastWriteTimeUtc.ToString('o'); bars = $bars; bias = $bias; ote = $ote }
}

function Get-NewsState {
  $path = Join-Path $PSScriptRoot 'data/forexfactory-calendar-current.csv'
  if (-not (Test-Path $path)) { return @{ source = 'Forex Factory weekly CSV export'; events = @(); importedAt = $null } }
  $events = @(
    Import-Csv -Path $path | Where-Object { $_.Impact -eq 'High' } | ForEach-Object {
      $date = [datetime]::ParseExact("$($_.Date) $($_.Time)",'MM-dd-yyyy h:mmtt',[Globalization.CultureInfo]::InvariantCulture)
      $utc = [datetime]::SpecifyKind($date,[DateTimeKind]::Utc)
      @{ time = $utc.ToString('o'); currency = [string]$_.Country; title = [string]$_.Title;
        impact = 'High'; forecast = [string]$_.Forecast; previous = [string]$_.Previous; url = [string]$_.URL }
    } | Sort-Object time,currency,title
  )
  return @{ source = 'Forex Factory weekly CSV export'; timezone = 'UTC'; importedAt = (Get-Item $path).LastWriteTimeUtc.ToString('o'); events = $events }
}

function Get-OpenMarks([string[]]$OpenPairs) {
  if (-not $OpenPairs.Count) { return @{} }
  $key = (@($OpenPairs | Sort-Object) -join ',')
  if ($script:quoteCache.key -eq $key -and [DateTimeOffset]::UtcNow -lt $script:quoteCache.expires) {
    return $script:quoteCache.marks
  }
  Resolve-Account
  $hostName = if ($script:environment -eq 'live') { 'api-fxtrade.oanda.com' } else { 'api-fxpractice.oanda.com' }
  $instruments = ($OpenPairs | ForEach-Object { $_.Replace('/','_') }) -join ','
  $accountId = [uri]::EscapeDataString($script:account)
  $url = "https://$hostName/v3/accounts/$accountId/pricing?instruments=$([uri]::EscapeDataString($instruments))"
  $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get,$url)
  $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$script:token)
  try {
    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    try {
      if (-not $response.IsSuccessStatusCode) { throw "OANDA pricing returned HTTP $([int]$response.StatusCode)." }
      $payload = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable -DateKind String
      $marks = @{}
      foreach ($quote in @($payload.prices)) {
        if (-not $quote.bids -or -not $quote.asks) { continue }
        $pair = ([string]$quote.instrument).Replace('_','/')
        $bid = [double]$quote.bids[0].price
        $ask = [double]$quote.asks[0].price
        $marks[$pair] = @{ bid = $bid; ask = $ask; time = [string]$quote.time; status = [string]$quote.status }
      }
      $script:quoteCache = @{ key = $key; expires = [DateTimeOffset]::UtcNow.AddSeconds(20); marks = $marks }
      return $marks
    } finally { $response.Dispose() }
  } finally { $request.Dispose() }
}

function Get-PaperState([switch]$AllTrades) {
  $path = Join-Path $PSScriptRoot 'data/paper-ledger-v2.json'
  if (-not (Test-Path $path)) {
    return @{ startedAt = $null; updatedAt = $null; errors = @(); open = @(); recent = @(); closedCount = 0; netPips = 0; pairTotals = @{} }
  }
  $ledger = Get-Content -Raw $path | ConvertFrom-Json -AsHashtable -DateKind String
  $open = @()
  $openPairs = @($ledger.pairs.Keys | Where-Object { $ledger.pairs[$_].position })
  $quoteError = $null
  $quotes = try { Get-OpenMarks $openPairs } catch { $quoteError = $_.Exception.Message; @{} }
  foreach ($pair in @($ledger.pairs.Keys | Sort-Object)) {
    $state = $ledger.pairs[$pair]
    if (-not $state.position) { continue }
    $pos = $state.position
    $pip = if ($pair.EndsWith('/JPY')) { 0.01 } else { 0.0001 }
    $sign = if ($pos.direction -eq 'long') { 1 } else { -1 }
    $quote = if ($quotes.ContainsKey($pair)) { $quotes[$pair] } else { $null }
    $mark = if ($quote) { ([double]$quote.bid+[double]$quote.ask)/2.0 } else { [double]$state.lastClose }
    $markTime = if ($quote) { [string]$quote.time } else { [string]$state.lastBar }
    $open += @{ pair = $pair; direction = $pos.direction; entry = $pos.entry; stop = $pos.stop; tp1 = $pos.tp1; origin = $pos.origin;
      entryTime = $pos.entryTime; signalTime = $pos.signalTime; signalPrice = $pos.signalPrice; signalOpen = $pos.signalOpen; signalClose = $pos.signalClose;
      armEma20 = $pos.armEma20; armEma50 = $pos.armEma50; armAtrRatio = $pos.armAtrRatio; armBias = $pos.armBias; practice = $pos.practice;
      signalDay = $pos.signalDay; reason = $pos.reason;
      mark = $mark; markPips = [Math]::Round($sign*($mark-[double]$pos.entry)/$pip,1);
      maxFavorablePips = $pos.maxFavorablePips; maxAdversePips = $pos.maxAdversePips;
      asOf = $markTime; markSource = if ($quote) { 'OANDA midpoint quote' } else { 'last completed M15 midpoint' } }
  }
  $trades = @($ledger.trades)
  $net = 0.0
  $pairTotals = @{}
  $nowUtc = [DateTimeOffset]::UtcNow
  $localNow = [TimeZoneInfo]::ConvertTime($nowUtc,$nyZone)
  $sunday = $localNow.Date.AddDays(-[int]$localNow.DayOfWeek)
  if ($localNow.DayOfWeek -eq [DayOfWeek]::Sunday -and $localNow.Hour -lt 17) { $sunday = $sunday.AddDays(-7) }
  $weekStartUtc = [TimeZoneInfo]::ConvertTimeToUtc($sunday.AddHours(17),$nyZone)
  foreach ($pair in $pairs) {
    $inOte = $false; $hasOte = $false; $hasPending = $false; $oteDistancePips = $null; $otePosition = $null
    if ($ledger.pairs.ContainsKey($pair) -and $ledger.pairs[$pair].ote) {
      $state = $ledger.pairs[$pair]
      $ote = $state.ote
      $recent = $ote.asOf -and ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse([string]$ote.asOf)).TotalMinutes -le 30
      $hasOte = [bool]$recent -and $ote.ContainsKey('low') -and $ote.ContainsKey('high') -and [double]$ote.high -gt [double]$ote.low
      $inOte = [bool]$ote.inZone -and [bool]$recent
      $hasPending = [bool]$hasOte -and [bool]$state.pending -and -not [bool]$state.position
      if ($hasOte -and $null -ne $state.lastClose) {
        $close = [double]$state.lastClose
        $pip = if ($pair.EndsWith('/JPY')) { 0.01 } else { 0.0001 }
        if ($close -lt [double]$ote.low) { $otePosition = 'below'; $oteDistancePips = ([double]$ote.low-$close)/$pip }
        elseif ($close -gt [double]$ote.high) { $otePosition = 'above'; $oteDistancePips = ($close-[double]$ote.high)/$pip }
        else { $otePosition = 'inside'; $oteDistancePips = 0.0 }
        $oteDistancePips = [Math]::Round($oteDistancePips,1)
      }
    }
    $pairTotals[$pair] = @{ closedPips = 0.0; livePips = 0.0; totalPips = 0.0; weeklyClosedPips = 0.0; weeklyLivePips = 0.0; weeklyNetPips = 0.0; hasOpen = $false;
      hasOte = $hasOte; inOte = $inOte; hasPending = $hasPending; oteDistancePips = $oteDistancePips; otePosition = $otePosition }
  }
  foreach ($trade in $trades) {
    $net += [double]$trade.netPips
    $pairTotals[[string]$trade.pair].closedPips += [double]$trade.netPips
    if ($trade.exitTime -and [DateTimeOffset]::Parse([string]$trade.exitTime).UtcDateTime -ge $weekStartUtc) {
      $pairTotals[[string]$trade.pair].weeklyClosedPips += [double]$trade.netPips
    }
  }
  foreach ($trade in $open) {
    $pairTotals[[string]$trade.pair].livePips = [double]$trade.markPips
    if ($trade.entryTime -and [DateTimeOffset]::Parse([string]$trade.entryTime).UtcDateTime -ge $weekStartUtc) {
      $pairTotals[[string]$trade.pair].weeklyLivePips = [double]$trade.markPips
    }
    $pairTotals[[string]$trade.pair].hasOpen = $true
  }
  foreach ($pair in $pairs) {
    $total = $pairTotals[$pair]
    $total.closedPips = [Math]::Round($total.closedPips,1)
    $total.totalPips = [Math]::Round($total.closedPips+$total.livePips,1)
    $total.weeklyClosedPips = [Math]::Round($total.weeklyClosedPips,1)
    $total.weeklyNetPips = [Math]::Round($total.weeklyClosedPips+$total.weeklyLivePips,1)
  }
  $closed = if ($AllTrades) { @($trades | Sort-Object exitTime -Descending) }
    else { @($trades | Sort-Object exitTime -Descending | Select-Object -First 50) }
  return @{ startedAt = $ledger.startedAt; updatedAt = $ledger.updatedAt; backfilledAt = $ledger.backfilledAt; errors = @($ledger.errors); quoteError = $quoteError; enginePairs = $ledger.pairs;
    open = $open; recent = $closed;
    closedCount = $trades.Count; netPips = [Math]::Round($net,1); pairTotals = $pairTotals }
}

function Close-PaperTrade([string]$Pair, [string]$EntryTime, [string]$LedgerPath = (Join-Path $PSScriptRoot 'data/paper-ledger-v2.json')) {
  if ($pairs -notcontains $Pair) { throw 'Unsupported currency pair.' }
  if (-not $EntryTime) { throw 'The open trade identifier is missing. Refresh the chart and try again.' }
  if (-not (Test-Path $ledgerPath)) { throw 'The paper ledger is unavailable.' }

  # Fetch a new closing-side quote. A stale candle or missing quote must not
  # silently become a manual exit price.
  $script:quoteCache.expires = [DateTimeOffset]::MinValue
  $quotes = Get-OpenMarks @($Pair)
  if (-not $quotes.ContainsKey($Pair)) { throw "No current OANDA quote is available for $Pair." }
  $quote = $quotes[$Pair]
  if ($quote.status -and $quote.status -ne 'tradeable') { throw "$Pair is not currently tradeable." }
  $quoteTime = [DateTimeOffset]::Parse([string]$quote.time)
  $now = [DateTimeOffset]::UtcNow
  if ([Math]::Abs(($now-$quoteTime).TotalSeconds) -gt 60) { throw "The OANDA quote for $Pair is stale. Try again when prices resume." }

  $ledgerLock = Enter-PaperLedgerLock $ledgerPath
  try {
    if ([Math]::Abs(([DateTimeOffset]::UtcNow-$quoteTime).TotalSeconds) -gt 60) {
      throw "The OANDA quote for $Pair is stale. Try again when prices resume."
    }
    $ledger = Get-Content -Raw $ledgerPath | ConvertFrom-Json -AsHashtable -DateKind String
    if (-not $ledger.pairs.ContainsKey($Pair) -or -not $ledger.pairs[$Pair].position) {
      throw "$Pair has no open paper trade. Refresh the chart."
    }
    $state = $ledger.pairs[$Pair]
    $pos = $state.position
    $requestedEntry=[DateTimeOffset]::Parse($EntryTime,[Globalization.CultureInfo]::InvariantCulture)
    $currentEntry=[DateTimeOffset]::Parse([string]$pos.entryTime,[Globalization.CultureInfo]::InvariantCulture)
    if ($currentEntry -ne $requestedEntry) { throw 'That paper trade has changed. Refresh the chart and try again.' }
    if ($pos.practice.status -in @('SUBMITTING','UNCERTAIN')) {
      $receipt=Get-V2PracticeOrderReceipt ([string]$pos.practice.clientId)
      if (-not $receipt.tradeId) { throw 'The practice order result is unresolved. Manual paper close cannot safely leave a possible OANDA trade open.' }
      $pos.practice=$receipt
    }
    if ($pos.practice.tradeId) {
      $closedPractice=Close-V2PracticeTrade $pos.practice
      foreach ($field in $closedPractice.Keys) { $pos.practice[$field]=$closedPractice[$field] }
    }
    $sign = if ($pos.direction -eq 'long') { 1 } else { -1 }
    $pip = if ($Pair.EndsWith('/JPY')) { 0.01 } else { 0.0001 }
    $exitPrice = ([double]$quote.bid+[double]$quote.ask)/2.0
    $pips = [Math]::Round($sign*($exitPrice-[double]$pos.entry)/$pip,1)
    $maxFavorable = [Math]::Max([double]$pos.maxFavorablePips,$pips)
    $maxAdverse = [Math]::Min([double]$pos.maxAdversePips,$pips)
    $trade = @{ pair = $Pair; direction = $pos.direction; origin = $pos.origin; pricing = 'midpoint';
      targetRule = $pos.targetRule; entryRule = $pos.entryRule; entryTarget = $pos.entryTarget;
      entryZoneLow = $pos.entryZoneLow; entryZoneHigh = $pos.entryZoneHigh;
      signalTime = $pos.signalTime; signalPrice = $pos.signalPrice;
      entry = $pos.entry; stop = $pos.stop; tp1 = $pos.tp1; entryTime = $pos.entryTime; signalDay = $pos.signalDay;
      reason = $pos.reason; practice = $pos.practice; exit = $exitPrice; exitTime = $now.ToString('o'); quoteTime = $quoteTime.ToString('o');
      exitReason = 'manual'; grossPips = $pips; netPips = $pips;
      maxFavorablePips = [Math]::Round($maxFavorable,1); maxAdversePips = [Math]::Round($maxAdverse,1) }
    $ledger.trades = @($ledger.trades) + @($trade)
    $state.position = $null
    $state.pending = $null
    $state.manualCloseTime = $now.ToString('o')
    $ledger.updatedAt = $now.ToString('o')
    Save-PaperLedger $ledgerPath $ledger
    return @{ trade = $trade; message = "$Pair paper trade closed at the current OANDA quote." }
  } finally { $ledgerLock.Dispose() }
}

function Write-Json($Context, $Object, [int]$Status = 200) {
  $bytes = [Text.Encoding]::UTF8.GetBytes(($Object | ConvertTo-Json -Depth 12 -Compress))
  $Context.Response.StatusCode = $Status
  $Context.Response.ContentType = 'application/json; charset=utf-8'
  $Context.Response.ContentLength64 = $bytes.Length
  $Context.Response.OutputStream.Write($bytes,0,$bytes.Length)
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Write-Host "Forex session chart v2: http://127.0.0.1:$Port/"
Write-Host 'OANDA credentials stay in this PowerShell process memory. Press Ctrl+C to stop.'
try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    try {
      $path = $context.Request.Url.AbsolutePath
      if ($path -eq '/' -and $context.Request.HttpMethod -eq 'GET') {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'index-v2.html'))
        $context.Response.ContentType = 'text/html; charset=utf-8'
        $context.Response.ContentLength64 = $bytes.Length
        $context.Response.OutputStream.Write($bytes,0,$bytes.Length)
      } elseif ($path -in @('/summary','/summary.html') -and $context.Request.HttpMethod -eq 'GET') {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'summary-v2.html'))
        $context.Response.ContentType = 'text/html; charset=utf-8'
        $context.Response.ContentLength64 = $bytes.Length
        $context.Response.OutputStream.Write($bytes,0,$bytes.Length)
      } elseif ($path -eq '/qqq' -and $context.Request.HttpMethod -eq 'GET') {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'qqq.html'))
        $context.Response.ContentType = 'text/html; charset=utf-8'
        $context.Response.ContentLength64 = $bytes.Length
        $context.Response.OutputStream.Write($bytes,0,$bytes.Length)
      } elseif ($path -eq '/api/qqq/backtest' -and $context.Request.HttpMethod -eq 'GET') {
        $studyPath = Join-Path $PSScriptRoot 'data/qqq-backtest-6mo.json'
        if (-not (Test-Path $studyPath)) {
          Write-Json $context @{ error = 'QQQ study data is not installed. Provide your own licensed M15 source data and run build-qqq-backtest.ps1.' } 404
        } else {
          $bytes = [IO.File]::ReadAllBytes($studyPath)
          $context.Response.ContentType = 'application/json; charset=utf-8'
          $context.Response.ContentLength64 = $bytes.Length
          $context.Response.OutputStream.Write($bytes,0,$bytes.Length)
        }
      } elseif ($path -eq '/api/config' -and $context.Request.HttpMethod -eq 'GET') {
        Write-Json $context @{ configured = [bool]$script:token; environment = $script:environment }
      } elseif ($path -eq '/api/config' -and $context.Request.HttpMethod -eq 'POST') {
        $origin = [string]$context.Request.Headers['Origin']
        if ($origin -and $origin -ne "http://127.0.0.1:$Port") { throw 'Settings must be submitted from the local chart.' }
        $reader = [IO.StreamReader]::new($context.Request.InputStream)
        try { $body = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable } finally { $reader.Dispose() }
        $token = [string]$body.token; $account = [string]$body.account
        if ($token.Length -lt 10 -or $account -notmatch '^[A-Za-z0-9-]+$') { throw 'Enter a valid OANDA token and account number.' }
        $script:token = $token; $script:account = $account
        $script:environment = if ($body.environment -eq 'live') { 'live' } else { 'practice' }
        $script:history = @{}; $script:historyWeek = ''
        Write-Json $context @{ configured = $true; environment = $script:environment }
      } elseif ($path -in @('/api/snapshot','/api/updates') -and $context.Request.HttpMethod -eq 'GET') {
        if (-not $script:token) { Write-Json $context @{ error = 'Enter OANDA credentials in Settings.' } 409 }
        else { Write-Json $context (Get-MarketState) }
      } elseif ($path -eq '/api/live' -and $context.Request.HttpMethod -eq 'GET') {
        if (-not $script:token) { Write-Json $context @{ error = 'Enter OANDA credentials in Settings.' } 409 }
        else { Write-Json $context (Get-LiveState -Pair ([uri]::UnescapeDataString($context.Request.QueryString['pair']))) }
      } elseif ($path -eq '/api/mobile-chart' -and $context.Request.HttpMethod -eq 'GET') {
        if (-not $script:token) { Write-Json $context @{ error = 'Enter OANDA credentials in Settings.' } 409 }
        else { Write-Json $context (Get-MobileChartState -Pair ([uri]::UnescapeDataString($context.Request.QueryString['pair']))) }
      } elseif ($path -eq '/api/h4' -and $context.Request.HttpMethod -eq 'GET') {
        if (-not $script:token) { Write-Json $context @{ error = 'Enter OANDA credentials in Settings.' } 409 }
        else { Write-Json $context (Get-H4State -Pair ([uri]::UnescapeDataString($context.Request.QueryString['pair']))) }
      } elseif ($path -eq '/dxy' -and $context.Request.HttpMethod -eq 'GET') {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'dxy.html'))
        $context.Response.ContentType = 'text/html; charset=utf-8'
        $context.Response.ContentLength64 = $bytes.Length
        $context.Response.OutputStream.Write($bytes,0,$bytes.Length)
      } elseif ($path -eq '/api/dxy' -and $context.Request.HttpMethod -eq 'GET') {
        Write-Json $context (Get-DxyState)
      } elseif ($path -eq '/api/news' -and $context.Request.HttpMethod -eq 'GET') {
        Write-Json $context (Get-NewsState)
      } elseif ($path -eq '/api/paper' -and $context.Request.HttpMethod -eq 'GET') {
        Write-Json $context (Get-PaperState)
      } elseif ($path -eq '/api/paper/all' -and $context.Request.HttpMethod -eq 'GET') {
        Write-Json $context (Get-PaperState -AllTrades)
      } elseif ($path -eq '/api/paper/close' -and $context.Request.HttpMethod -eq 'POST') {
        $origin = [string]$context.Request.Headers['Origin']
        if ($origin -ne "http://127.0.0.1:$Port") { Write-Json $context @{ error = 'Manual closes must come from the local chart.' } 403 }
        elseif ([string]$context.Request.ContentType -notmatch '^application/json(?:\s*;|$)') { Write-Json $context @{ error = 'Send a JSON request.' } 415 }
        else {
          $reader = [IO.StreamReader]::new($context.Request.InputStream)
          try { $body = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable -DateKind String } finally { $reader.Dispose() }
          Write-Json $context (Close-PaperTrade -Pair ([string]$body.pair) -EntryTime ([string]$body.entryTime))
        }
      } else { Write-Json $context @{ error = 'Not found.' } 404 }
    } catch {
      Write-Warning $_.Exception.Message
      Write-Warning $_.ScriptStackTrace
      if (-not $context.Response.HeadersWritten) {
        try { Write-Json $context @{ error = $_.Exception.Message } 500 } catch { }
      }
    } finally { $context.Response.OutputStream.Close() }
  }
} finally { $listener.Stop(); $listener.Close(); $client.Dispose() }
