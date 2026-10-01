param([string]$OutputPath = (Join-Path $PSScriptRoot 'mail-credentials.local.ps1'))

$ErrorActionPreference = 'Stop'
$secure = Read-Host 'Paste the 16-character Gmail app password (input hidden)' -AsSecureString
$password = (ConvertFrom-SecureString -SecureString $secure -AsPlainText) -replace '\s',''
if ($password -notmatch '^[A-Za-z0-9]{16}$') {
  throw 'Expected a 16-character Gmail app password. No credential file was changed.'
}
$path = [IO.Path]::GetFullPath($OutputPath)
$content = '$script:mailAppPassword = ''' + $password + "'`n"
[IO.File]::WriteAllText($path,$content,[Text.Encoding]::UTF8)
& chmod 600 -- $path
if ($LASTEXITCODE -ne 0) { throw 'Could not set private permissions on the mail credential file.' }
Write-Host "Saved a private mail credential at $path. Restart ./start.sh to enable hourly email."
