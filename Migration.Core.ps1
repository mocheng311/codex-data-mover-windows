#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:OwnedCopy = $null
$script:GuardPaths = @()
$script:LastCopyExitCode = $null

function Assert-Windows {
    if ($env:OS -ne 'Windows_NT') { throw 'Windows is required.' }
}
function Get-NormalPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:[\\/]' -or
        $Path.Substring(2).Contains(':') -or $Path -match '[*?\[\]]') { throw 'Use an absolute local drive path without wildcards or streams.' }
    foreach ($segment in $Path.Replace('/', '\').Substring(3).TrimEnd('\').Split('\')) {
        if ($segment -match '[. ]$|^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw 'Ambiguous or reserved Windows path names are unsupported.' }
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full.Length -le 2) { throw 'A volume root cannot be a migration directory.' }
    return $full
}
function Test-Inside([string]$Path, [string]$Root) {
    return $Path.Equals($Root, [StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)
}
function Assert-PlainChain([string]$Path) {
    $current = [IO.DirectoryInfo]::new((Get-NormalPath $Path))
    while ($null -ne $current) {
        $item = Get-Item -LiteralPath $current.FullName -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'A path or ancestor is redirected. Review it before migration.' }
        $current = $current.Parent
    }
}
function Assert-LocalNtfs([string]$Path) {
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Path))
    if (-not $drive.IsReady -or $drive.DriveType -ne 'Fixed' -or $drive.DriveFormat -ne 'NTFS') { throw 'A ready, fixed, local NTFS volume is required.' }
}
function Assert-NotSynced([string]$Path) {
    $roots = [Collections.Generic.List[string]]::new()
    foreach ($name in @('OneDrive', 'OneDriveCommercial', 'OneDriveConsumer')) {
        foreach ($scope in @('Process', 'User')) {
            $value = [Environment]::GetEnvironmentVariable($name, $scope)
            if ($value) { $roots.Add($value) }
        }
    }
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager'
    if (Test-Path -LiteralPath $key) {
        foreach ($entry in Get-ChildItem -LiteralPath $key) {
            $subkey = Join-Path $entry.PSPath 'UserSyncRoots'
            if (Test-Path -LiteralPath $subkey) {
                foreach ($property in (Get-ItemProperty -LiteralPath $subkey).PSObject.Properties) {
                    if ($property.Name -notmatch '^PS' -and $property.Value -is [string]) { $roots.Add($property.Value) }
                }
            }
        }
    }
    foreach ($root in $roots) {
        $normalized = Get-NormalPath $root
        if ((Test-Inside $Path $normalized) -or (Test-Inside $normalized $Path)) { throw 'The destination overlaps a registered synchronization root.' }
    }
}
function Get-AccessSignature($Acl) {
    $raw = [Security.AccessControl.RawSecurityDescriptor]::new($Acl.GetSecurityDescriptorBinaryForm(), 0)
    if ($null -eq $raw.DiscretionaryAcl) { throw 'Null DACLs are not supported.' }
    $blocks = [Collections.Generic.List[string]]::new()
    $qualifier = ''; $rules = @{}
    foreach ($ace in $raw.DiscretionaryAcl) {
        if ($ace -isnot [Security.AccessControl.CommonAce] -or $ace.IsCallback -or
            $ace.AceType -notin @([Security.AccessControl.AceType]::AccessAllowed, [Security.AccessControl.AceType]::AccessDenied)) { throw 'Unsupported access rule.' }
        $next = $ace.AceQualifier.ToString()
        if ($next -ne $qualifier -and $rules.Count) {
            $parts = @($rules.Keys | Sort-Object | ForEach-Object { $_ + '=' + $rules[$_] })
            $blocks.Add($qualifier + '[' + ($parts -join ';') + ']'); $rules = @{}
        }
        $qualifier = $next
        $flags = [int]$ace.AceFlags -band (-bnot [int][Security.AccessControl.AceFlags]::Inherited)
        $key = $ace.SecurityIdentifier.Value + '|' + $flags
        if (-not $rules.ContainsKey($key)) { $rules[$key] = 0L }
        $rules[$key] = $rules[$key] -bor [long]$ace.AccessMask
    }
    if ($rules.Count) {
        $parts = @($rules.Keys | Sort-Object | ForEach-Object { $_ + '=' + $rules[$_] })
        $blocks.Add($qualifier + '[' + ($parts -join ';') + ']')
    }
    return $blocks -join '|'
}
function Set-PreservedAccess([string]$Source, [string]$Destination) {
    $item = Get-Item -LiteralPath $Destination -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Cannot set permissions through a reparse point.' }
    $original = Get-Acl -LiteralPath $Source
    if (-not $original.AreAccessRulesCanonical) { throw 'Noncanonical permissions require manual review.' }
    $expected = Get-AccessSignature $original
    $copy = if ($item.PSIsContainer) { [Security.AccessControl.DirectorySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
    $copy.SetSecurityDescriptorSddlForm($original.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access), [Security.AccessControl.AccessControlSections]::Access)
    $copy.SetAccessRuleProtection($true, $true)
    if ((Get-AccessSignature $copy) -cne $expected) { throw 'Permission conversion would change access rights.' }
    # Persist access rules only. Set-Acl can also request SACL privileges.
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        if ($item.PSIsContainer) { ([IO.DirectoryInfo]::new($Destination)).SetAccessControl($copy) }
        else { ([IO.FileInfo]::new($Destination)).SetAccessControl($copy) }
    } else {
        if ($item.PSIsContainer) { [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($Destination), $copy) }
        else { [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($Destination), $copy) }
    }
    if ((Get-AccessSignature (Get-Acl -LiteralPath $Destination)) -cne $expected) { throw 'Permission preservation failed.' }
}
function Get-FileStreams([string]$Path) {
    return @(Get-Item -LiteralPath $Path -Force -Stream '*' -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{ Name = [string]$_.Stream; Length = [long]$_.Length }
    } | Sort-Object Name)
}
function Get-StreamPath([string]$Path, [string]$Name) {
    if ($Name -eq ':$DATA') { return $Path }
    # The extended local path form is needed for named streams on .NET Framework.
    return '\\?\' + $Path + ':' + $Name
}
function Get-Fingerprint([string]$Path) {
    $stream = $null; $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $buffer = New-Object byte[] (4MB)
        [long]$processed = 0; $timer = [Diagnostics.Stopwatch]::StartNew()
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $null = $sha.TransformBlock($buffer, 0, $read, $buffer, 0); $processed += $read
            if ($timer.Elapsed.TotalSeconds -ge 15) {
                Assert-Quiescent
                Write-Host ('Verifying file data: ' + [Math]::Round($processed / 1MB) + ' MiB processed.')
                $timer.Restart()
            }
        }
        $null = $sha.TransformFinalBlock($buffer, 0, 0)
        return [Convert]::ToBase64String($sha.Hash)
    } finally { if ($null -ne $stream) { $stream.Dispose() }; $sha.Dispose() }
}
function Get-Tree([string]$Root, [switch]$CheckReadable) {
    Assert-PlainChain $Root
    $entries = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    $stack = [Collections.Generic.Stack[string]]::new(); $stack.Push($Root)
    [long]$bytes = 0; [long]$files = 0
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($stack.Count) {
        $path = $stack.Pop()
        if ($path.Length -gt 240) { throw 'Paths longer than 240 characters require separate handling.' }
        $item = Get-Item -LiteralPath $path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Nested links and cloud placeholders require separate handling; nothing will be skipped.' }
        if (($item.Attributes -band [IO.FileAttributes]::Encrypted) -or ([int]$item.Attributes -band 0x00441000)) { throw 'Encrypted, offline or recalled data is unsupported.' }
        $relative = $path.Substring($Root.Length).TrimStart('\')
        $acl = Get-Acl -LiteralPath $path
        if (-not $acl.AreAccessRulesCanonical) { throw 'Noncanonical permissions require manual review.' }
        $streams = @()
        if ($item.PSIsContainer) {
            foreach ($child in ([IO.DirectoryInfo]::new($path)).GetFileSystemInfos()) { $stack.Push($child.FullName) }
        } else {
            $files++; $streams = @(Get-FileStreams $path)
            foreach ($stream in $streams) {
                $bytes += $stream.Length
                if ($CheckReadable) {
                    $handle = $null
                    try { $handle = [IO.File]::Open((Get-StreamPath $path $stream.Name), 'Open', 'Read', 'Read') }
                    catch { throw ('A file is inaccessible or open for writing (Windows error ' + ($_.Exception.GetBaseException().HResult -band 65535) + '). Close applications before copying.') }
                    finally { if ($null -ne $handle) { $handle.Dispose() } }
                }
            }
        }
        $entries.Add($relative, [pscustomobject]@{
            Directory = [bool]$item.PSIsContainer; WriteTicks = $item.LastWriteTimeUtc.Ticks
            BasicAttributes = ([int]$item.Attributes -band 0x27)
            Access = (Get-AccessSignature $acl); Streams = $streams
        })
        if ($entries.Count % 100 -eq 0) { Assert-Quiescent }
        if ($timer.Elapsed.TotalSeconds -ge 15) { Write-Host ('Checking tree: ' + $entries.Count + ' entries.'); $timer.Restart() }
    }
    return [pscustomobject]@{ Entries = $entries; Files = $files; Bytes = $bytes }
}
function Test-ProcessBlocks($Process, $Owned, [string[]]$Paths) {
    if ($Process.ProcessId -eq $PID) { return $false }
    if ($null -ne $Owned -and $Process.ProcessId -eq $Owned.Id -and
        $Process.ParentProcessId -eq $PID -and $Process.Name -ieq 'robocopy.exe' -and
        [string]::Equals([string]$Process.ExecutablePath, (Join-Path $env:SystemRoot 'System32\robocopy.exe'), [StringComparison]::OrdinalIgnoreCase) -and
        [Math]::Abs(($Process.CreationDate.ToUniversalTime() - $Owned.StartUtc).TotalMilliseconds) -lt 10) { return $false }
    if ($Process.Name -match '^(Codex|ChatGPT|cc-switch|codex-windows-sandbox-service)\.exe$') { return $true }
    foreach ($path in $Paths) {
        if ($Process.ExecutablePath -and (Test-Inside ([string]$Process.ExecutablePath) $path)) { return $true }
        if ($Process.CommandLine -and $Process.CommandLine.IndexOf($path, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}
function Get-BlockingProcesses {
    if (-not $script:GuardPaths.Count) { return @() }
    foreach ($process in Get-CimInstance Win32_Process -ErrorAction Stop) {
        if (Test-ProcessBlocks $process $script:OwnedCopy $script:GuardPaths) {
            [pscustomobject]@{ Name = $process.Name; PID = $process.ProcessId; ParentPID = $process.ParentProcessId }
        }
    }
}
function Assert-Quiescent {
    $blockers = @(Get-BlockingProcesses)
    if ($blockers.Count) { throw ('Applications are using protected paths. Close them normally. Blockers: ' + (($blockers | ForEach-Object { $_.Name + ' (PID ' + $_.PID + ', parent ' + $_.ParentPID + ')' }) -join ', ')) }
}
function Assert-CopyPair([string]$Source, [string]$Destination) {
    $sourcePath = Get-NormalPath $Source; $destinationPath = Get-NormalPath $Destination
    if ((Test-Inside $sourcePath $destinationPath) -or (Test-Inside $destinationPath $sourcePath)) { throw 'Source and destination overlap.' }
    Assert-LocalNtfs $sourcePath; Assert-LocalNtfs $destinationPath
    Assert-PlainChain $sourcePath; Assert-PlainChain $destinationPath
    Assert-NotSynced $sourcePath; Assert-NotSynced $destinationPath
    if (-not [IO.Directory]::Exists($sourcePath)) { throw 'Source directory is missing.' }
    if (Test-Path -LiteralPath $destinationPath) { throw 'Destination already exists. Never merge into an unknown directory.' }
    if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($destinationPath))) { throw 'Create the destination parent directory first.' }
}
function Invoke-DataCopy([string]$Source, [string]$Destination) {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    $psi.Arguments = (@($Source, $Destination, '/E', '/COPY:DAT', '/DCOPY:DAT', '/XJ', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $psi
    $started = $false
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $started = $process.Start()
        $script:OwnedCopy = [pscustomobject]@{Id=$process.Id;StartUtc=$process.StartTime.ToUniversalTime()}
        $output = $process.StandardOutput.ReadToEndAsync(); $errors = $process.StandardError.ReadToEndAsync()
        do {
            Assert-Quiescent
            if ($timer.Elapsed.TotalSeconds -ge 15) { Write-Host 'Robocopy is still running; content verification follows.'; $timer.Restart() }
        } while (-not $process.WaitForExit(1000))
        $null = $output.GetAwaiter().GetResult(); $null = $errors.GetAwaiter().GetResult()
        $script:LastCopyExitCode = $process.ExitCode
        if ($process.ExitCode -ge 8) { throw ('Robocopy failed (exit ' + $process.ExitCode + '). Originals remain intact.') }
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $script:OwnedCopy = $null; $process.Dispose()
    }
}
function Assert-TreesEqual([string]$Source, [string]$Destination) {
    $before = Get-Tree $Source -CheckReadable; $after = Get-Tree $Destination -CheckReadable
    if ($before.Entries.Count -ne $after.Entries.Count -or $before.Bytes -ne $after.Bytes) { throw 'Entry count or byte count differs.' }
    foreach ($name in $before.Entries.Keys) {
        if (-not $after.Entries.ContainsKey($name)) { throw 'A destination entry is missing.' }
        $a = $before.Entries[$name]; $b = $after.Entries[$name]
        if ($a.Directory -ne $b.Directory -or $a.Access -cne $b.Access -or $a.BasicAttributes -ne $b.BasicAttributes) { throw 'Entry type, basic attributes or permissions differ.' }
        if (-not $a.Directory) {
            if ($a.WriteTicks -ne $b.WriteTicks -or ($a.Streams | ConvertTo-Json -Compress) -cne ($b.Streams | ConvertTo-Json -Compress)) { throw 'File timestamp or streams differ.' }
            foreach ($stream in $a.Streams) {
                $left = Get-StreamPath (Join-Path $Source $name) $stream.Name
                $right = Get-StreamPath (Join-Path $Destination $name) $stream.Name
                if ((Get-Fingerprint $left) -cne (Get-Fingerprint $right)) { throw 'File content verification failed.' }
            }
        }
    }
    Assert-Quiescent
    return [pscustomobject]@{ Files = $before.Files; Bytes = $before.Bytes; Entries = $before.Entries.Count }
}
function Copy-VerifiedTree([string]$Source, [string]$Destination) {
    Write-Verbose 'Validating the copy pair and source readability.'
    Assert-CopyPair $Source $Destination; Assert-Quiescent
    $tree = Get-Tree $Source -CheckReadable
    foreach ($name in $tree.Entries.Keys) {
        if (($Destination.Length + 1 + $name.Length) -gt 240) { throw 'A destination path would exceed the supported length.' }
    }
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Destination))
    if ($drive.AvailableFreeSpace -lt ($tree.Bytes + [Math]::Max(64MB, [long]($tree.Bytes * 0.1)))) { throw 'Insufficient free space including the safety margin.' }
    $null = New-Item -ItemType Directory -Path $Destination
    Set-PreservedAccess $Source $Destination
    Write-Verbose 'Copying file data.'
    Invoke-DataCopy $Source $Destination
    # Check the source again: /XJ is only a second defense, never permission to skip links.
    $current = Get-Tree $Source -CheckReadable
    Write-Verbose 'Restoring access rules.'
    if ($tree.Entries.Count -ne $current.Entries.Count) { throw 'The source changed while copying.' }
    foreach ($name in $current.Entries.Keys) {
        $sourceItem = if ($name) { Join-Path $Source $name } else { $Source }
        $destinationItem = if ($name) { Join-Path $Destination $name } else { $Destination }
        Set-PreservedAccess $sourceItem $destinationItem
        $attributes = [int][IO.File]::GetAttributes($destinationItem)
        $attributes = ($attributes -band (-bnot 0x27)) -bor $current.Entries[$name].BasicAttributes
        [IO.File]::SetAttributes($destinationItem, [IO.FileAttributes]$attributes)
    }
    Write-Verbose 'Verifying data, streams and permissions.'
    return Assert-TreesEqual $Source $Destination
}
