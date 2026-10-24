#requires -Version 5.1
[CmdletBinding()]
param()
Write-Host 'Loading migration helpers...'
. (Join-Path $PSScriptRoot 'Migration.Core.ps1')
Assert-Windows
Write-Host 'Creating a synthetic fixture...'
$root = Join-Path ([IO.Path]::GetTempPath()) ('migration-fixture-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$source = Join-Path $root 'source'; $destination = Join-Path $root 'destination'
$null = New-Item -ItemType Directory -Path $source
$null = New-Item -ItemType Directory -Path (Join-Path $source 'empty')
$file = Join-Path $source 'example.txt'
[IO.File]::WriteAllText($file, 'synthetic fixture only')
Set-Content -LiteralPath $file -Stream 'FixtureStream' -Value 'synthetic stream'
function Assert-Rejected([scriptblock]$Action) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'An unsafe operation was accepted.' }
}
try {
    Write-Host 'Checking ACL and process regressions...'
    $who = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $split = [Security.AccessControl.DirectorySecurity]::new()
    $split.SetSecurityDescriptorSddlForm("D:(A;;0x1;;;$who)(A;;0x2;;;$who)")
    $merged = [Security.AccessControl.DirectorySecurity]::new()
    $merged.SetSecurityDescriptorSddlForm("D:(A;;0x3;;;$who)")
    if ((Get-AccessSignature $split) -cne (Get-AccessSignature $merged)) { throw 'Equivalent ACL regression remains.' }
    $denied = [Security.AccessControl.DirectorySecurity]::new()
    $denied.SetSecurityDescriptorSddlForm("D:(D;;0x1;;;$who)(A;;0x3;;;$who)")
    if ((Get-AccessSignature $denied) -ceq (Get-AccessSignature $merged)) { throw 'A deny rule was ignored.' }
    $owned = [pscustomobject]@{ Id = 12345; HasExited = $false }
    $process = [pscustomobject]@{ ProcessId = 12345; ParentProcessId = $PID; Name = 'robocopy.exe'; ExecutablePath = (Join-Path $env:SystemRoot 'System32\robocopy.exe'); CommandLine = $source }
    if (Test-ProcessBlocks $process $owned @($source)) { throw 'The owned copy is still blocked.' }
    $process.ParentProcessId = $PID + 1
    if (-not (Test-ProcessBlocks $process $owned @($source))) { throw 'An unrelated copy was exempted.' }
    Assert-Rejected { Assert-CopyPair $source $source }
    Write-Host 'Checking path guards and file locks...'
    Assert-Rejected { Assert-CopyPair $source (Join-Path $source 'nested') }
    $handle = [IO.File]::Open($file, 'Open', 'ReadWrite', 'None')
    try { Assert-Rejected { Get-Tree $source -CheckReadable } } finally { $handle.Dispose() }
    $link = Join-Path $source 'external-link'
    $null = New-Item -ItemType Junction -Path $link -Target (Join-Path $source 'empty')
    try { Assert-Rejected { Get-Tree $source } } finally { [IO.Directory]::Delete($link, $false) }
    Write-Host 'Copying and verifying the synthetic tree...'
    $VerbosePreference = 'Continue'
    $summary = Copy-VerifiedTree $source $destination
    Assert-Rejected { Copy-VerifiedTree $source $destination }
    [IO.File]::WriteAllText((Join-Path $destination 'example.txt'), 'tampered copy')
    Assert-Rejected { Assert-TreesEqual $source $destination }
    if ([IO.File]::ReadAllText($file) -cne 'synthetic fixture only') { throw 'The original was changed.' }
    [pscustomobject]@{ Passed = $true; Checks = @('equivalent ACL', 'deny preservation', 'owned copy identity', 'unrelated copy blocked', 'overlap rejected', 'locked file rejected', 'nested link rejected', 'copy and streams verified', 'existing destination rejected', 'tampering detected', 'original unchanged'); Files = $summary.Files } | ConvertTo-Json
} finally {
    # Deliberately retain only the small synthetic fixture for inspection.
    Write-Host ('Synthetic fixture retained at: ' + $root)
}
