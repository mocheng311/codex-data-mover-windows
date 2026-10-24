#requires -Version 5.1
[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'Migration.Transaction.ps1')
Assert-Windows
$root = Join-Path ([IO.Path]::GetTempPath()) ('transaction-fixture-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
function New-Fixture([string]$Name) {
    $source = Join-Path $root ($Name + '-source')
    $null = New-Item -ItemType Directory -Path $source
    [IO.File]::WriteAllText((Join-Path $source 'example.txt'), 'original fixture')
    return [pscustomobject]@{Source=$source;Destination=(Join-Path $root ($Name + '-destination'));State=(Join-Path $root ($Name + '-state.json'))}
}
try {
    Write-Host 'Testing completed migration, repeat invocation and latest-data rollback...'
    $fixture = New-Fixture 'complete'
    $journal = Invoke-Migration $fixture.Source $fixture.Destination $fixture.State
    Assert-Junction $fixture.Source $fixture.Destination
    $again = Invoke-Migration $fixture.Source $fixture.Destination $fixture.State
    if ($again.Id -cne $journal.Id) { throw 'Repeated migration created a second transaction.' }
    [IO.File]::WriteAllText((Join-Path $fixture.Source 'example.txt'), 'new data after migration')
    $rolledBack = Invoke-Rollback $fixture.Source $fixture.Destination $fixture.State
    if ($rolledBack.Phase -ne 'RolledBack' -or [IO.File]::ReadAllText((Join-Path $fixture.Source 'example.txt')) -cne 'new data after migration') { throw 'Latest writes were lost during rollback.' }
    if ([IO.File]::ReadAllText((Join-Path $journal.Backup 'example.txt')) -cne 'original fixture') { throw 'The original backup was overwritten.' }
    $null = Assert-TreesEqual $fixture.Source $fixture.Destination
    $null = Invoke-Rollback $fixture.Source $fixture.Destination $fixture.State

    Write-Host 'Testing an interruption after rename and before junction creation...'
    $interrupted = New-Fixture 'interrupted'
    $id = [guid]::NewGuid().ToString('N')
    $partial = [pscustomobject]@{Version=1;Id=$id;Source=$interrupted.Source;Destination=$interrupted.Destination;Backup=($interrupted.Source+'.migration-backup-'+$id);RestorePath='';Phase='Switching';UpdatedUtc='';Files=1;Bytes=0;ErrorCode=$null;CopyExitCode=1}
    $null = Copy-VerifiedTree $interrupted.Source $interrupted.Destination
    Save-Journal $partial $interrupted.State
    [IO.Directory]::Move($interrupted.Source, $partial.Backup)
    $restored = Invoke-Rollback $interrupted.Source $interrupted.Destination $interrupted.State
    if ($restored.Phase -ne 'RolledBack' -or -not [IO.Directory]::Exists($interrupted.Source)) { throw 'The interrupted rename was not recovered.' }

    Write-Host 'Testing tampered journal rejection...'
    $invalid = Read-Journal $interrupted.State $interrupted.Source $interrupted.Destination
    $invalid.Backup = Join-Path $root 'unexpected'
    [IO.File]::WriteAllText($interrupted.State, ($invalid | ConvertTo-Json))
    $rejected=$false
    try { $null = Read-Journal $interrupted.State $interrupted.Source $interrupted.Destination } catch { $rejected=$true }
    if (-not $rejected) { throw 'A tampered backup path was accepted.' }
    [pscustomobject]@{Passed=$true;Checks=@('junction switch','idempotent migration','latest writes restored','original backup preserved','destination retained','repeat rollback','interrupted rename recovery','tampered journal rejected')} | ConvertTo-Json
} finally { Write-Host ('Synthetic fixture retained at: ' + $root) }
