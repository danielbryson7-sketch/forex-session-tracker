# Daily OTE + Supertrend + EMA/ATR Filter, translated from daily-ote-st-ema-atr-v3.pine.
# All indicator prices use the midpoint of completed OANDA M15 bid/ask candles.
$script:V2Ny = [TimeZoneInfo]::FindSystemTimeZoneById('America/New_York')

function New-V2State {
  return @{ lastBar=$null; lastClose=$null; lastAskClose=$null; dayKey=$null; dayOpen=$null; dayHigh=$null; dayLow=$null; dayClose=$null;
    completeSession=$false; fibOpen=$null; fibHigh=$null; fibLow=$null; fibClose=$null; olderClose=$null;
    priorAtr=$null; atrSeed=0.0; atrDays=0; priorUpper=$null; priorLower=$null; priorDirection=1;
    ema20=$null; ema50=$null; atr14=$null; atr50=$null; atrSeed14=0.0; atrSeed50=0.0; atrCount=0; priorM15Close=$null;
    bias=0; killZone=0; entriesToday=0; touched=$false; pending=$null; position=$null; ote=$null; manualCloseTime=$null }
}

function Get-V2DayKey([DateTimeOffset]$Time) {
  $local = [TimeZoneInfo]::ConvertTime($Time,$script:V2Ny)
  $date = $local.Date
  if ($local.Hour -ge 17) { $date = $date.AddDays(1) }
  return $date.ToString('yyyy-MM-dd')
}

function Get-V2KillZone([DateTimeOffset]$Time) {
  $local = [TimeZoneInfo]::ConvertTime($Time,$script:V2Ny)
  $minutes = $local.Hour*60 + $local.Minute
  if ($minutes -ge 0 -and $minutes -lt 300) { return 1 }
  if ($minutes -ge 420 -and $minutes -lt 600) { return 2 }
  if ($minutes -ge 600 -and $minutes -lt 720) { return 3 }
  return 0
}

function Get-V2MidBar($Bar) {
  $dt = if ($Bar.dt) { [DateTimeOffset]$Bar.dt } else { [DateTimeOffset]::Parse([string]$Bar.time) }
  $mid = @{ time=$dt.ToString('o'); dt=$dt }
  foreach ($name in @('open','high','low','close')) {
    $askName = 'ask' + $name.Substring(0,1).ToUpperInvariant() + $name.Substring(1)
    $mid[$name] = ([double]$Bar[$name]+[double]$Bar[$askName])/2.0
  }
  $mid.askClose = [double]$Bar.askClose
  return $mid
}

function Get-V2EntryBarExit([int]$Direction,[double]$Entry,[double]$Target,[double]$Stop,$Bar) {
  $points = if ($Direction -eq 1) { @([double]$Bar.open,[double]$Bar.low,[double]$Bar.high,[double]$Bar.close) }
    else { @([double]$Bar.open,[double]$Bar.high,[double]$Bar.low,[double]$Bar.close) }
  $filled = $points[0] -eq $Entry
  for ($j=0; $j -lt 3; $j++) {
    $a=$points[$j]; $b=$points[$j+1]
    if (-not $filled -and [Math]::Min($a,$b) -le $Entry -and [Math]::Max($a,$b) -ge $Entry) { $filled=$true; $a=$Entry }
    if ($filled) {
      if ([Math]::Min($a,$b) -le $Stop -and [Math]::Max($a,$b) -ge $Stop) { return @{ price=$Stop; reason='stop' } }
      if ([Math]::Min($a,$b) -le $Target -and [Math]::Max($a,$b) -ge $Target) { return @{ price=$Target; reason='tp1' } }
    }
  }
  return $null
}

function Close-V2Position($Ledger,$State,[string]$Pair,[double]$Exit,[string]$Reason,[DateTimeOffset]$ExitTime) {
  $pos=$State.position
  $sign=if ($pos.direction -eq 'long') { 1 } else { -1 }
  $pip=if ($Pair.EndsWith('/JPY')) { 0.01 } else { 0.0001 }
  $pips=[Math]::Round($sign*($Exit-[double]$pos.entry)/$pip,1)
  $trade=@{} + $pos
  $trade.Remove('maxFavorablePips') | Out-Null
  $trade.Remove('maxAdversePips') | Out-Null
  $trade.exit=$Exit; $trade.exitTime=$ExitTime.ToString('o'); $trade.exitReason=$Reason
  $trade.grossPips=$pips; $trade.netPips=$pips
  $trade.maxFavorablePips=[Math]::Max([double]$pos.maxFavorablePips,$pips)
  $trade.maxAdversePips=[Math]::Min([double]$pos.maxAdversePips,$pips)
  $Ledger.trades=@($Ledger.trades)+@($trade)
  $State.position=$null
}

function Add-V2SignalEvent($Ledger,[string]$Kind,[string]$Pair,[DateTimeOffset]$Time,$Details) {
  if (-not $Ledger.ContainsKey('eventSeq')) { $Ledger.eventSeq=0 }
  if (-not $Ledger.ContainsKey('events')) { $Ledger.events=@() }
  $Ledger.eventSeq=[long]$Ledger.eventSeq+1
  $event=@{ seq=$Ledger.eventSeq; kind=$Kind; pair=$Pair; time=$Time.ToString('o') }
  foreach ($key in $Details.Keys) { $event[$key]=$Details[$key] }
  $Ledger.events=@($Ledger.events)+@($event)
  if ($Ledger.events.Count -gt 2000) { $Ledger.events=@($Ledger.events | Select-Object -Last 2000) }
}

function Invoke-V2Bar($Ledger,$State,[string]$Pair,$Bar,[DateTimeOffset]$StartAt) {
  $b=Get-V2MidBar $Bar
  $time=$b.dt; $end=$time.AddMinutes(15); $key=Get-V2DayKey $time
  $local=[TimeZoneInfo]::ConvertTime($time,$script:V2Ny)
  $newDay=$null -eq $State.dayKey -or $State.dayKey -ne $key
  if ($newDay -and $null -ne $State.dayKey) {
    $State.fibOpen=$State.dayOpen; $State.fibHigh=$State.dayHigh; $State.fibLow=$State.dayLow; $State.fibClose=$State.dayClose
    $tr=[double]$State.fibHigh-[double]$State.fibLow
    if ($null -ne $State.olderClose) { $tr=[Math]::Max($tr,[Math]::Max([Math]::Abs([double]$State.fibHigh-[double]$State.olderClose),[Math]::Abs([double]$State.fibLow-[double]$State.olderClose))) }
    $State.atrDays++
    $wasReady=$null -ne $State.priorAtr
    if ($State.atrDays -le 10) {
      $State.atrSeed += $tr
      if ($State.atrDays -eq 10) { $State.priorAtr=$State.atrSeed/10.0 }
    } else { $State.priorAtr=([double]$State.priorAtr*9.0+$tr)/10.0 }
    if ($null -ne $State.priorAtr) {
      $upper=([double]$State.fibHigh+[double]$State.fibLow)/2+3*[double]$State.priorAtr
      $lower=([double]$State.fibHigh+[double]$State.fibLow)/2-3*[double]$State.priorAtr
      $oldUpper=if ($null -eq $State.priorUpper) { $upper } else { [double]$State.priorUpper }
      $oldLower=if ($null -eq $State.priorLower) { $lower } else { [double]$State.priorLower }
      if (-not ($upper -lt $oldUpper -or ($null -ne $State.olderClose -and [double]$State.olderClose -gt $oldUpper))) { $upper=$oldUpper }
      if (-not ($lower -gt $oldLower -or ($null -ne $State.olderClose -and [double]$State.olderClose -lt $oldLower))) { $lower=$oldLower }
      if (-not $wasReady) { $State.priorDirection=1 }
      elseif ($State.priorDirection -lt 0) { $State.priorDirection=if ([double]$State.fibClose -lt $lower) { 1 } else { -1 } }
      else { $State.priorDirection=if ([double]$State.fibClose -gt $upper) { -1 } else { 1 } }
      $State.priorUpper=$upper; $State.priorLower=$lower
    }
    $State.olderClose=$State.fibClose
  }
  if ($newDay) {
    $State.dayKey=$key; $State.dayOpen=$b.open; $State.dayHigh=$b.high; $State.dayLow=$b.low; $State.dayClose=$b.close
    $State.completeSession=$local.Hour -eq 17 -and $local.Minute -eq 0
  } else {
    $State.dayHigh=[Math]::Max([double]$State.dayHigh,$b.high)
    $State.dayLow=[Math]::Min([double]$State.dayLow,$b.low)
    $State.dayClose=$b.close
  }
  $ema20=if ($null -eq $State.ema20) { $b.close } else { [double]$State.ema20+2.0/21.0*($b.close-[double]$State.ema20) }
  $ema50=if ($null -eq $State.ema50) { $b.close } else { [double]$State.ema50+2.0/51.0*($b.close-[double]$State.ema50) }
  $State.ema20=$ema20; $State.ema50=$ema50
  $m15tr=$b.high-$b.low
  if ($null -ne $State.priorM15Close) { $m15tr=[Math]::Max($m15tr,[Math]::Max([Math]::Abs($b.high-[double]$State.priorM15Close),[Math]::Abs($b.low-[double]$State.priorM15Close))) }
  $State.atrCount++
  if ($null -eq $State.atr14) { $State.atrSeed14 += $m15tr; if ($State.atrCount -eq 14) { $State.atr14=$State.atrSeed14/14.0 } }
  else { $State.atr14=([double]$State.atr14*13.0+$m15tr)/14.0 }
  if ($null -eq $State.atr50) { $State.atrSeed50 += $m15tr; if ($State.atrCount -eq 50) { $State.atr50=$State.atrSeed50/50.0 } }
  else { $State.atr50=([double]$State.atr50*49.0+$m15tr)/50.0 }
  $State.priorM15Close=$b.close
  $bias=0; $st=$null
  if ($State.completeSession -and $null -ne $State.priorAtr -and $null -ne $State.fibClose) {
    $tr=[Math]::Max([double]$State.dayHigh-[double]$State.dayLow,[Math]::Max([Math]::Abs([double]$State.dayHigh-[double]$State.fibClose),[Math]::Abs([double]$State.dayLow-[double]$State.fibClose)))
    $atr=([double]$State.priorAtr*9+$tr)/10
    $upper=([double]$State.dayHigh+[double]$State.dayLow)/2+3*$atr
    $lower=([double]$State.dayHigh+[double]$State.dayLow)/2-3*$atr
    if (-not ($upper -lt [double]$State.priorUpper -or [double]$State.fibClose -gt [double]$State.priorUpper)) { $upper=[double]$State.priorUpper }
    if (-not ($lower -gt [double]$State.priorLower -or [double]$State.fibClose -lt [double]$State.priorLower)) { $lower=[double]$State.priorLower }
    $direction=if ($State.priorDirection -lt 0) { if ($b.close -lt $lower) { 1 } else { -1 } } else { if ($b.close -gt $upper) { -1 } else { 1 } }
    $bias=if ($direction -lt 0) { 1 } else { -1 }
    $st=if ($direction -lt 0) { $lower } else { $upper }
  }
  $zone=Get-V2KillZone $time
  if ($newDay) { $State.entriesToday=0; $State.touched=$false; $State.pending=$null }
  if ($bias -ne [int]$State.bias -or $zone -ne [int]$State.killZone) { $State.touched=$false; $State.pending=$null }
  $State.bias=$bias; $State.killZone=$zone; $State.dailyST=$st
  if ($null -ne $State.fibLow) {
    $start=if ([double]$State.fibClose -gt [double]$State.fibOpen) { [double]$State.fibHigh } else { [double]$State.fibLow }
    $finish=if ([double]$State.fibClose -gt [double]$State.fibOpen) { [double]$State.fibLow } else { [double]$State.fibHigh }
    $p62=$start+($finish-$start)*0.62; $p79=$start+($finish-$start)*0.79
    $zl=[Math]::Min($p62,$p79); $zh=[Math]::Max($p62,$p79)
    $State.ote=@{ low=$zl; high=$zh; p705=$start+($finish-$start)*0.705; inZone=$b.close -ge $zl -and $b.close -le $zh;
      direction=if ($bias -eq 1) { 'bullish' } elseif ($bias -eq -1) { 'bearish' } else { 'mixed' }; asOf=$end.ToString('o'); priorHigh=$State.fibHigh; priorLow=$State.fibLow }
  }
  $live=$end -gt $StartAt
  if ($State.manualCloseTime -and $time -le [DateTimeOffset]::Parse([string]$State.manualCloseTime)) { $live=$false }
  if ($live -and $State.position) {
    $pos=$State.position; $long=$pos.direction -eq 'long'
    $stopHit=if ($long) { $b.low -le [double]$pos.stop } else { $b.high -ge [double]$pos.stop }
    $targetHit=if ($long) { $b.high -ge [double]$pos.tp1 } else { $b.low -le [double]$pos.tp1 }
    $exit=$null; $reason=$null
    if (($long -and $b.open -le [double]$pos.stop) -or (-not $long -and $b.open -ge [double]$pos.stop)) { $exit=$b.open; $reason='gap_stop' }
    elseif (($long -and $b.open -ge [double]$pos.tp1) -or (-not $long -and $b.open -le [double]$pos.tp1)) { $exit=$b.open; $reason='gap_tp1' }
    elseif ($stopHit -or $targetHit) { if ($stopHit) { $exit=[double]$pos.stop; $reason='stop' } else { $exit=[double]$pos.tp1; $reason='tp1' } }
    if ($null -ne $exit) { Close-V2Position $Ledger $State $Pair $exit $reason $time }
    else {
      $pip=if ($Pair.EndsWith('/JPY')) { 0.01 } else { 0.0001 }; $sign=if ($long) { 1 } else { -1 }
      $best=[Math]::Max(($sign*($b.high-[double]$pos.entry)/$pip),($sign*($b.low-[double]$pos.entry)/$pip))
      $worst=[Math]::Min(($sign*($b.high-[double]$pos.entry)/$pip),($sign*($b.low-[double]$pos.entry)/$pip))
      $State.position.maxFavorablePips=[Math]::Max([double]$pos.maxFavorablePips,$best)
      $State.position.maxAdversePips=[Math]::Min([double]$pos.maxAdversePips,$worst)
    }
  }
  $entered=$false
  if ($live -and $zone -ne 0 -and $State.pending -and -not $State.position -and $State.entriesToday -lt 2 -and $State.pending.direction -eq $bias -and $time -gt [DateTimeOffset]::Parse([string]$State.pending.signalTime)) {
    $pending=$State.pending
    if ($b.low -le [double]$pending.entry -and $b.high -ge [double]$pending.entry) {
      $entered=$true; $State.entriesToday++
      $long=$bias -eq 1; $target=if ($long) { [double]$pending.high } else { [double]$pending.low }; $stop=if ($long) { [double]$pending.low } else { [double]$pending.high }
      $State.position=@{ pair=$Pair; direction=if ($long) { 'long' } else { 'short' }; entry=[double]$pending.entry; tp1=$target; stop=$stop;
        entryTime=$time.ToString('o'); signalTime=$pending.signalTime; signalPrice=$pending.signalPrice; signalOpen=$pending.signalOpen; signalClose=$pending.signalPrice; signalDay=$key;
        entryRule='later-m15-705-touch'; entryTarget=[double]$pending.entry; entryZoneLow=[double]$pending.zoneLow; entryZoneHigh=[double]$pending.zoneHigh;
        targetRule='prior-day-extreme'; origin='live'; pricing='midpoint'; reason='Daily ST bias; prior-day candle fib; M15 zone rejection; EMA20/50 and ATR14/50 arm filters';
        armEma20=$pending.ema20; armEma50=$pending.ema50; armAtrRatio=$pending.atrRatio; armBias=$pending.direction; maxFavorablePips=0.0; maxAdversePips=0.0 }
      $entryExit=Get-V2EntryBarExit $bias ([double]$pending.entry) $target $stop $b
      if ($entryExit) { Close-V2Position $Ledger $State $Pair ([double]$entryExit.price) ([string]$entryExit.reason) $time }
      $State.pending=$null; $State.touched=$false
    }
  }
  if ($live -and $zone -ne 0 -and $State.completeSession -and $bias -ne 0 -and -not $State.pending -and -not $State.position -and $State.entriesToday -lt 2 -and -not $entered -and $State.ote -and [double]$State.fibHigh -gt [double]$State.fibLow) {
    $zl=[double]$State.ote.low; $zh=[double]$State.ote.high
    if ($b.low -le $zh -and $b.high -ge $zl) {
      if (-not $State.touched) {
        Add-V2SignalEvent $Ledger 'ote' $Pair $end @{ dayKey=$key; zoneLow=$zl; zoneHigh=$zh }
      }
      $State.touched=$true
    }
    $rejected=if ($bias -eq 1) { $b.close -gt $zh } else { $b.close -lt $zl }
    if ($State.touched -and $rejected) {
      $emaOk=$bias*($ema20-$ema50) -gt 0
      $atrRatio=if ($null -ne $State.atr14 -and $null -ne $State.atr50 -and [double]$State.atr50 -gt 0) { [double]$State.atr14/[double]$State.atr50 } else { $null }
      if ($emaOk -and $null -ne $atrRatio -and $atrRatio -le 1.4) {
        $State.pending=@{ direction=$bias; signalTime=$time.ToString('o'); signalPrice=$b.close; signalOpen=$b.open; entry=[double]$State.ote.p705;
          high=[double]$State.fibHigh; low=[double]$State.fibLow; zoneLow=$zl; zoneHigh=$zh; ema20=$ema20; ema50=$ema50; atrRatio=$atrRatio }
        Add-V2SignalEvent $Ledger 'armed' $Pair $end @{ dayKey=$key; pending=$State.pending }
      }
      $State.touched=$false
    }
  }
  $State.lastBar=$time.ToString('o'); $State.lastClose=$b.close; $State.lastAskClose=$b.askClose
}
