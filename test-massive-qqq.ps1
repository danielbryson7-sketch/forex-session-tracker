param(
  [ValidatePattern('^[A-Z][A-Z0-9.]{0,9}$')][string]$Ticker = 'QQQ',
  [ValidateRange(1,30)][int]$LookbackDays = 7
)

$ErrorActionPreference = 'Stop'
$keyFile = Join-Path $PSScriptRoot '.massive-api-key.local'
$apiKey = if ($env:MASSIVE_API_KEY) { $env:MASSIVE_API_KEY.Trim() }
  elseif (Test-Path $keyFile) { (Get-Content -Raw $keyFile).Trim() }
  else { '' }
if (-not $apiKey) { throw 'Set MASSIVE_API_KEY or put the key in .massive-api-key.local beside this script.' }

$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(20)
$client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $apiKey)

function Get-MassiveJson([string]$Path) {
  $url = 'https://api.massive.com' + $Path
  $response = $client.GetAsync($url).GetAwaiter().GetResult()
  try {
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $json = if ($body) { $body | ConvertFrom-Json -AsHashtable -DateKind String } else { @{} }
    if (-not $response.IsSuccessStatusCode) {
      $message = if ($json.error) { [string]$json.error }
        elseif ($json.message) { [string]$json.message }
        else { 'Request was rejected.' }
      throw "HTTP $([int]$response.StatusCode): $message"
    }
    return $json
  } finally { $response.Dispose() }
}

function Show-Bars([string]$Label, $Payload) {
  $bars = @($Payload.results)
  Write-Host "$Label`: status=$($Payload.status), bars=$($bars.Count)"
  if ($bars.Count -gt 0) {
    $latest = $bars[-1]
    $when = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$latest.t).ToString('yyyy-MM-dd HH:mm:ss zzz')
    Write-Host "  Latest: $when UTC | O=$($latest.o) H=$($latest.h) L=$($latest.l) C=$($latest.c) volume=$($latest.v)"
  }
}

try {
  $details = Get-MassiveJson ('/v3/reference/tickers/' + [uri]::EscapeDataString($Ticker))
  Write-Host "Ticker: $($details.results.ticker) | $($details.results.name) | active=$($details.results.active)"

  $to = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-dd')
  $from = [DateTimeOffset]::UtcNow.AddDays(-$LookbackDays).ToString('yyyy-MM-dd')
  $base = '/v2/aggs/ticker/' + [uri]::EscapeDataString($Ticker) + '/range/'
  try {
    $daily = Get-MassiveJson ($base + ('1/day/{0}/{1}?adjusted=true&sort=asc&limit=100' -f $from,$to))
    Show-Bars 'Daily OHLC' $daily
  } catch { Write-Host "Daily OHLC: $($_.Exception.Message)" }
  try {
    $intradayFrom = [DateTimeOffset]::UtcNow.AddDays(-2).ToString('yyyy-MM-dd')
    $intraday = Get-MassiveJson ($base + ('15/minute/{0}/{1}?adjusted=true&sort=asc&limit=5000' -f $intradayFrom,$to))
    Show-Bars '15-minute OHLC' $intraday
  } catch { Write-Host "15-minute OHLC: $($_.Exception.Message)" }
} finally {
  $client.Dispose()
  $apiKey = $null
}
