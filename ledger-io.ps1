function Enter-PaperLedgerLock([string]$LedgerPath, [int]$TimeoutSeconds = 180) {
  $lockPath = "$LedgerPath.lock"
  $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
  while ([DateTimeOffset]::UtcNow -lt $deadline) {
    try {
      return [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    } catch [IO.IOException] {
      Start-Sleep -Milliseconds 100
    }
  }
  throw 'The paper ledger is busy. Try closing the trade again in a moment.'
}

function Save-PaperLedger([string]$LedgerPath, $Ledger) {
  $temp = "$LedgerPath.$PID.tmp"
  try {
    [IO.File]::WriteAllText($temp,($Ledger | ConvertTo-Json -Depth 15 -Compress),[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temp,$LedgerPath,$true)
  } finally {
    if (Test-Path $temp) { Remove-Item $temp -Force }
  }
}
