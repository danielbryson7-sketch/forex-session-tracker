param([switch]$Once,[switch]$Preview,[switch]$TestSend,[string]$OutputPath)

$ErrorActionPreference = 'Stop'
$nyZone = [TimeZoneInfo]::FindSystemTimeZoneById('America/New_York')
$ledgerPath = Join-Path $PSScriptRoot 'data/paper-ledger-v2.json'
$statePath = Join-Path $PSScriptRoot 'data/hourly-mail-state-v2.json'
$script:mailFrom = [string]$env:GMAIL_FROM
$script:mailTo = [string]$env:GMAIL_TO
$script:mailAppPassword = [string]$env:GMAIL_APP_PASSWORD
$credentialsPath = Join-Path $PSScriptRoot 'mail-credentials.local.ps1'
if (Test-Path $credentialsPath) { . $credentialsPath }

function Encode-Html($Value) {
  if ($null -eq $Value) { return '' }
  return [Net.WebUtility]::HtmlEncode([string]$Value)
}

function Format-Ny($Value) {
  if (-not $Value) { return '—' }
  $time = [DateTimeOffset]::Parse([string]$Value)
  return [TimeZoneInfo]::ConvertTime($time,$nyZone).ToString('MM/dd/yyyy HH:mm')
}

function Format-Price($Pair,$Value) {
  if ($null -eq $Value -or [string]$Value -eq '') { return '—' }
  $digits = if ([string]$Pair -like '*/JPY') { 3 } else { 5 }
  return ([double]$Value).ToString("F$digits",[Globalization.CultureInfo]::InvariantCulture)
}

function Format-Pips($Value) {
  if ($null -eq $Value -or [string]$Value -eq '') { return '—' }
  $number = [double]$Value
  return ('{0}{1:F1}' -f $(if ($number -ge 0) { '+' } else { '' }),$number)
}

function Read-CurrentSummary {
  if (-not (Test-Path $ledgerPath)) { throw 'The paper-trade ledger is missing.' }
  try { $null = Get-Content -Raw $ledgerPath | ConvertFrom-Json -AsHashtable -DateKind String }
  catch { throw "The paper-trade ledger is unreadable: $($_.Exception.Message)" }
  $response = Invoke-WebRequest -Uri 'http://127.0.0.1:8771/api/paper/all' -TimeoutSec 35 -UseBasicParsing
  if ($response.StatusCode -ne 200) { throw "Local trade summary returned HTTP $($response.StatusCode)." }
  return ($response.Content | ConvertFrom-Json -AsHashtable -DateKind String)
}

function Pip-Color($Value) {
  if ([double]$Value -gt 0) { return '#55d6b3' }
  if ([double]$Value -lt 0) { return '#ff8d87' }
  return '#edf5ff'
}

function Trade-Badge($Trade) {
  $direction = ([string]$Trade.direction).ToUpperInvariant()
  $background = if ($direction -eq 'SHORT') { '#572c37' } else { '#254274' }
  $foreground = if ($direction -eq 'SHORT') { '#ffd6db' } else { '#cfe3ff' }
  return '<span style="display:inline-block;background:' + $background + ';color:' + $foreground + ';border-radius:6px;padding:5px 8px;font-size:11px;font-weight:700;letter-spacing:1px">' + (Encode-Html $direction) + '</span>'
}

function Open-TradeCard($Trade) {
  $pair = [string]$Trade.pair
  $markPips = [double]$Trade.markPips
  $net = Format-Pips $markPips
  $distance = '—'
  if ($null -ne $Trade.mark -and $null -ne $Trade.tp1) {
    $pip = if ($pair -like '*/JPY') { 0.01 } else { 0.0001 }
    $remaining = if ($Trade.direction -eq 'short') { ([double]$Trade.mark-[double]$Trade.tp1)/$pip }
      else { ([double]$Trade.tp1-[double]$Trade.mark)/$pip }
    $distance = if ($remaining -le 0) { 'TP reached' } else { $remaining.ToString('F1',[Globalization.CultureInfo]::InvariantCulture) }
  }
  $origin = if ($Trade.origin -eq 'backfill') { ' · Backfilled' } else { '' }
  $details = 'Opened ' + (Format-Ny $Trade.entryTime) + ' NY · Entry ' + (Format-Price $pair $Trade.entry) +
    ' · Current ' + (Format-Price $pair $Trade.mark) + ' · TP1 ' + (Format-Price $pair $Trade.tp1) +
    ' · Stop ' + (Format-Price $pair $Trade.stop) + $origin
  return @"
<div style="background:#102035;border:1px solid #294056;border-radius:14px;padding:16px;margin:0 0 11px">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>
    <td style="color:#edf5ff;font-size:21px;font-weight:700;letter-spacing:-.3px">$(Encode-Html $pair)</td>
    <td align="right">$(Trade-Badge $Trade)</td>
  </tr></table>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-top:14px"><tr>
    <td width="48%" style="background:#0b192a;border-radius:9px;padding:10px;color:#a9bed1;font-size:12px">Open net pips<br><strong style="display:block;margin-top:5px;color:$(Pip-Color $markPips);font-size:22px">$(Encode-Html $net)</strong></td>
    <td width="8" style="font-size:1px">&nbsp;</td>
    <td width="48%" style="background:#0b192a;border-radius:9px;padding:10px;color:#a9bed1;font-size:12px">Pips to TP<br><strong style="display:block;margin-top:5px;color:#edf5ff;font-size:22px">$(Encode-Html $distance)</strong></td>
  </tr></table>
  <div style="color:#9eb5cc;font-size:11px;line-height:1.5;margin-top:12px">$(Encode-Html $details)</div>
</div>
"@
}

function Closed-TradeCard($Trade) {
  $pair = [string]$Trade.pair
  $net = [double]$Trade.netPips
  $result = if ($Trade.exitReason -eq 'tp1') { 'TP1' } elseif ($Trade.exitReason -eq 'stop') { 'Stop' }
    elseif ($Trade.exitReason -eq 'friday') { 'Friday close' }
    elseif ($Trade.exitReason -eq 'bias_lost') { 'H4 bias lost' } else { [string]$Trade.exitReason }
  $origin = if ($Trade.origin -eq 'backfill') { ' · Backfilled' } else { '' }
  $summary = $result + ' · ' + (Format-Ny $Trade.exitTime) + ' NY' + $origin
  $details = 'Opened ' + (Format-Ny $Trade.entryTime) + ' NY · Entry ' + (Format-Price $pair $Trade.entry) +
    ' · Exit ' + (Format-Price $pair $Trade.exit) + ' · TP1 ' + (Format-Price $pair $Trade.tp1) +
    ' · Stop ' + (Format-Price $pair $Trade.stop)
  return @"
<div style="background:#102035;border:1px solid #294056;border-radius:11px;padding:13px 14px;margin:0 0 8px">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>
    <td style="color:#edf5ff;font-size:16px;font-weight:700">$(Encode-Html $pair) &nbsp;$(Trade-Badge $Trade)</td>
    <td align="right" style="color:$(Pip-Color $net);font-size:17px;font-weight:700;white-space:nowrap">$(Encode-Html (Format-Pips $net)) pips</td>
  </tr></table>
  <div style="color:#9eb5cc;font-size:11px;line-height:1.5;margin-top:7px">$(Encode-Html $summary)<br>$(Encode-Html $details)</div>
</div>
"@
}

function Build-Report($Data,[DateTimeOffset]$RunTime) {
  $open = @($Data.open)
  $closed = @($Data.recent)
  $openNet = 0.0
  foreach ($trade in $open) { $openNet += [double]$trade.markPips }
  $closedNet = [double]$Data.netPips
  $totalNet = $closedNet + $openNet
  $checked = Format-Ny $Data.updatedAt
  $openCards = if ($open.Count) { (@($open | Sort-Object pair | ForEach-Object { Open-TradeCard $_ }) -join "`n") }
    else { '<div style="background:#102035;border:1px solid #294056;border-radius:14px;padding:22px;color:#a9bed1;text-align:center">No open paper trades right now.</div>' }
  $closedCards = if ($closed.Count) { (@($closed | ForEach-Object { Closed-TradeCard $_ }) -join "`n") }
    else { '<div style="background:#102035;border:1px solid #294056;border-radius:14px;padding:22px;color:#a9bed1;text-align:center">No closed paper trades yet.</div>' }
  $asOf = [TimeZoneInfo]::ConvertTime($RunTime,$nyZone).ToString('MM/dd/yyyy HH:mm')
  return @"
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Paper trades</title></head>
<body style="margin:0;padding:0;background:#08111d;color:#edf5ff;font-family:Arial,Helvetica,sans-serif">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#08111d"><tr><td align="center" style="padding:18px 10px 30px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:660px"><tr><td>
  <div style="font-size:24px;font-weight:700;letter-spacing:-.5px;color:#edf5ff">Paper trades</div>
  <div style="font-size:12px;color:#9eb5cc;margin-top:5px">Live marks · paper results<br>Sent $asOf NY · Last scan $(Encode-Html $checked) NY</div>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-top:17px;margin-bottom:17px"><tr>
    <td width="48%" style="background:#102035;border:1px solid #294056;border-radius:12px;padding:13px;color:#a9bed1;font-size:12px">Open trades<br><strong style="display:block;margin-top:5px;color:#edf5ff;font-size:23px">$( $open.Count )</strong></td>
    <td width="9" style="font-size:1px">&nbsp;</td>
    <td width="48%" style="background:#102035;border:1px solid #294056;border-radius:12px;padding:13px;color:#a9bed1;font-size:12px">Open net pips<br><strong style="display:block;margin-top:5px;color:$(Pip-Color $openNet);font-size:23px">$(Format-Pips $openNet)</strong></td>
  </tr></table>
  <div style="color:#edf5ff;font-size:17px;font-weight:700;margin:0 2px 11px">Open trades</div>
  $openCards
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-top:23px;margin-bottom:11px"><tr>
    <td style="color:#edf5ff;font-size:17px;font-weight:700">Closed trades</td>
    <td align="right" style="color:#9eb5cc;font-size:12px">$( $closed.Count ) trades · $(Format-Pips $closedNet) pips</td>
  </tr></table>
  $closedCards
  <div style="color:#9eb5cc;font-size:12px;margin:17px 2px 0">Combined net: <strong style="color:$(Pip-Color $totalNet)">$(Format-Pips $totalNet) pips</strong></div>
  <div style="color:#829bb2;font-size:11px;line-height:1.5;margin:12px 2px 0">Distance to TP uses the latest available bid or ask. Paper results use completed M15 midpoint candles and can differ from any linked OANDA practice order fills.</div>
</td></tr></table></td></tr></table></body></html>
"@
}

function Send-Mail([string]$Subject,[string]$Html) {
  if (-not $script:mailAppPassword -or $script:mailAppPassword -eq 'REPLACE_WITH_GMAIL_APP_PASSWORD') {
    throw 'Gmail app password is not configured.'
  }
  $message = [Net.Mail.MailMessage]::new()
  $smtp = [Net.Mail.SmtpClient]::new('smtp.gmail.com',587)
  try {
    $message.From = [Net.Mail.MailAddress]::new($script:mailFrom)
    $message.To.Add($script:mailTo)
    $message.Subject = $Subject
    $message.SubjectEncoding = [Text.Encoding]::UTF8
    $message.Body = $Html
    $message.BodyEncoding = [Text.Encoding]::UTF8
    $message.IsBodyHtml = $true
    $smtp.EnableSsl = $true
    $smtp.UseDefaultCredentials = $false
    $smtp.Credentials = [Net.NetworkCredential]::new($script:mailFrom,$script:mailAppPassword)
    $smtp.Timeout = 45000
    $smtp.Send($message)
  } finally { $message.Dispose();$smtp.Dispose() }
}

function Send-HourlyReport([DateTimeOffset]$RunTime) {
  $hour = [TimeZoneInfo]::ConvertTime($RunTime,$nyZone).ToString('yyyy-MM-dd HH')
  if (-not $TestSend -and -not $Preview -and (Test-Path $statePath)) {
    try { $state = Get-Content -Raw $statePath | ConvertFrom-Json -AsHashtable }
    catch { throw "Hourly mail state is unreadable: $($_.Exception.Message)" }
    if ($state.lastSentHour -eq $hour) { Write-Host "Hourly report already sent for $hour New York.";return }
  }
  $subject = if ($TestSend) { 'Paper trade report — mobile layout test' }
    else { 'Paper trade report — ' + [TimeZoneInfo]::ConvertTime($RunTime,$nyZone).ToString('MM/dd/yyyy HH:00') + ' NY' }
  try { $data = Read-CurrentSummary; $html = Build-Report $data $RunTime }
  catch { $html = '<html><body><h1>Paper-trade report unavailable</h1><p>' + (Encode-Html $_.Exception.Message) + '</p><p>No stale trade figures were sent.</p></body></html>' }
  if ($Preview) {
    if (-not $OutputPath) { $OutputPath = Join-Path $PSScriptRoot 'data/hourly-mail-preview.html' }
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),$html,[Text.Encoding]::UTF8)
    Write-Host "Preview written to $OutputPath"
    return
  }
  Send-Mail $subject $html
  if ($TestSend) { Write-Host "Sent layout test to $script:mailTo.";return }
  $state = @{ lastSentHour = $hour; sentAt = [DateTimeOffset]::UtcNow.ToString('o') }
  $temporary = "$statePath.tmp"
  [IO.File]::WriteAllText($temporary,($state | ConvertTo-Json -Compress),[Text.Encoding]::UTF8)
  Move-Item $temporary $statePath -Force
  Write-Host "Sent paper-trade report for $hour New York to $script:mailTo."
}

if ($Preview -or $Once -or $TestSend) { Send-HourlyReport ([DateTimeOffset]::UtcNow);return }
if (-not $script:mailFrom -or -not $script:mailTo) {
  throw 'Set GMAIL_FROM and GMAIL_TO before starting hourly email.'
}
if (-not $script:mailAppPassword -or $script:mailAppPassword -eq 'REPLACE_WITH_GMAIL_APP_PASSWORD') {
  throw 'Set a Gmail app password in mail-credentials.local.ps1 before starting hourly email.'
}
Write-Host "Hourly paper email scheduled at the top of each hour, New York time, to $script:mailTo."
while ($true) {
  $utcNow = [DateTimeOffset]::UtcNow
  $nextUtc = [DateTimeOffset]::new($utcNow.UtcDateTime.Date.AddHours($utcNow.Hour + 1),[TimeSpan]::Zero)
  while ([DateTimeOffset]::UtcNow -lt $nextUtc) {
    $remaining = ($nextUtc-[DateTimeOffset]::UtcNow).TotalSeconds
    Start-Sleep -Seconds ([Math]::Max(1,[Math]::Min(30,[int][Math]::Ceiling($remaining))))
  }
  try { Send-HourlyReport $nextUtc }
  catch { Write-Warning "Hourly paper email failed: $($_.Exception.Message)" }
}
