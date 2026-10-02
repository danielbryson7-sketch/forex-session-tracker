param([switch]$Once,[string]$OutputLedgerPath,[switch]$DefinitionsOnly,[switch]$NoNetwork,[switch]$DisablePracticeExecution)

$ErrorActionPreference='Stop'
$pairs=@('EUR/USD','GBP/USD','USD/JPY','USD/CHF','USD/CAD','AUD/USD','NZD/USD','EUR/GBP','EUR/JPY','EUR/CHF','EUR/CAD','EUR/AUD','EUR/NZD','GBP/JPY','GBP/CHF','GBP/CAD','GBP/AUD','GBP/NZD','AUD/JPY','AUD/CHF','AUD/CAD','AUD/NZD','NZD/JPY','NZD/CHF','NZD/CAD','CAD/JPY','CAD/CHF','CHF/JPY')
$script:token=[string]$env:OANDA_API_TOKEN
$script:account=[string]$env:OANDA_ACCOUNT_ID
$script:environment=if ($env:OANDA_ENVIRONMENT -eq 'live') { 'live' } else { 'practice' }
if (Test-Path (Join-Path $PSScriptRoot 'credentials-v2.local.ps1')) { . (Join-Path $PSScriptRoot 'credentials-v2.local.ps1') }
$script:client=[System.Net.Http.HttpClient]::new()
$script:client.Timeout=[TimeSpan]::FromSeconds(60)
$ledgerPath=if ($OutputLedgerPath) { [IO.Path]::GetFullPath($OutputLedgerPath) } else { Join-Path $PSScriptRoot 'data/paper-ledger-v2.json' }
[IO.Directory]::CreateDirectory((Split-Path $ledgerPath)) | Out-Null
. (Join-Path $PSScriptRoot 'ledger-io.ps1')
. (Join-Path $PSScriptRoot 'indicator-engine-v2.ps1')
. (Join-Path $PSScriptRoot 'practice-execution-v2.ps1')

function Resolve-V2Host {
  if (-not $script:token) { throw 'OANDA token is required for the v2 paper worker.' }
  $candidates=@($script:environment)
  foreach ($candidate in $candidates) {
    $hostName=if ($candidate -eq 'live') { 'api-fxtrade.oanda.com' } else { 'api-fxpractice.oanda.com' }
    $request=[System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get,"https://$hostName/v3/accounts")
    $request.Headers.Authorization=[System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$script:token)
    try {
      $response=$script:client.SendAsync($request).GetAwaiter().GetResult()
      try { if ($response.IsSuccessStatusCode) { return $hostName } }
      finally { $response.Dispose() }
    } finally { $request.Dispose() }
  }
  throw 'OANDA rejected the v2 paper worker token.'
}

function Get-V2Candles([string]$HostName,[string]$Pair,[DateTimeOffset]$From,[DateTimeOffset]$To) {
  $byTime=@{}
  $cursor=$From
  while ($cursor -lt $To) {
    $end=$cursor.AddDays(14)
    if ($end -gt $To) { $end=$To }
    $instrument=$Pair.Replace('/','_')
    $url="https://$HostName/v3/instruments/$instrument/candles?price=BA&granularity=M15"
    $url+='&from='+[uri]::EscapeDataString($cursor.UtcDateTime.ToString('o'))
    $url+='&to='+[uri]::EscapeDataString($end.UtcDateTime.ToString('o'))
    $request=[System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get,$url)
    $request.Headers.Authorization=[System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$script:token)
    try {
      $response=$script:client.SendAsync($request).GetAwaiter().GetResult()
      try {
        if (-not $response.IsSuccessStatusCode) { throw "OANDA HTTP $([int]$response.StatusCode) for $Pair M15" }
        $payload=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable -DateKind String
        foreach ($c in @($payload.candles)) {
          if (-not $c.complete -or $null -eq $c.bid -or $null -eq $c.ask) { continue }
          $byTime[[string]$c.time]=@{ time=[string]$c.time; dt=[DateTimeOffset]::Parse([string]$c.time);
            open=[double]$c.bid.o; high=[double]$c.bid.h; low=[double]$c.bid.l; close=[double]$c.bid.c;
            askOpen=[double]$c.ask.o; askHigh=[double]$c.ask.h; askLow=[double]$c.ask.l; askClose=[double]$c.ask.c }
        }
      } finally { $response.Dispose() }
    } finally { $request.Dispose() }
    $cursor=$end
  }
  return ,@($byTime.Keys | Sort-Object | ForEach-Object { $byTime[$_] })
}

function New-V2Ledger {
  return @{ version=2; engine='daily-ote-st-ema-atr-v3.pine'; pricing='OANDA M15 midpoint'; startedAt=[DateTimeOffset]::UtcNow.ToString('o');
    updatedAt=$null; pairs=@{}; trades=@(); events=@(); eventSeq=0; errors=@() }
}

function Scan-V2Pair($Ledger,[string]$Pair,[string]$HostName,[DateTimeOffset]$Now,[object[]]$M15Bars=$null) {
  $state=if ($Ledger.pairs.ContainsKey($Pair)) { $Ledger.pairs[$Pair] } else { New-V2State }
  $from=if ($state.lastBar) { [DateTimeOffset]::Parse([string]$state.lastBar).AddHours(-1) } else { $Now.AddDays(-60) }
  $bars=if ($null -ne $M15Bars) { $M15Bars } else { Get-V2Candles $HostName $Pair $from $Now }
  if (-not $bars.Count) { $Ledger.pairs[$Pair]=$state; return }
  if (-not $state.lastBar -and $bars.Count -gt 3500) { $bars=@($bars | Select-Object -Last 3500) }
  $startAt=[DateTimeOffset]::Parse([string]$Ledger.startedAt)
  foreach ($bar in $bars) {
    $barTime=if ($bar.dt) { [DateTimeOffset]$bar.dt } else { [DateTimeOffset]::Parse([string]$bar.time) }
    if ($state.lastBar -and $barTime -le [DateTimeOffset]::Parse([string]$state.lastBar)) { continue }
    $previousEntry=if ($state.position) { [string]$state.position.entryTime } else { '' }
    $previousClosedCount=@($Ledger.trades).Count
    Invoke-V2Bar $Ledger $state $Pair $bar $startAt
    if (@($Ledger.trades).Count -gt $previousClosedCount) {
      foreach ($closedTrade in @($Ledger.trades | Select-Object -Skip $previousClosedCount)) {
        if ($closedTrade.origin -eq 'live' -and -not $closedTrade.practice -and
            [DateTimeOffset]::Parse([string]$closedTrade.entryTime) -eq $barTime) {
          $closedTrade.practice=@{ status='SKIPPED_SAME_BAR'; reason='This trade opened and closed inside one completed M15 candle, before a practice order could be sent.' }
        }
      }
    }
    if ($state.position -and [string]$state.position.entryTime -ne $previousEntry -and -not $state.position.practice) {
      if ($DisablePracticeExecution) {
        $state.position.practice=@{ status='DISABLED' }
      } elseif ($Now-$barTime.AddMinutes(15) -gt [TimeSpan]::FromMinutes(2)) {
        $state.position.practice=@{ status='SKIPPED_STALE'; reason='The paper entry was discovered more than two minutes after its M15 candle closed.' }
      } else {
        $clientId='v2_'+$Pair.Replace('/','')+'_'+$barTime.ToUnixTimeSeconds()
        $plan=$null
        try { $plan=Get-V2PracticeOrderPlan $state.position $clientId }
        catch { $state.position.practice=@{ status='SKIPPED_PRECHECK'; reason=$_.Exception.Message } }
        if ($plan) {
          $state.position.practice=@{ status='SUBMITTING'; clientId=$clientId }
          $Ledger.pairs[$Pair]=$state
          Save-PaperLedger $ledgerPath $Ledger
          try { $state.position.practice=Submit-V2PracticeTrade $state.position $clientId $plan }
          catch {
            $message=$_.Exception.Message
            try {
              $receipt=Get-V2PracticeOrderReceipt $clientId
              if ($receipt.tradeId) { $state.position.practice=$receipt }
              elseif ($receipt.status -eq 'CANCELLED') { $state.position.practice=@{ status='NOT_FILLED'; clientId=$clientId; reason=$message } }
              else { $state.position.practice=@{ status='UNCERTAIN'; clientId=$clientId; reason=$message } }
            } catch { $state.position.practice=@{ status='UNCERTAIN'; clientId=$clientId; reason=$message } }
          }
        }
      }
      $Ledger.pairs[$Pair]=$state
      Save-PaperLedger $ledgerPath $Ledger
      $practiceStatus=if ($state.position.practice.status) { [string]$state.position.practice.status } else { 'UNKNOWN' }
      Write-Host "V2 practice $Pair entry $($state.position.entryTime): $practiceStatus."
    }
  }
  $Ledger.pairs[$Pair]=$state
}

function Reconcile-V2Practice($Ledger) {
  if ($DisablePracticeExecution) { return }
  # An older worker may have created paper trades before OANDA execution was
  # installed. Never submit those positions later at an unrelated market price.
  foreach ($pair in @($Ledger.pairs.Keys)) {
    $pos=$Ledger.pairs[$pair].position
    if ($pos -and $pos.origin -eq 'live' -and -not $pos.practice) {
      $pos.practice=@{ status='PAPER_ONLY'; reason='This trade was opened by a worker that did not record an OANDA submission. It will not be submitted retroactively.' }
      Save-PaperLedger $ledgerPath $Ledger
      Write-Warning "V2 practice $pair PAPER_ONLY: older open paper trade had no OANDA submission record."
    }
  }
  foreach ($trade in @($Ledger.trades)) {
    if ($trade.origin -eq 'live' -and -not $trade.practice) {
      $trade.practice=@{ status='PAPER_ONLY'; reason='This trade closed without an OANDA submission record.' }
      Save-PaperLedger $ledgerPath $Ledger
      Write-Warning "V2 practice $($trade.pair) PAPER_ONLY: closed paper trade had no OANDA submission record."
    }
  }
  foreach ($pair in @($Ledger.pairs.Keys)) {
    $pos=$Ledger.pairs[$pair].position
    if (-not $pos -or $pos.practice.status -notin @('SUBMITTING','UNCERTAIN')) { continue }
    try {
      $receipt=Get-V2PracticeOrderReceipt ([string]$pos.practice.clientId)
      if ($receipt.tradeId) { $pos.practice=$receipt; Save-PaperLedger $ledgerPath $Ledger }
      elseif ($receipt.status -eq 'CANCELLED') { $pos.practice=@{ status='NOT_FILLED'; clientId=[string]$pos.practice.clientId; reason='OANDA cancelled the order.' }; Save-PaperLedger $ledgerPath $Ledger }
    } catch { } # Never blindly repost an order whose result may be unknown.
  }
  foreach ($trade in @($Ledger.trades)) {
    if ($trade.origin -ne 'live' -or $trade.practice.status -notin @('SUBMITTING','UNCERTAIN')) { continue }
    try {
      $receipt=Get-V2PracticeOrderReceipt ([string]$trade.practice.clientId)
      if ($receipt.tradeId) { $trade.practice=$receipt; Save-PaperLedger $ledgerPath $Ledger }
      elseif ($receipt.status -eq 'CANCELLED') { $trade.practice=@{ status='NOT_FILLED'; clientId=[string]$trade.practice.clientId; reason='OANDA cancelled the order.' }; Save-PaperLedger $ledgerPath $Ledger }
    } catch { } # A lookup failure is not proof that no order filled.
  }
  foreach ($trade in @($Ledger.trades)) {
    if ($trade.origin -ne 'live' -or $trade.practice.status -notin @('OPEN','FILLED','CLOSE_ERROR','CLOSING')) { continue }
    try {
      $trade.practice.status='CLOSING'; Save-PaperLedger $ledgerPath $Ledger
      $closedPractice=Close-V2PracticeTrade $trade.practice
      foreach ($field in $closedPractice.Keys) { $trade.practice[$field]=$closedPractice[$field] }
      Save-PaperLedger $ledgerPath $Ledger
    } catch {
      $trade.practice.status='CLOSE_ERROR'; $trade.practice.reason=$_.Exception.Message
      Save-PaperLedger $ledgerPath $Ledger
    }
  }
}

function Scan-V2All {
  $lock=Enter-PaperLedgerLock $ledgerPath
  try {
    $ledger=if (Test-Path $ledgerPath) { Get-Content -Raw $ledgerPath | ConvertFrom-Json -AsHashtable -DateKind String } else { New-V2Ledger }
    if ($ledger.version -ne 2) { throw 'The v2 ledger path contains another format.' }
    $now=[DateTimeOffset]::UtcNow
    $errors=@()
    foreach ($pair in $pairs) {
      try { Scan-V2Pair $ledger $pair $script:hostName $now }
      catch { $errors+= "$($pair): $($_.Exception.Message)" }
    }
    Reconcile-V2Practice $ledger
    $ledger.updatedAt=[DateTimeOffset]::UtcNow.ToString('o'); $ledger.errors=$errors
    Save-PaperLedger $ledgerPath $ledger
    Write-Host "V2 scan $($ledger.updatedAt): $(@($ledger.trades).Count) closed; $(@($ledger.pairs.Values | Where-Object { $_.position }).Count) open; $($errors.Count) errors."
  } finally { $lock.Dispose() }
}

if ($DefinitionsOnly) { return }
try {
  Write-Host "V2 worker loaded $(Get-Date -Format o); practice execution=$(-not [bool]$DisablePracticeExecution); source=$(Get-Item $PSCommandPath | Select-Object -ExpandProperty LastWriteTimeUtc)."
  if (-not $NoNetwork) {
    if (-not $DisablePracticeExecution) { Assert-V2PracticeAccount }
    $script:hostName=Resolve-V2Host
  }
  if (-not (Test-Path $ledgerPath)) {
    $lock=Enter-PaperLedgerLock $ledgerPath
    try { if (-not (Test-Path $ledgerPath)) { Save-PaperLedger $ledgerPath (New-V2Ledger) } }
    finally { $lock.Dispose() }
  }
  if ($NoNetwork) { return }
  do {
    try { Scan-V2All } catch { Write-Warning "V2 scan failed: $($_.Exception.Message)" }
    if ($Once) { break }
    $next=[DateTimeOffset]::FromUnixTimeSeconds(([long]([Math]::Floor([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()/900)+1)*900)+20)
    Start-Sleep -Seconds ([int][Math]::Max(1,($next-[DateTimeOffset]::UtcNow).TotalSeconds))
  } while ($true)
} finally { $script:client.Dispose() }
