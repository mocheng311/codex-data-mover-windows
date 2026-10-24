#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Migrate', 'Status', 'Verify', 'Rollback')][string]$Mode = 'Plan',
    [ValidateSet('Home', 'Workspace', 'LocalRuntime', 'AppData', 'RuntimeCache', 'Custom')][string]$Component = 'Home',
    [string]$DestinationRoot = 'D:\CodexData',
    [string]$SourcePath,
    [string]$DestinationPath,
    [string]$StatePath
)
. (Join-Path $PSScriptRoot 'Migration.Transaction.ps1')
Assert-Windows
try {
    $profileRoot = [Environment]::GetFolderPath('UserProfile')
    $defaults = @{
        Home = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $profileRoot '.codex' })
        Workspace = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Codex')
        LocalRuntime = (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex')
        AppData = (Join-Path $env:APPDATA 'Codex')
        RuntimeCache = (Join-Path $profileRoot '.cache\codex-runtimes')
    }
    if ($Component -eq 'Custom') {
        if (-not $SourcePath -or -not $DestinationPath) { throw 'Custom mode requires explicit SourcePath and DestinationPath.' }
    } else {
        if ($SourcePath -or $DestinationPath) { throw 'Use Component Custom when providing explicit data paths.' }
        $SourcePath = $defaults[$Component]; $DestinationPath = Join-Path $DestinationRoot $Component
    }
    $source = Get-NormalPath $SourcePath; $destination = Get-NormalPath $DestinationPath
    $state = if ($StatePath) { Get-NormalPath $StatePath } else { Join-Path ([IO.Path]::GetDirectoryName($destination)) ($Component + '.migration-state.json') }
    foreach ($root in @($source, $destination)) {
        if (Test-Inside (Get-NormalPath $PSScriptRoot) $root) { throw 'Run the tool from a directory outside both migration trees.' }
    }
    $script:GuardPaths = @($source, $destination)
    Assert-DataScope $source $destination
    if ($Mode -eq 'Plan') {
        [pscustomobject]@{ Component = $Component; Source = $source; Destination = $destination; State = $state; SourceExists = [IO.Directory]::Exists($source); DestinationExists = [IO.Directory]::Exists($destination); BlockingProcesses = @(Get-BlockingProcesses); ChangesMade = $false } | ConvertTo-Json -Depth 4
    } elseif ($Mode -eq 'Status') {
        Read-Journal $state $source $destination | Select-Object Phase, Files, Bytes, UpdatedUtc, ErrorCode, CopyExitCode, Source, Destination, Backup, RestorePath | ConvertTo-Json
    } elseif ($Mode -eq 'Migrate') {
        $null = Invoke-Migration $source $destination $state
    } elseif ($Mode -eq 'Rollback') {
        $null = Invoke-Rollback $source $destination $state
    } else {
        $journal = Read-Journal $state $source $destination
        if ($journal.Phase -ne 'Completed') { throw 'Verify requires a completed migration.' }
        Assert-Junction $source $destination
        Assert-PlainChain $journal.Backup
        [pscustomobject]@{ JunctionValid = $true; OriginalBackupExists = [IO.Directory]::Exists($journal.Backup); CurrentTree = (Get-Tree $destination); Note = 'Current data may legitimately differ from the original backup after application use.' } | Select-Object JunctionValid, OriginalBackupExists, @{Name='Files';Expression={$_.CurrentTree.Files}}, Note | ConvertTo-Json
    }
    exit 0
} catch {
    Write-Host ('NOT COMPLETED: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
