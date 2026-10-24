#requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'These regression tests require Windows.' }

# Minimal isolated reproductions of the old decisions. No real user data is used.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$split = [Security.AccessControl.RawSecurityDescriptor]::new("D:(A;;0x1;;;$identity)(A;;0x2;;;$identity)")
$merged = [Security.AccessControl.RawSecurityDescriptor]::new("D:(A;;0x3;;;$identity)")
$oldComparison = $split.GetSddlForm('Access') -ceq $merged.GetSddlForm('Access')
if ($oldComparison) { throw 'The ACL comparison regression was not reproduced.' }

$source = 'C:\Example\Data'
$ownedCopy = [pscustomobject]@{
    ProcessId = 12345; ParentProcessId = $PID; Name = 'robocopy.exe'
    ExecutablePath = (Join-Path $env:SystemRoot 'System32\robocopy.exe')
    CommandLine = ('robocopy.exe "' + $source + '" "D:\Example\Data" /E')
}
$oldProcessCheck = $ownedCopy.CommandLine.IndexOf($source, [StringComparison]::OrdinalIgnoreCase) -ge 0
if (-not $oldProcessCheck) { throw 'The owned-copy false positive was not reproduced.' }

[pscustomobject]@{
    EquivalentAclRejectedByOldComparison = (-not $oldComparison)
    OwnedRobocopyBlockedByOldCheck = $oldProcessCheck
    RealDataRead = $false
    RealMigrationPerformed = $false
} | ConvertTo-Json
