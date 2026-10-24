#requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Status', 'Stop', 'Start')][string]$Action = 'Status')
. (Join-Path $PSScriptRoot 'Migration.Core.ps1')
Assert-Windows
try {
    $name = 'CodexSandboxService.OpenAI.Codex'
    $service = Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction Stop
    if ($null -eq $service) { throw 'The known Codex sandbox service is not installed. No service was changed.' }
    $binary = [regex]::Match([string]$service.PathName, '^\s*(?:"([^"]+)"|(.+?\.exe)(?:\s|$))', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $executable = $binary.Groups[1].Value + $binary.Groups[2].Value
    if ([IO.Path]::GetFileName($executable) -ine 'codex-windows-sandbox-service.exe' -or -not [IO.File]::Exists($executable)) { throw 'Service binary identity did not match. No service was changed.' }
    $signature = Get-AuthenticodeSignature -LiteralPath $executable
    if ($signature.Status -ne 'Valid') { throw 'Service binary signature is not valid. No service was changed.' }
    if ($Action -ne 'Status') {
        $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Open a separate administrator PowerShell for the service action. Run migration as the original user.' }
        if ($Action -eq 'Stop') {
            $script:GuardPaths = @((Join-Path $env:USERPROFILE '.codex'), (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex'), (Join-Path $env:USERPROFILE '.cache\codex-runtimes'))
            $blockers = @(Get-BlockingProcesses | Where-Object { $_.PID -ne $service.ProcessId })
            if ($blockers.Count) { throw 'Close Codex, browser helpers and related applications normally before stopping its service.' }
            if (@((Get-Service -Name $name).DependentServices | Where-Object { $_.Status -eq 'Running' }).Count) { throw 'A dependent service is running. Nothing was stopped.' }
            Stop-Service -Name $name -ErrorAction Stop
            (Get-Service -Name $name).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        } else {
            Start-Service -Name $name -ErrorAction Stop
            (Get-Service -Name $name).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
        }
    }
    $after = Get-CimInstance Win32_Service -Filter "Name='$name'"
    [pscustomobject]@{ Name=$name; State=$after.State; StartMode=$after.StartMode; Action=$Action } | ConvertTo-Json
    exit 0
} catch { Write-Host ('Service action not completed: ' + $_.Exception.Message); exit 1 }
