# QQQ regular-session adaptation of the V2 OTE + Supertrend + EMA/ATR engine.
# Each day's OTE is fixed from the high and low of its first four M15 candles.
# That opening range is available only after the fourth candle closes at 10:30 NY.
# Inputs are Massive completed M15 trade aggregates; results are QQQ price points.
$script:V2Ny = [TimeZoneInfo]::FindSystemTimeZoneById('America/New_York')

function New-V2State {
  return @{ lastBar=$null; lastClose=$null; lastAskClose=$null; dayKey=$null; dayOpen=$null; dayHigh=$null; dayLow=$null; dayClose=$null;
    completeSession=$false; fibOpen=$null; fibHigh=$null; fibLow=$null; fibClose=$null; olderClose=$null;
    priorAtr=$null; atrSeed=0.0; atrDays=0; priorUpper=$null; priorLower=$null; priorDirection=1;
    ema20=$null; ema50=$null; atr14=$null; atr50=$null; atrSeed14=0.0; atrSeed50=0.0; atrCount=0; priorM15Close=$null;
    bias=0; killZone=0; entriesToday=0; touched=$false; pending=$null; position=$null; ote=$null; manualCloseTime=$null;
    swingBars=(New-Object 'System.Collections.Generic.List[object]'); swingHigh=$null; swingLow=$null;
    swingReady=$false; swingDirection=0; swingConfirmedAt=$null; swingDirectionSource=$null }
}

function Get-V2DayKey([DateTimeOffset]$Time) {
  $local = [TimeZoneInfo]::ConvertTime($Time,$script:V2Ny)
  return $local.Date.ToString('yyyy-MM-dd')
}

function Get-V2KillZone([DateTimeOffset]$Time) {
  $local = [TimeZoneInfo]::ConvertTime($Time,$script:V2Ny)
  $minutes = $local.Hour*60 + $local.Minute
  # The range may not be confirmed until midday; let it trade afterward.
  # The 15:45 candle is exit-only because positions must be flat at 16:00.
  if ($minutes -ge 570 -and $minutes -lt 945) { return 1 }
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

function Get-V2EntryBarExit([int]$Direction,[double]$Entry,[double]$Target,$Bar) {
  $points = if ($Direction -eq 1) { @([double]$Bar.open,[double]$Bar.low,[double]$Bar.high,[double]$Bar.close) }
    else { @([double]$Bar.open,[double]$Bar.high,[double]$Bar.low,[double]$Bar.close) }
  $filled = $points[0] -eq $Entry
  for ($j=0; $j -lt 3; $j++) {
    $a=$points[$j]; $b=$points[$j+1]
    if (-not $filled -and [Math]::Min($a,$b) -le $Entry -and [Math]::Max($a,$b) -ge $Entry) { $filled=$true; $a=$Entry }
    if ($filled) {
      if ([Math]::Min($a,$b) -le $Target -and [Math]::Max($a,$b) -ge $Target) { return @{ price=$Target; reason='tp1' } }
    }
  }
  return $null
}

function Close-V2Position($Ledger,$State,[string]$Pair,[double]$Exit,[string]$Reason,[DateTimeOffset]$ExitTime) {
  $pos=$State.position
  $sign=if ($pos.direction -eq 'long') { 1 } else { -1 }
  $pip=1.0
  $pips=[Math]::Round($sign*($Exit-[double]$pos.entry)/$pip,2)
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
    $State.completeSession=$true
    $State.swingBars.Clear(); $State.swingHigh=$null; $State.swingLow=$null
    $State.swingReady=$false; $State.swingDirection=0; $State.swingConfirmedAt=$null; $State.swingDirectionSource=$null; $State.ote=$null
  } else {
    $State.dayHigh=[Math]::Max([double]$State.dayHigh,$b.high)
    $State.dayLow=[Math]::Min([double]$State.dayLow,$b.low)
    $State.dayClose=$b.close
  }
  $State.swingBars.Add(@{ time=$time.ToString('o'); open=[double]$b.open; high=[double]$b.high; low=[double]$b.low; close=[double]$b.close })
  $count=$State.swingBars.Count
  if (-not $State.swingReady -and $count -eq 4) {
    $highIndex=0; $lowIndex=0
    for ($i=1; $i -lt 4; $i++) {
      if ([double]$State.swingBars[$i].high -gt [double]$State.swingBars[$highIndex].high) { $highIndex=$i }
      if ([double]$State.swingBars[$i].low -lt [double]$State.swingBars[$lowIndex].low) { $lowIndex=$i }
    }
    $hi=$State.swingBars[$highIndex]; $lo=$State.swingBars[$lowIndex]
    $State.swingHigh=@{ price=[double]$hi.high; time=[string]$hi.time; index=$highIndex }
    $State.swingLow=@{ price=[double]$lo.low; time=[string]$lo.time; index=$lowIndex }
    if ($lowIndex -eq $highIndex) {
      # OHLC cannot tell the intrabar path. Use the shared candle's body as
      # a documented tie-breaker, never as proof of which extreme came first.
      $shared=$State.swingBars[$lowIndex]
      $State.swingDirection=if ([double]$shared.close -ge [double]$shared.open) { 1 } else { -1 }
      $State.swingDirectionSource='same-bar-body-tie-break'
    } else {
      $State.swingDirection=if ($lowIndex -lt $highIndex) { 1 } else { -1 }
      $State.swingDirectionSource='extreme-bar-order'
    }
    $State.swingReady=$true; $State.swingConfirmedAt=$end.ToString('o')
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
  if ($State.swingReady -and $time -ge [DateTimeOffset]::Parse([string]$State.swingConfirmedAt)) {
    # Low then high is an upward opening impulse; high then low is downward.
    $start=if ($State.swingDirection -eq 1) { [double]$State.swingHigh.price } else { [double]$State.swingLow.price }
    $finish=if ($State.swingDirection -eq 1) { [double]$State.swingLow.price } else { [double]$State.swingHigh.price }
    $p62=$start+($finish-$start)*0.62; $p79=$start+($finish-$start)*0.79
    $zl=[Math]::Min($p62,$p79); $zh=[Math]::Max($p62,$p79)
    $State.ote=@{ low=$zl; high=$zh; p705=$start+($finish-$start)*0.705; inZone=$b.close -ge $zl -and $b.close -le $zh;
      direction=if ($State.swingDirection -eq 1) { 'bullish' } else { 'bearish' }; asOf=$end.ToString('o');
      swingHigh=[double]$State.swingHigh.price; swingLow=[double]$State.swingLow.price; confirmedAt=$State.swingConfirmedAt }
  } else { $State.ote=$null }
  $live=$end -gt $StartAt
  if ($State.manualCloseTime -and $time -le [DateTimeOffset]::Parse([string]$State.manualCloseTime)) { $live=$false }
  if ($live -and $State.position) {
    $pos=$State.position; $long=$pos.direction -eq 'long'
    $targetHit=if ($long) { $b.high -ge [double]$pos.tp1 } else { $b.low -le [double]$pos.tp1 }
    $exit=$null; $reason=$null
    if (($long -and $b.open -ge [double]$pos.tp1) -or (-not $long -and $b.open -le [double]$pos.tp1)) { $exit=$b.open; $reason='gap_tp1' }
    elseif ($targetHit) { $exit=[double]$pos.tp1; $reason='tp1' }
    if ($null -ne $exit) { Close-V2Position $Ledger $State $Pair $exit $reason $time }
    else {
      $pip=1.0; $sign=if ($long) { 1 } else { -1 }
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
      $long=$bias -eq 1; $target=if ($long) { [double]$pending.high } else { [double]$pending.low }
      $State.position=@{ pair=$Pair; direction=if ($long) { 'long' } else { 'short' }; entry=[double]$pending.entry; tp1=$target; stop=$null;
        entryTime=$time.ToString('o'); signalTime=$pending.signalTime; signalPrice=$pending.signalPrice; signalOpen=$pending.signalOpen; signalClose=$pending.signalPrice; signalDay=$key;
        entryRule='later-m15-705-touch'; entryTarget=[double]$pending.entry; entryZoneLow=[double]$pending.zoneLow; entryZoneHigh=[double]$pending.zoneHigh;
        targetRule='first-four-bar-extreme'; origin='historical-study'; pricing='aggregate'; reason='Daily ST bias; first four M15 bar OTE; M15 zone rejection; EMA20/50 and ATR14/50 arm filters';
        armEma20=$pending.ema20; armEma50=$pending.ema50; armAtrRatio=$pending.atrRatio; armBias=$pending.direction; maxFavorablePips=0.0; maxAdversePips=0.0 }
      $entryExit=Get-V2EntryBarExit $bias ([double]$pending.entry) $target $b
      if ($entryExit) { Close-V2Position $Ledger $State $Pair ([double]$entryExit.price) ([string]$entryExit.reason) $time }
      $State.pending=$null; $State.touched=$false
    }
  }
  if ($live -and $zone -ne 0 -and $State.completeSession -and $bias -ne 0 -and -not $State.pending -and -not $State.position -and $State.entriesToday -lt 2 -and -not $entered -and $State.ote -and [double]$State.swingHigh.price -gt [double]$State.swingLow.price) {
    $zl=[double]$State.ote.low; $zh=[double]$State.ote.high
    if ($b.low -le $zh -and $b.high -ge $zl) { $State.touched=$true }
    $rejected=if ($bias -eq 1) { $b.close -gt $zh } else { $b.close -lt $zl }
    if ($State.touched -and $rejected) {
      $emaOk=$bias*($ema20-$ema50) -gt 0
      $atrRatio=if ($null -ne $State.atr14 -and $null -ne $State.atr50 -and [double]$State.atr50 -gt 0) { [double]$State.atr14/[double]$State.atr50 } else { $null }
      if ($emaOk -and $null -ne $atrRatio -and $atrRatio -le 1.4) {
        $State.pending=@{ direction=$bias; signalTime=$time.ToString('o'); signalPrice=$b.close; signalOpen=$b.open; entry=[double]$State.ote.p705;
          high=[double]$State.swingHigh.price; low=[double]$State.swingLow.price; zoneLow=$zl; zoneHigh=$zh; ema20=$ema20; ema50=$ema50; atrRatio=$atrRatio }
      }
      $State.touched=$false
    }
  }
  $State.lastBar=$time.ToString('o'); $State.lastClose=$b.close; $State.lastAskClose=$b.askClose
}
