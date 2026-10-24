#requires -Version 5.1
. (Join-Path $PSScriptRoot 'Migration.Core.ps1')

function Assert-DataScope([string]$Source, [string]$Destination) {
    foreach ($protected in @($env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA, [Environment]::GetFolderPath('MyDocuments'))) {
        if ($protected -and (Test-Inside (Get-NormalPath $protected) $Source)) { throw 'Do not migrate an entire user profile or application-data root.' }
    }
    foreach ($protected in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) {
        if (-not $protected) { continue }
        $path = Get-NormalPath $protected
        if ((Test-Inside $Source $path) -or (Test-Inside $path $Source) -or (Test-Inside $Destination $path)) { throw 'Operating-system and shared program directories are outside the supported scope.' }
    }
}
function Assert-ControlPath([string]$StatePath, [string]$Source, [string]$Destination) {
    $state = Get-NormalPath $StatePath
    Assert-LocalNtfs $state; Assert-NotSynced $state
    Assert-PlainChain ([IO.Path]::GetDirectoryName($state))
    foreach ($root in @($Source, $Destination)) {
        if ((Test-Inside $state $root) -or (Test-Inside $root $state)) { throw 'The state file must be outside both data trees.' }
    }
    if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($state))) { throw 'Create the state-file parent directory first.' }
    foreach ($path in @($state, ($state + '.lock'))) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))) { throw 'The state or lock path is not a plain file.' }
    }
}
function Save-Journal($Journal, [string]$Path) {
    Assert-ControlPath $Path $Journal.Source $Journal.Destination
    $Journal.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    $temporary = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($temporary, ($Journal | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
    else { [IO.File]::Move($temporary, $Path) }
}
function Read-Journal([string]$Path, [string]$Source, [string]$Destination) {
    Assert-ControlPath $Path $Source $Destination
    $journal = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if ($journal.Version -ne 1 -or $journal.Id -notmatch '^[a-f0-9]{32}$' -or
        $journal.Source -cne $Source -or $journal.Destination -cne $Destination -or
        $journal.Backup -cne ($Source + '.migration-backup-' + $journal.Id)) { throw 'Journal identity or path validation failed.' }
    if ($journal.RestorePath -and $journal.RestorePath -notmatch ('^' + [regex]::Escape($Source) + '\.migration-restore-[a-f0-9]{32}$')) { throw 'Unexpected restore staging path.' }
    if ($journal.Phase -notin @('Copying', 'CopyVerified', 'Switching', 'Completed', 'Failed', 'RestoreCopying', 'InstallingRestore', 'RolledBack', 'Aborted')) { throw 'Unrecognized journal phase.' }
    return $journal
}
function Invoke-Locked([string]$Source, [string]$StatePath, [scriptblock]$Action) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Source.ToUpperInvariant()))).Replace('-', '') }
    finally { $sha.Dispose() }
    $mutex = [Threading.Mutex]::new($false, ('Local\CodexDataMover-' + $key))
    $held = $false; $lock = $null
    try {
        try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Another migration is using this source.' }
        $lock = [IO.File]::Open(($StatePath + '.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        & $Action
    } finally {
        if ($null -ne $lock) { $lock.Dispose() }
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
function Assert-Junction([string]$Path, [string]$Destination) {
    Assert-PlainChain ([IO.Path]::GetDirectoryName($Path))
    $item = Get-Item -LiteralPath $Path -Force
    $targets = @($item.Target)
    if ($item.LinkType -ne 'Junction' -or $targets.Count -ne 1 -or
        -not [string]::Equals((Get-NormalPath ([string]$targets[0])), $Destination, [StringComparison]::OrdinalIgnoreCase)) { throw 'The compatibility junction does not point to the expected destination.' }
    Assert-PlainChain $Destination
    if (-not [IO.Directory]::Exists($Destination)) { throw 'The destination is missing.' }
}
function Invoke-Migration([string]$Source, [string]$Destination, [string]$StatePath) {
    $Source = Get-NormalPath $Source; $Destination = Get-NormalPath $Destination; $StatePath = Get-NormalPath $StatePath
    Assert-DataScope $Source $Destination
    Assert-ControlPath $StatePath $Source $Destination
    Invoke-Locked $Source $StatePath {
        if ([IO.File]::Exists($StatePath)) {
            $previous = Read-Journal $StatePath $Source $Destination
            if ($previous.Phase -eq 'Completed') {
                Assert-Junction $Source $Destination
                Write-Host 'Already migrated. No second copy or rename was performed.'
                return $previous
            }
            throw 'A previous transaction exists. Inspect Status and use Rollback before choosing a fresh state and destination.'
        }
        Assert-CopyPair $Source $Destination; Assert-Quiescent
        $id = [guid]::NewGuid().ToString('N')
        $journal = [pscustomobject]@{
            Version = 1; Id = $id; Source = $Source; Destination = $Destination
            Backup = ($Source + '.migration-backup-' + $id); RestorePath = ''
            Phase = 'Copying'; UpdatedUtc = ''; Files = 0; Bytes = 0
            ErrorCode = $null; CopyExitCode = $null
        }
        if (Test-Path -LiteralPath $journal.Backup) { throw 'The original-backup path already exists.' }
        Save-Journal $journal $StatePath
        try {
            Write-Host 'Copying and verifying. Originals remain in place.'
            $result = Copy-VerifiedTree $Source $Destination
            $journal.Files = $result.Files; $journal.Bytes = $result.Bytes; $journal.CopyExitCode = $script:LastCopyExitCode
            $journal.Phase = 'CopyVerified'; Save-Journal $journal $StatePath
            Assert-Quiescent
            $null = Assert-TreesEqual $Source $Destination
            $journal.Phase = 'Switching'; Save-Journal $journal $StatePath
            # Journal intent before either filesystem change, so a power interruption is recoverable.
            [IO.Directory]::Move($Source, $journal.Backup)
            $null = New-Item -ItemType Junction -Path $Source -Target $Destination
            Assert-Junction $Source $Destination
            $journal.Phase = 'Completed'; Save-Journal $journal $StatePath
            Write-Host 'MIGRATION COMPLETE. Reopen and validate applications. Original backup retained.'
            return $journal
        } catch {
            $failure = $_
            # If renaming succeeded but junction creation failed, restore the source name immediately.
            if (-not (Test-Path -LiteralPath $Source) -and [IO.Directory]::Exists($journal.Backup)) {
                Assert-PlainChain $journal.Backup
                [IO.Directory]::Move($journal.Backup, $Source)
            }
            $journal.Phase = 'Failed'; $journal.ErrorCode = $failure.Exception.GetBaseException().HResult -band 65535
            $journal.CopyExitCode = $script:LastCopyExitCode
            Save-Journal $journal $StatePath
            throw 'MIGRATION NOT COMPLETE. Data copies were retained. Inspect Status, then use Rollback.'
        }
    }
}
function Invoke-Rollback([string]$Source, [string]$Destination, [string]$StatePath) {
    $Source = Get-NormalPath $Source; $Destination = Get-NormalPath $Destination; $StatePath = Get-NormalPath $StatePath
    Assert-DataScope $Source $Destination; Assert-ControlPath $StatePath $Source $Destination
    Invoke-Locked $Source $StatePath {
        $journal = Read-Journal $StatePath $Source $Destination
        Assert-Quiescent
        $sourceItem = Get-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
        if ($null -ne $sourceItem -and -not ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            if ($journal.Phase -eq 'InstallingRestore') {
                if (-not $journal.RestorePath -or (Test-Path -LiteralPath $journal.RestorePath)) { throw 'Restore staging is ambiguous. Nothing was overwritten.' }
                # The restore rename completed, but its final journal update was interrupted.
                $null = Assert-TreesEqual $Destination $Source
            } elseif ($journal.Phase -notin @('RolledBack', 'Aborted', 'Copying', 'CopyVerified', 'Failed', 'Switching')) { throw 'An unexpected plain directory occupies the source. No data was overwritten.' }
            Assert-PlainChain $Source
            $journal.Phase = if ([IO.Directory]::Exists($journal.Backup)) { 'RolledBack' } else { 'Aborted' }
            Save-Journal $journal $StatePath
            Write-Host 'Original path is a plain directory. All destination copies are retained.'
            return $journal
        }
        Assert-PlainChain $journal.Backup
        if (-not [IO.Directory]::Exists($journal.Backup)) { throw 'The recorded original backup is missing. Nothing was changed.' }
        if ($null -eq $sourceItem -and -not $journal.RestorePath -and $journal.Phase -eq 'Switching') {
            # An interruption happened between source rename and junction creation.
            [IO.Directory]::Move($journal.Backup, $Source)
            $journal.Phase = 'RolledBack'; Save-Journal $journal $StatePath
            return $journal
        }
        if ($null -ne $sourceItem) { Assert-Junction $Source $Destination }
        # Preserve post-migration writes: copy CURRENT destination contents back to a fresh staging tree.
        # The stale original backup and the destination remain untouched.
        $restore = $Source + '.migration-restore-' + [guid]::NewGuid().ToString('N')
        $journal.RestorePath = $restore; $journal.Phase = 'RestoreCopying'; Save-Journal $journal $StatePath
        $null = Copy-VerifiedTree $Destination $restore
        Assert-Quiescent
        $null = Assert-TreesEqual $Destination $restore
        $journal.Phase = 'InstallingRestore'; Save-Journal $journal $StatePath
        if ($null -ne $sourceItem) {
            Assert-Junction $Source $Destination
            [IO.Directory]::Delete($Source, $false)
        }
        [IO.Directory]::Move($restore, $Source)
        $journal.Phase = 'RolledBack'; Save-Journal $journal $StatePath
        Write-Host 'ROLLBACK COMPLETE. Latest data restored; original backup and destination retained.'
        return $journal
    }
}
function Wait-ForQuiescence([int]$TimeoutSeconds, [int]$QuietSeconds) {
    $elapsed = [Diagnostics.Stopwatch]::StartNew(); $quiet = [Diagnostics.Stopwatch]::StartNew()
    $previous = ''; $heartbeat = [Diagnostics.Stopwatch]::StartNew()
    Write-Host 'Waiting for applications and helpers to close. Keep this migration window open.'
    while ($elapsed.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $blockers = @(Get-BlockingProcesses)
        if ($blockers.Count) {
            $quiet.Restart()
            $summary = ($blockers | ForEach-Object { $_.Name + ' (PID ' + $_.PID + ', parent ' + $_.ParentPID + ')' }) -join ', '
        } else {
            if ($quiet.Elapsed.TotalSeconds -ge $QuietSeconds) { return }
            $summary = 'No blockers. Waiting for the quiet period.'
        }
        if ($summary -ne $previous -or $heartbeat.Elapsed.TotalSeconds -ge 10) {
            Write-Host $summary; $previous = $summary; $heartbeat.Restart()
        }
        Start-Sleep -Seconds 1
    }
    throw 'Timed out waiting for a quiet session. No migration was started.'
}
