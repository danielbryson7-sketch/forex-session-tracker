function Get-V2DailySummary($Ledger,[datetime]$CutoffNy) {
  $ny = [TimeZoneInfo]::FindSystemTimeZoneById('America/New_York')
  $cutoffNy = [datetime]::SpecifyKind($CutoffNy,[DateTimeKind]::Unspecified)
  $dayStartNy = $cutoffNy.AddDays(-1)
  $weekStartNy = $cutoffNy.Date.AddDays(-[int]$cutoffNy.DayOfWeek).AddHours(17)
  $dayStart = [TimeZoneInfo]::ConvertTimeToUtc($dayStartNy,$ny)
  $weekStart = [TimeZoneInfo]::ConvertTimeToUtc($weekStartNy,$ny)
  $cutoff = [TimeZoneInfo]::ConvertTimeToUtc($cutoffNy,$ny)
  $live = @($Ledger.trades | Where-Object { $_.origin -eq 'live' })
  $dailyClosed = @($live | Where-Object {
    $_.exitTime -and ([DateTimeOffset]::Parse([string]$_.exitTime)).UtcDateTime -gt $dayStart -and
      ([DateTimeOffset]::Parse([string]$_.exitTime)).UtcDateTime -le $cutoff
  })
  $weeklyClosed = @($live | Where-Object {
    $_.exitTime -and ([DateTimeOffset]::Parse([string]$_.exitTime)).UtcDateTime -gt $weekStart -and
      ([DateTimeOffset]::Parse([string]$_.exitTime)).UtcDateTime -le $cutoff
  })
  $liveOpen = @($Ledger.pairs.Keys | ForEach-Object { $Ledger.pairs[$_].position } | Where-Object {
    $_ -and $_.origin -eq 'live'
  })
  $allEntries = @($live) + @($liveOpen)
  $dailyEntries = @($allEntries | Where-Object {
    $_.entryTime -and ([DateTimeOffset]::Parse([string]$_.entryTime)).UtcDateTime -gt $dayStart -and
      ([DateTimeOffset]::Parse([string]$_.entryTime)).UtcDateTime -le $cutoff
  }).Count
  $weeklyEntries = @($allEntries | Where-Object {
    $_.entryTime -and ([DateTimeOffset]::Parse([string]$_.entryTime)).UtcDateTime -gt $weekStart -and
      ([DateTimeOffset]::Parse([string]$_.entryTime)).UtcDateTime -le $cutoff
  }).Count
  $open = @($allEntries | Where-Object {
    $_.entryTime -and ([DateTimeOffset]::Parse([string]$_.entryTime)).UtcDateTime -le $cutoff -and
      (-not $_.exitTime -or ([DateTimeOffset]::Parse([string]$_.exitTime)).UtcDateTime -gt $cutoff)
  })
  $date = $cutoffNy.ToString('ddd MMM d, yyyy',[Globalization.CultureInfo]::InvariantCulture)
  $parts = @(
    ":bar_chart: *V2 paper trading summary — $date, 17:00 New York*"
    'Live-origin trades only · realized pips use the close time; entries use the entry time.'
    (Format-V2SummaryPeriod 'Today' $dailyEntries $dailyClosed)
    (Format-V2SummaryTable $dailyClosed)
    (Format-V2SummaryPeriod 'Week to date' $weeklyEntries $weeklyClosed)
    (Format-V2SummaryTable $weeklyClosed)
    "Open at cutoff: $($open.Count) · unrealized pips excluded."
  )
  return ($parts -join "`n")
}

function Format-V2SummaryPeriod([string]$Title,[int]$Entries,$Trades) {
  $wins = @($Trades | Where-Object { [double]$_.netPips -gt 0 })
  $losses = @($Trades | Where-Object { [double]$_.netPips -lt 0 })
  $flat = @($Trades | Where-Object { [double]$_.netPips -eq 0 }).Count
  $gained = 0.0; foreach ($trade in $wins) { $gained += [double]$trade.netPips }
  $lost = 0.0; foreach ($trade in $losses) { $lost -= [double]$trade.netPips }
  $decided = $wins.Count + $losses.Count
  $rate = if ($decided) { 100.0*$wins.Count/$decided } else { 0.0 }
  $culture = [Globalization.CultureInfo]::InvariantCulture
  $rateText = if ($decided) { "$($rate.ToString('F0',$culture))%" } else { 'n/a' }
  return "*$Title* · $Entries entered · $($Trades.Count) closed ($($wins.Count)W / $($losses.Count)L / ${flat} flat) · win rate $rateText · gained +$($gained.ToString('F1',$culture)) · lost -$($lost.ToString('F1',$culture)) · *net $(($gained-$lost).ToString('+0.0;-0.0;0.0',$culture)) pips*"
}

function Format-V2SummaryTable($Trades) {
  $rows = @()
  foreach ($group in @($Trades | Group-Object pair)) {
    $gained = 0.0; $lost = 0.0; $wins = 0; $losses = 0
    foreach ($trade in $group.Group) {
      $pips = [double]$trade.netPips
      if ($pips -gt 0) { $gained += $pips; $wins++ }
      elseif ($pips -lt 0) { $lost -= $pips; $losses++ }
    }
    $rows += [pscustomobject]@{ Pair=[string]$group.Name; Wins=$wins; Losses=$losses; Gained=$gained; Lost=$lost; Net=$gained-$lost }
  }
  $rows = @($rows | Sort-Object @{Expression='Net';Descending=$true},@{Expression='Pair';Descending=$false})
  $culture = [Globalization.CultureInfo]::InvariantCulture
  $lines = @('```','PAIR       W-L   GAIN   LOSS     NET','----------------------------------')
  foreach ($row in $rows) {
    $wl = "$($row.Wins)-$($row.Losses)"
    $gain = $row.Gained.ToString('F1',$culture)
    $loss = $row.Lost.ToString('F1',$culture)
    $net = $row.Net.ToString('+0.0;-0.0;0.0',$culture)
    $lines += ('{0,-9} {1,3} {2,6} {3,6} {4,7}' -f $row.Pair,$wl,$gain,$loss,$net)
  }
  if (-not $rows.Count) { $lines += 'No closed trades.' }
  $lines += '```'
  return ($lines -join "`n")
}
