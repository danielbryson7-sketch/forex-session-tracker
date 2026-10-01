# OANDA practice execution for V2. Never route these functions to a live host.
$script:V2PracticeUsdPerPip = 0.25
$script:V2InstrumentSpecs = $null

function Assert-V2PracticeAccount {
  if ($script:environment -ne 'practice') { throw 'V2 practice execution refuses a live OANDA environment.' }
  if (-not $script:token -or -not $script:account) { throw 'V2 practice execution needs a practice token and account ID.' }
}

function Invoke-V2PracticeApi([string]$Method,[string]$Path,$Body=$null) {
  Assert-V2PracticeAccount
  $url='https://api-fxpractice.oanda.com/v3/accounts/'+[uri]::EscapeDataString($script:account)+$Path
  $request=[System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method),$url)
  $request.Headers.Authorization=[System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$script:token)
  if ($null -ne $Body) { $request.Content=[System.Net.Http.StringContent]::new(($Body | ConvertTo-Json -Depth 12 -Compress),[Text.Encoding]::UTF8,'application/json') }
  try {
    $response=$script:client.SendAsync($request).GetAwaiter().GetResult()
    try {
      $content=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      if (-not $response.IsSuccessStatusCode) {
        $message=try { $parsed=$content | ConvertFrom-Json -AsHashtable; [string]($parsed.errorMessage ?? $parsed.message) } catch { '' }
        if (-not $message) { $message="HTTP $([int]$response.StatusCode)" }
        throw "OANDA practice $Method failed: $message"
      }
      if (-not $content) { return @{} }
      return ($content | ConvertFrom-Json -AsHashtable -DateKind String)
    } finally { $response.Dispose() }
  } finally { $request.Dispose() }
}

function Get-V2InstrumentSpec([string]$Pair) {
  if ($null -eq $script:V2InstrumentSpecs) {
    $payload=Invoke-V2PracticeApi 'GET' '/instruments'
    $script:V2InstrumentSpecs=@{}
    foreach ($item in @($payload.instruments)) { $script:V2InstrumentSpecs[[string]$item.name]=$item }
  }
  $name=$Pair.Replace('/','_')
  if (-not $script:V2InstrumentSpecs.ContainsKey($name)) { throw "$Pair is unavailable in the practice account." }
  return $script:V2InstrumentSpecs[$name]
}

function Format-V2OrderPrice([double]$Price,[int]$Digits) {
  return [Math]::Round($Price,$Digits).ToString("F$Digits",[Globalization.CultureInfo]::InvariantCulture)
}

function Get-V2PracticeOrderPlan($Position,[string]$ClientId) {
  $pair=[string]$Position.pair; $instrument=$pair.Replace('/','_')
  $spec=Get-V2InstrumentSpec $pair
  $existing=Invoke-V2PracticeApi 'GET' ('/trades?state=OPEN&instrument='+[uri]::EscapeDataString($instrument))
  if (@($existing.trades).Count -gt 0) { throw "An OANDA practice trade is already open for $pair; no second order was sent." }
  $pricing=Invoke-V2PracticeApi 'GET' ('/pricing?instruments='+[uri]::EscapeDataString($instrument)+'&includeHomeConversions=true')
  $quote=@($pricing.prices | Where-Object { $_.instrument -eq $instrument }) | Select-Object -First 1
  if (-not $quote -or -not $quote.bids -or -not $quote.asks -or $quote.status -ne 'tradeable') { throw "No tradeable practice quote for $pair." }
  if ([Math]::Abs(([DateTimeOffset]::UtcNow-[DateTimeOffset]::Parse([string]$quote.time)).TotalSeconds) -gt 30) { throw "Practice quote for $pair is stale." }
  $account=Invoke-V2PracticeApi 'GET' '/summary'
  if ($account.account.currency -ne 'USD') { throw 'The $0.25-per-pip sizing currently requires a USD practice account.' }
  $quoteCurrency=$pair.Substring(4,3)
  $conversion=@($pricing.homeConversions | Where-Object { $_.currency -eq $quoteCurrency }) | Select-Object -First 1
  if (-not $conversion -or [double]$conversion.positionValue -le 0) { throw "No USD conversion for $quoteCurrency." }
  $pip=[Math]::Pow(10,[int]$spec.pipLocation)
  $precision=[int]$spec.tradeUnitsPrecision
  $increment=[Math]::Pow(10,-$precision)
  $units=[Math]::Round(($script:V2PracticeUsdPerPip/($pip*[double]$conversion.positionValue))/$increment,0)*$increment
  if ($units -lt [double]$spec.minimumTradeSize) { throw "The $0.25-per-pip size is below the minimum for $pair." }
  $long=$Position.direction -eq 'long'; $bid=[double]$quote.bids[0].price; $ask=[double]$quote.asks[0].price
  $stop=[double]$Position.stop; $target=[double]$Position.tp1; $entryQuote=if ($long) { $ask } else { $bid }
  if (($long -and ($stop -ge $entryQuote -or $target -le $entryQuote)) -or (-not $long -and ($stop -le $entryQuote -or $target -ge $entryQuote))) {
    throw "The current $pair quote has passed the paper stop or target; practice order skipped."
  }
  $digits=[int]$spec.displayPrecision
  $bound=if ($long) { $ask+2*$pip } else { $bid-2*$pip }
  $signed=if ($long) { $units } else { -$units }
  $order=@{ type='MARKET'; instrument=$instrument; units=$signed.ToString("F$precision",[Globalization.CultureInfo]::InvariantCulture);
    timeInForce='FOK'; positionFill='OPEN_ONLY'; priceBound=(Format-V2OrderPrice $bound $digits);
    stopLossOnFill=@{ price=(Format-V2OrderPrice $stop $digits); timeInForce='GTC' };
    takeProfitOnFill=@{ price=(Format-V2OrderPrice $target $digits); timeInForce='GTC' };
    clientExtensions=@{ id=$ClientId; tag='codex_v2_practice' } }
  return @{ order=$order; units=$units; dollarsPerPip=$units*$pip*[double]$conversion.positionValue;
    quoteTime=[string]$quote.time; quoteBid=$bid; quoteAsk=$ask }
}

function Get-V2PracticeOrderReceipt([string]$ClientId) {
  $path='/orders/@'+[uri]::EscapeDataString($ClientId)
  $result=Invoke-V2PracticeApi 'GET' $path
  $order=$result.order
  if (-not $order) { throw 'Practice order lookup returned no order.' }
  $receipt=@{ status=[string]$order.state; clientId=$ClientId; orderId=[string]$order.id }
  if ($order.tradeOpenedID) { $receipt.tradeId=[string]$order.tradeOpenedID }
  if ($order.fillingTransactionID) {
    try {
      $tx=Invoke-V2PracticeApi 'GET' ('/transactions/'+[uri]::EscapeDataString([string]$order.fillingTransactionID))
      if ($tx.transaction.tradeOpened.tradeID) { $receipt.tradeId=[string]$tx.transaction.tradeOpened.tradeID }
      if ($tx.transaction.price) { $receipt.fillPrice=[double]$tx.transaction.price }
    } catch { if (-not $receipt.tradeId) { throw } }
  }
  return $receipt
}

function Submit-V2PracticeTrade($Position,[string]$ClientId,$Plan=$null) {
  $plan=if ($null -ne $Plan) { $Plan } else { Get-V2PracticeOrderPlan $Position $ClientId }
  $response=Invoke-V2PracticeApi 'POST' '/orders' @{ order=$plan.order }
  $fill=$response.orderFillTransaction
  if (-not $fill -or -not $fill.tradeOpened.tradeID) {
    $reason=if ($response.orderCancelTransaction.reason) { [string]$response.orderCancelTransaction.reason } else { 'no trade was opened' }
    throw "Practice market order did not fill: $reason"
  }
  return @{ status='OPEN'; clientId=$ClientId; orderId=[string]$response.orderCreateTransaction.id;
    tradeId=[string]$fill.tradeOpened.tradeID; fillPrice=[double]$fill.price; fillTime=[string]$fill.time;
    units=[double]$plan.units; dollarsPerPip=[Math]::Round([double]$plan.dollarsPerPip,4); quoteTime=$plan.quoteTime }
}

function Close-V2PracticeTrade($Practice) {
  if (-not $Practice -or -not $Practice.tradeId) { return @{ status='NOT_LINKED' } }
  $tradeId=[uri]::EscapeDataString([string]$Practice.tradeId)
  $current=Invoke-V2PracticeApi 'GET' ("/trades/$tradeId")
  if ($current.trade.state -ne 'OPEN') { return @{ status='CLOSED'; tradeId=[string]$Practice.tradeId; closeReason='already closed at OANDA' } }
  $result=Invoke-V2PracticeApi 'PUT' ("/trades/$tradeId/close") @{ units='ALL' }
  if (-not $result.orderFillTransaction) { throw 'OANDA did not confirm the practice trade close.' }
  return @{ status='CLOSED'; tradeId=[string]$Practice.tradeId; closeReason='paper trade exited'; closeTime=[string]$result.orderFillTransaction.time;
    closePrice=[double]$result.orderFillTransaction.price }
}
