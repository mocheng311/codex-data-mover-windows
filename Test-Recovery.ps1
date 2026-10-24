#requires -Version 5.1
[CmdletBinding()]
param([string]$DestinationFixtureRoot)
. (Join-Path $PSScriptRoot 'Migration.Transaction.ps1')
Assert-Windows
$root = Join-Path ([IO.Path]::GetTempPath()) ('recovery-fixture-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$remoteRoot = $root
if ($DestinationFixtureRoot) {
    $parent = Get-NormalPath $DestinationFixtureRoot
    Assert-PlainChain $parent
    $remoteRoot = Join-Path $parent ('recovery-target-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $remoteRoot
}
function New-RecoveryFixture([string]$Name) {
    $source = Join-Path $root ($Name+'-source'); $destination = Join-Path $remoteRoot ($Name+'-destination')
    $null = New-Item -ItemType Directory -Path $source
    [IO.File]::WriteAllText((Join-Path $source 'example.txt'), 'before migration')
    return [pscustomobject]@{Source=$source;Destination=$destination;State=(Join-Path $root ($Name+'-state.json'))}
}
function Require-Rejection([scriptblock]$Action) {
    $rejected=$false; try { & $Action | Out-Null } catch { $rejected=$true }
    if (-not $rejected) { throw 'Expected a rejected operation.' }
}
try {
    Write-Host 'Testing a locked file before copying and recovery from a failed transaction...'
    $locked = New-RecoveryFixture 'locked'
    $handle = [IO.File]::Open((Join-Path $locked.Source 'example.txt'), 'Open', 'ReadWrite', 'None')
    try { Require-Rejection { Invoke-Migration $locked.Source $locked.Destination $locked.State } } finally { $handle.Dispose() }
    $failed = Read-Journal $locked.State $locked.Source $locked.Destination
    if ($failed.Phase -ne 'Failed' -or (Test-Path -LiteralPath $locked.Destination)) { throw 'A locked-file failure had unexpected side effects.' }
    $aborted = Invoke-Rollback $locked.Source $locked.Destination $locked.State
    if ($aborted.Phase -ne 'Aborted') { throw 'Failed transaction recovery did not finish.' }

    Write-Host 'Testing journal lock contention and ambiguous path rejection...'
    $contended = New-RecoveryFixture 'contended'
    $lock = [IO.File]::Open(($contended.State+'.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try { Require-Rejection { Invoke-Migration $contended.Source $contended.Destination $contended.State } } finally { $lock.Dispose() }
    if (Test-Path -LiteralPath $contended.Destination) { throw 'A second worker changed the destination.' }
    Require-Rejection { Get-NormalPath 'C:\example\NUL' }
    Require-Rejection { Get-NormalPath 'C:\example\trailing.' }
    Require-Rejection { Assert-ControlPath (Join-Path $contended.Source 'state.json') $contended.Source $contended.Destination }

    foreach ($window in @('before-restore-rename','after-restore-rename')) {
        Write-Host ('Testing recovery window: '+$window)
        $fixture = New-RecoveryFixture $window
        $journal = Invoke-Migration $fixture.Source $fixture.Destination $fixture.State
        [IO.File]::WriteAllText((Join-Path $fixture.Destination 'example.txt'), 'latest destination data')
        $staging = $fixture.Source + '.migration-restore-' + [guid]::NewGuid().ToString('N')
        $null = Copy-VerifiedTree $fixture.Destination $staging
        $journal.RestorePath = $staging; $journal.Phase = 'InstallingRestore'; Save-Journal $journal $fixture.State
        Assert-Junction $fixture.Source $fixture.Destination
        [IO.Directory]::Delete($fixture.Source, $false)
        if ($window -eq 'after-restore-rename') { [IO.Directory]::Move($staging, $fixture.Source) }
        $restored = Invoke-Rollback $fixture.Source $fixture.Destination $fixture.State
        if ($restored.Phase -ne 'RolledBack' -or [IO.File]::ReadAllText((Join-Path $fixture.Source 'example.txt')) -cne 'latest destination data') { throw 'Restore interruption recovery failed.' }
        if ([IO.File]::ReadAllText((Join-Path $journal.Backup 'example.txt')) -cne 'before migration') { throw 'The old backup was changed.' }
    }

    Write-Host 'Testing a mismatched junction without touching its target...'
    $mismatch = New-RecoveryFixture 'mismatch'
    $journal = Invoke-Migration $mismatch.Source $mismatch.Destination $mismatch.State
    [IO.Directory]::Delete($mismatch.Source, $false)
    $other = Join-Path $root 'external-must-survive'
    $null = New-Item -ItemType Directory -Path $other
    [IO.File]::WriteAllText((Join-Path $other 'sentinel.txt'), 'must survive')
    $null = New-Item -ItemType Junction -Path $mismatch.Source -Target $other
    Require-Rejection { Invoke-Rollback $mismatch.Source $mismatch.Destination $mismatch.State }
    if ([IO.File]::ReadAllText((Join-Path $other 'sentinel.txt')) -cne 'must survive') { throw 'An external target was modified.' }
    [pscustomobject]@{Passed=$true;CrossVolume=([IO.Path]::GetPathRoot($root) -ne [IO.Path]::GetPathRoot($remoteRoot));Checks=@('locked file leaves original intact','failed transaction can abort','concurrent journal writer rejected','ambiguous path rejected','state inside source rejected','restore interrupted before rename','restore interrupted after rename','mismatched junction rejected','external target preserved')} | ConvertTo-Json
} finally {
    Write-Host ('Synthetic source fixtures retained: '+$root)
    if ($remoteRoot -ne $root) { Write-Host ('Synthetic destination fixtures retained: '+$remoteRoot) }
}
