param(
  [Parameter(Mandatory = $true)][string]$BindIp,
  [ValidateRange(1,32)][int]$PrefixLength = 24,
  [ValidateRange(1024,65535)][int]$Port = 8768
)

$ErrorActionPreference = 'Stop'
$bindAddress = [Net.IPAddress]::Parse($BindIp)
if ($bindAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
  throw 'The home-network summary requires an IPv4 address.'
}
$bindBytes = $bindAddress.GetAddressBytes()
$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("http://${BindIp}:${Port}/")
$client = [Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(20)

function Test-HomeNetworkAddress([Net.IPAddress]$Address) {
  if ($Address.IsIPv4MappedToIPv6) { $Address = $Address.MapToIPv4() }
  if ($Address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
  $bytes = $Address.GetAddressBytes()
  $wholeBytes = [Math]::Floor($PrefixLength / 8)
  for ($i = 0; $i -lt $wholeBytes; $i++) {
    if ($bytes[$i] -ne $bindBytes[$i]) { return $false }
  }
  $remainingBits = $PrefixLength % 8
  if ($remainingBits) {
    $mask = (0xff -shl (8 - $remainingBits)) -band 0xff
    if (($bytes[$wholeBytes] -band $mask) -ne ($bindBytes[$wholeBytes] -band $mask)) { return $false }
  }
  return $true
}

function Write-Response($Context, [int]$Status, [string]$ContentType, [string]$Body) {
  $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
  $Context.Response.StatusCode = $Status
  $Context.Response.ContentType = "$ContentType; charset=utf-8"
  $Context.Response.Headers['Cache-Control'] = 'no-store'
  $Context.Response.Headers['X-Content-Type-Options'] = 'nosniff'
  $Context.Response.Headers['Referrer-Policy'] = 'no-referrer'
  $Context.Response.ContentLength64 = $bytes.Length
  $Context.Response.OutputStream.Write($bytes,0,$bytes.Length)
}

function Get-MobileSummary {
  $response = $client.GetAsync('http://127.0.0.1:8771/api/paper/all').GetAwaiter().GetResult()
  try {
    if (-not $response.IsSuccessStatusCode) { throw "Local trade summary returned HTTP $([int]$response.StatusCode)." }
    $source = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable -DateKind String
  } finally { $response.Dispose() }
  $open = @($source.open | ForEach-Object {
    @{ pair = $_.pair; direction = $_.direction; entryTime = $_.entryTime; entry = $_.entry;
      mark = $_.mark; asOf = $_.asOf; markSource = $_.markSource; tp1 = $_.tp1;
      stop = $_.stop; markPips = $_.markPips }
  })
  $closed = @($source.recent | ForEach-Object {
    @{ pair = $_.pair; direction = $_.direction; entryTime = $_.entryTime; exitTime = $_.exitTime;
      entry = $_.entry; exit = $_.exit; exitReason = $_.exitReason;
      netPips = $_.netPips; maxFavorablePips = $_.maxFavorablePips; origin = $_.origin }
  })
  $pairTotals = @{}
  foreach ($pair in $source.pairTotals.Keys) {
    $total = $source.pairTotals[$pair]
    if ($total.hasOpen -or $total.closedPips -or $total.hasOte) {
      $pairTotals[$pair] = @{ closedPips = $total.closedPips; livePips = $total.livePips;
        totalPips = $total.totalPips; hasOpen = $total.hasOpen;
        hasOte = $total.hasOte; inOte = $total.inOte; hasPending = $total.hasPending;
        oteDistancePips = $total.oteDistancePips; otePosition = $total.otePosition }
    }
  }
  return @{ updatedAt = $source.updatedAt; errors = $source.errors; quoteError = $source.quoteError;
    open = $open; recent = $closed; closedCount = $source.closedCount;
    netPips = $source.netPips; pairTotals = $pairTotals }
}

function Close-MobilePaperTrade($Context) {
  $origin = [string]$Context.Request.Headers['Origin']
  if ($origin -ne "http://${BindIp}:${Port}") {
    Write-Response $Context 403 'application/json' '{"error":"Open this page on the home network to close a paper trade."}'
    return
  }
  if ([string]$Context.Request.ContentType -notmatch '^application/json(?:\s*;|$)' -or $Context.Request.ContentLength64 -gt 1024) {
    Write-Response $Context 415 'application/json' '{"error":"Invalid close request."}'
    return
  }
  $reader = [IO.StreamReader]::new($Context.Request.InputStream)
  try { $body = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable }
  finally { $reader.Dispose() }
  $pair = [string]$body.pair
  $entryTime = [string]$body.entryTime
  if (-not $pair -or -not $entryTime) {
    Write-Response $Context 400 'application/json' '{"error":"The trade identifier is missing."}'
    return
  }
  $payload = @{ pair = $pair; entryTime = $entryTime } | ConvertTo-Json -Compress
  $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,'http://127.0.0.1:8771/api/paper/close')
  $request.Headers.TryAddWithoutValidation('Origin','http://127.0.0.1:8771') | Out-Null
  $request.Content = [Net.Http.StringContent]::new($payload,[Text.Encoding]::UTF8,'application/json')
  try {
    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    try {
      $result = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      Write-Response $Context ([int]$response.StatusCode) 'application/json' $result
    } finally { $response.Dispose() }
  } finally { $request.Dispose() }
}

$listener.Start()
Write-Host "Home-network V2 trade summary: http://${BindIp}:${Port}/"
try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    try {
      $remoteAddress = $context.Request.RemoteEndPoint.Address
      if (-not (Test-HomeNetworkAddress $remoteAddress)) {
        Write-Response $context 403 'text/plain' 'This summary is available only on the home network.'
      } elseif ($context.Request.Url.AbsolutePath -eq '/api/paper/close' -and $context.Request.HttpMethod -eq 'POST') {
        Close-MobilePaperTrade $context
      } elseif ($context.Request.HttpMethod -ne 'GET') {
        Write-Response $context 405 'text/plain' 'Method not allowed.'
      } else {
        $path = $context.Request.Url.AbsolutePath
        if ($path -in @('/','/summary','/summary.html')) {
          $html = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'mobile-summary-v2.html'))
          Write-Response $context 200 'text/html' $html
        } elseif ($path -eq '/full') {
          $html = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'summary-v2.html'))
          $html = $html.Replace('<a class="nav" href="/">← Back to chart</a>','<span class="nav">Home-network view</span>')
          Write-Response $context 200 'text/html' $html
        } elseif ($path -eq '/api/paper/all') {
          $data = Get-MobileSummary
          Write-Response $context 200 'application/json' ($data | ConvertTo-Json -Depth 8 -Compress)
        } elseif ($path -eq '/api/chart') {
          $pair = [uri]::UnescapeDataString([string]$context.Request.QueryString['pair'])
          if ($pair -notmatch '^[A-Z]{3}/[A-Z]{3}$') {
            Write-Response $context 400 'application/json' '{"error":"Invalid pair."}'
          } else {
            $url = 'http://127.0.0.1:8771/api/mobile-chart?pair=' + [uri]::EscapeDataString($pair)
            $response = $client.GetAsync($url).GetAwaiter().GetResult()
            try {
              $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
              Write-Response $context ([int]$response.StatusCode) 'application/json' $body
            } finally { $response.Dispose() }
          }
        } else {
          Write-Response $context 404 'text/plain' 'Not found.'
        }
      }
    } catch {
      Write-Warning $_.Exception.Message
      try { Write-Response $context 502 'application/json' '{"error":"Trade summary temporarily unavailable."}' } catch { }
    } finally { try { $context.Response.OutputStream.Close() } catch { } }
  }
} finally {
  $listener.Stop()
  $listener.Close()
  $client.Dispose()
}
