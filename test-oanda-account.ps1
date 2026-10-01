param(
  [ValidatePattern('^[0-9]+-[0-9]+-[0-9]+-[0-9]+$')]
  [string]$AccountId = $env:OANDA_ACCOUNT_ID,
  [switch]$TokenFromStdin,
  [ValidateSet('both', 'practice', 'live')]
  [string]$Environment = 'both'
)

$ErrorActionPreference = 'Stop'
if ($TokenFromStdin) {
  if ([Console]::IsInputRedirected) {
    $script:token = [Console]::In.ReadLine()
  } else {
    $secureToken = Read-Host 'OANDA API token' -AsSecureString
    try { $script:token = ConvertFrom-SecureString -SecureString $secureToken -AsPlainText }
    finally { $secureToken.Dispose() }
  }
} else {
  $script:token = [string]$env:OANDA_API_TOKEN
  $credentialsPath = Join-Path $PSScriptRoot 'credentials-v2.local.ps1'
  if (Test-Path $credentialsPath) { . $credentialsPath }
}
if ([string]::IsNullOrWhiteSpace($script:token)) {
  throw 'No OANDA API token was provided.'
}
if ([string]::IsNullOrWhiteSpace($AccountId)) {
  throw 'Pass -AccountId or set OANDA_ACCOUNT_ID.'
}

$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(15)
try {
  $environments = if ($Environment -eq 'both') { @('practice', 'live') } else { @($Environment) }
  foreach ($environment in $environments) {
    $hostName = if ($environment -eq 'live') { 'api-fxtrade.oanda.com' } else { 'api-fxpractice.oanda.com' }
    $listRequest = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, "https://$hostName/v3/accounts")
    $listRequest.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $script:token)
    try {
      $listResponse = $client.SendAsync($listRequest).GetAwaiter().GetResult()
      try {
        $listCode = [int]$listResponse.StatusCode
        if ($listResponse.IsSuccessStatusCode) {
          $listPayload = $listResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
          $accessible = @($listPayload.accounts)
          $listed = @($accessible | Where-Object { [string]$_.id -eq $AccountId }).Count -gt 0
          Write-Output "$environment token check: valid; $($accessible.Count) accessible account(s); target listed: $listed."
        } else {
          Write-Output "$environment token check: HTTP $listCode; account list unavailable."
        }
      } finally { $listResponse.Dispose() }
    } catch [System.Net.Http.HttpRequestException] {
      Write-Output "$environment token check: network request failed."
    } finally { $listRequest.Dispose() }
    $url = "https://$hostName/v3/accounts/$([uri]::EscapeDataString($AccountId))"
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $url)
    $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $script:token)
    try {
      $response = $client.SendAsync($request).GetAwaiter().GetResult()
      try {
        $code = [int]$response.StatusCode
        if ($response.IsSuccessStatusCode) {
          $payload = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
          $returnedId = [string]$payload.account.id
          if ($returnedId -ne $AccountId) { throw 'OANDA returned an unexpected account ID.' }
          Write-Output "SUCCESS: This API key can access account $AccountId in the $environment environment (HTTP $code)."
          exit 0
        }
        Write-Output "$environment environment: HTTP $code; account access was not confirmed."
      } finally { $response.Dispose() }
    } catch [System.Net.Http.HttpRequestException] {
      Write-Output "$environment environment: network request failed; account access was not confirmed."
    } finally { $request.Dispose() }
  }
  Write-Output "RESULT: This API key did not confirm access to account $AccountId in the tested environment(s)."
  exit 1
} finally { $client.Dispose() }
