@echo off
setlocal
title Codex Runtime Repair
set "SELF=%~f0"
set "REPAIR_ORIGINAL_SID=%~1"

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -Command ^
  "$ErrorActionPreference = 'Stop'; try { $identity = [Security.Principal.WindowsIdentity]::GetCurrent(); $sid = $identity.User.Value; $originalSid = $env:REPAIR_ORIGINAL_SID; if ([string]::IsNullOrWhiteSpace($originalSid)) { $originalSid = $sid }; if ($originalSid -notmatch '^S-1-[0-9-]+$') { throw 'Invalid original user SID.' }; if ($sid -ne $originalSid) { throw 'This repair must be elevated using the same Windows account. Do not enter credentials for another administrator account.' }; $principal = New-Object Security.Principal.WindowsPrincipal($identity); if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { $child = Start-Process -FilePath $env:SELF -ArgumentList $originalSid -Verb RunAs -Wait -PassThru -ErrorAction Stop; exit $child.ExitCode }; $lines = Get-Content -LiteralPath $env:SELF -Encoding UTF8; $marker = [Array]::IndexOf($lines, '#__POWERSHELL__'); if ($marker -lt 0) { throw 'PowerShell payload marker not found.' }; $code = $lines[($marker + 1)..($lines.Count - 1)] -join [Environment]::NewLine; & ([ScriptBlock]::Create($code)) -OriginalSid $originalSid } catch { Write-Host 'FAILED' -ForegroundColor Red; Write-Host $_.Exception.Message; exit 1 }"
set "RC=%errorlevel%"

echo.
echo ------------------------------------------------------------
echo Script finished. Press any key to close this window.
pause >nul
exit /b %RC%

#__POWERSHELL__
param([Parameter(Mandatory = $true)][string]$OriginalSid)
$ErrorActionPreference = 'Stop'

$ownedMaps = @{}
$mutex = $null
$mutexHeld = $false
$failure = $null
$successMessage = $null
$S = $null
$T = $null
$finalBackup = $null
$committed = $false
$identityFiles = @('manifest.json', 'bin/node.exe', 'bin/node_repl.exe')

function Get-RepairUserSid {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-RuntimeRoot {
    return Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'OpenAI\Codex\runtimes\cua_node'
}

function Initialize-DosDeviceApi {
    if ('CodexRepair.DosDevice' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace CodexRepair {
    public static class DosDevice {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern uint QueryDosDevice(string name, StringBuilder target, int capacity);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool DefineDosDevice(uint flags, string name, string target);
    }
}
'@
}

function Get-DosDevice([string]$Drive) {
    $buffer = New-Object Text.StringBuilder 32768
    if ([CodexRepair.DosDevice]::QueryDosDevice("$Drive`:", $buffer, $buffer.Capacity)) {
        # The first NUL-terminated entry is the current mapping.
        return ($buffer.ToString() -split "`0")[0]
    }
    $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($code -eq 2) { return $null }
    throw "QueryDosDevice failed for $Drive`: (Win32 error $code)."
}

function Invoke-SubstCreate([string]$Drive, [string]$Path) {
    & "$env:SystemRoot\System32\subst.exe" "$Drive`:" $Path | Out-Null
    return $LASTEXITCODE
}

function Remove-DosDeviceExact([string]$Drive, [string]$Target) {
    # RAW_TARGET_PATH | REMOVE_DEFINITION | EXACT_MATCH_ON_REMOVE.
    # Exact removal also closes the query-to-delete race; a replacement is not removed.
    if (-not [CodexRepair.DosDevice]::DefineDosDevice(7, "$Drive`:", $Target)) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Unable to remove owned SUBST $Drive`: (Win32 error $code)."
    }
}

function Assert-OwnedMap([string]$Drive) {
    if (-not $Drive -or -not $ownedMaps.ContainsKey($Drive)) { throw 'Unowned SUBST drive.' }
    $actual = Get-DosDevice $Drive
    if (-not [string]::Equals($actual, $ownedMaps[$Drive], [StringComparison]::OrdinalIgnoreCase)) {
        throw "SUBST $Drive`: changed or disappeared; repair aborted without removing its replacement."
    }
}

function Mount-Subst([string]$Path) {
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    foreach ($letter in 'ZYXWVUTSRQPONMLKJIHGFED'.ToCharArray()) {
        $drive = [string]$letter
        if (Get-DosDevice $drive) { continue }
        $exitCode = Invoke-SubstCreate $drive $fullPath
        # Another tool may have won this letter. Never claim a failed creation.
        if ($exitCode -ne 0) { continue }
        # Record success before any further check can throw (including an inaccessible target).
        $ownedMaps[$drive] = '\??\' + $fullPath
        Assert-OwnedMap $drive
        if (-not (Test-Path -LiteralPath "$drive`:\" -PathType Container)) {
            throw "SUBST target is not accessible: $fullPath"
        }
        return $drive
    }
    throw 'Unable to create an owned temporary SUBST drive.'
}

function Dismount-Subst([string]$Drive) {
    if (-not $Drive -or -not $ownedMaps.ContainsKey($Drive)) { return }
    $actual = Get-DosDevice $Drive
    if ($null -eq $actual) { $ownedMaps.Remove($Drive); return }
    Assert-OwnedMap $Drive
    Remove-DosDeviceExact $Drive $ownedMaps[$Drive]
    $actual = Get-DosDevice $Drive
    if ($null -ne $actual) { throw "SUBST $Drive`: still has a mapping after cleanup." }
    $ownedMaps.Remove($Drive)
}

function Remove-Maps {
    # Try every owned map independently. Return errors; do not replace a repair exception.
    foreach ($drive in @($ownedMaps.Keys)) {
        try { Dismount-Subst $drive }
        catch { $_.Exception.Message }
    }
}

function Assert-OrdinaryDirectory([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Not an ordinary runtime directory: $Path"
    }
}

function Assert-RuntimeMapping([string]$Root) {
    if ($Root -match '^([A-Za-z]):\\' -and $null -ne $ownedMaps -and $ownedMaps.ContainsKey($Matches[1])) {
        Assert-OwnedMap $Matches[1]
    }
}

function Assert-RuntimePath([string]$Path) {
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not $fullPath.StartsWith($rt + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing a path outside the runtime directory: $fullPath"
    }
    # A reparse point in a cache ancestor could redirect an elevated write outside the cache.
    $cursor = $fullPath
    while ($cursor.Length -ge $localAppData.Length) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Runtime reparse point refused: $cursor" }
        }
        if ([string]::Equals($cursor, $localAppData, [StringComparison]::OrdinalIgnoreCase)) { break }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
        if (-not $cursor) { throw 'Invalid runtime ancestor.' }
    }
}

function Get-Map([string]$Root) {
    Assert-RuntimeMapping $Root
    $map = @{}
    $prefix = $Root.TrimEnd('\') + '\'
    Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction Stop | ForEach-Object {
        if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Runtime reparse point refused: $($_.FullName)" }
        if (-not $_.PSIsContainer) {
            if (-not $_.FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Runtime enumeration escaped its root.' }
            $map[$_.FullName.Substring($prefix.Length)] = [Int64]$_.Length
        }
    }
    Assert-RuntimeMapping $Root
    return $map
}

function Get-IdentityFileDigest([string]$Path) {
    # Avoid Get-FileHash module autoload differences when launched from a PowerShell 7 host.
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [IO.File]::OpenRead($Path)
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $sha.Dispose()
    }
}

function Get-RuntimeIdentity([string]$Root) {
    Assert-RuntimeMapping $Root
    Assert-OrdinaryDirectory $Root
    Assert-OrdinaryDirectory (Join-Path $Root 'bin')
    Assert-OrdinaryDirectory (Join-Path $Root 'bin\node_modules')
    $digests = @{}
    $inputText = New-Object Text.StringBuilder
    foreach ($relative in $identityFiles) {
        $path = Join-Path $Root ($relative.Replace('/', '\'))
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -eq 0) {
            throw "Missing or invalid runtime identity file: $path"
        }
        $digest = Get-IdentityFileDigest $path
        $digests[$relative] = $digest
        $null = $inputText.Append($relative).Append([char]0).Append($digest).Append([char]0)
    }
    # Confirmed in Codex 26.911.7940.0, app.asar/.vite/build/src-BiETdQsO.js:
    # nR -> [manifest.json, bin/node.exe, bin/node_repl.exe] -> sR -> cR(...).slice(0,16).
    # SHA256(UTF8(relative + NUL + lowercase SHA256(file bytes) + NUL), in that order).
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($inputText.ToString())))).Replace('-', '').ToLowerInvariant().Substring(0,16) }
    finally { $sha.Dispose() }
    Assert-RuntimeMapping $Root
    return [PSCustomObject]@{ Hash = $hash; Digests = $digests }
}

function Compare-Maps($SourceMap, $TargetMap) {
    foreach ($relative in $SourceMap.Keys) {
        if (-not $TargetMap.ContainsKey($relative)) { "MISSING: $relative" }
        elseif ($TargetMap[$relative] -ne $SourceMap[$relative]) { "SIZE: $relative" }
    }
    foreach ($relative in $TargetMap.Keys) {
        if (-not $SourceMap.ContainsKey($relative)) { "EXTRA: $relative" }
    }
}

function Test-Runtime([string]$Root) {
    $map = Get-Map $Root
    $bad = @(Compare-Maps $srcMap $map)
    if ($map.Count -eq 0) { $bad += 'EMPTY runtime' }
    # Missing keys are ordinary validation failures. Access/query failures still abort.
    foreach ($relative in $identityFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root ($relative.Replace('/', '\'))) -PathType Leaf)) { $bad += "KEY FILE: $relative" }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'bin\node_modules') -PathType Container)) { $bad += 'MISSING: bin\node_modules directory' }
    if ($bad.Count -eq 0) {
        $identity = Get-RuntimeIdentity $Root
        foreach ($relative in $identityFiles) {
            if ($identity.Digests[$relative] -ne $sourceIdentity.Digests[$relative]) { $bad += "CONTENT: $relative" }
        }
    }
    return [PSCustomObject]@{ Complete = ($bad.Count -eq 0); Differences = $bad }
}

function Assert-SourceReady {
    Assert-OwnedMap $S
    Assert-OrdinaryDirectory $src
    $identity = Get-RuntimeIdentity "$S`:\"
    $map = Get-Map "$S`:\"
    if ($map.Count -eq 0 -or $identity.Hash -ne $hash -or @(Compare-Maps $srcMap $map).Count -ne 0) {
        throw 'Official source runtime changed or became invalid; repair aborted.'
    }
    $currentPackages = @(Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop)
    if ($currentPackages.Count -ne 1 -or $currentPackages[0].PackageFullName -ne $pkg.PackageFullName) {
        throw 'Codex package registration changed during repair; close Codex and retry.'
    }
}

function Get-OwnedCodexProcesses {
    $result = @()
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
        if ($process.Name -ine 'ChatGPT.exe' -and $process.Name -ine 'Codex.exe') { continue }
        $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction Stop
        if ($owner.ReturnValue -ne 0 -or -not $owner.Sid) { throw "Cannot determine owner SID of PID $($process.ProcessId)." }
        if ($owner.Sid -ne $OriginalSid) { continue }
        if (-not $process.ExecutablePath) { throw "Cannot determine executable path of PID $($process.ProcessId)." }
        $path = [IO.Path]::GetFullPath($process.ExecutablePath)
        if ($path.StartsWith($installRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { $result += $process }
    }
    return $result
}

function Assert-CodexStopped {
    $running = @(Get-OwnedCodexProcesses)
    if ($running.Count) { throw 'Codex restarted during repair. Close Codex and retry; recoverable work directories have been retained.' }
}

function Stop-OwnedCodexProcess($Snapshot) {
    $live = $null
    try {
        try { $live = Get-Process -Id $Snapshot.ProcessId -ErrorAction Stop }
        catch [ArgumentException] { return }
        # Force an open handle before revalidating identity; held handles prevent PID reuse.
        $null = $live.Handle
        if ($live.HasExited) { return }
        $current = @(Get-OwnedCodexProcesses | Where-Object ProcessId -EQ $Snapshot.ProcessId)
        if ($live.HasExited) { return }
        # CIM timestamps have microsecond precision; FILETIME has 100 ns precision.
        $startDifference = [Math]::Abs($live.StartTime.ToUniversalTime().Ticks - $Snapshot.CreationDate.ToUniversalTime().Ticks)
        if ($current.Count -ne 1 -or $current[0].CreationDate -ne $Snapshot.CreationDate -or $startDifference -ge 10) {
            throw "Process identity changed for PID $($Snapshot.ProcessId); nothing was terminated."
        }
        Stop-Process -InputObject $live -Force -ErrorAction Stop
        if (-not $live.WaitForExit(5000)) { throw "Codex PID $($Snapshot.ProcessId) did not exit." }
    }
    catch {
        if ($null -eq $live -or -not $live.HasExited) { throw }
    }
    finally { if ($null -ne $live) { $live.Dispose() } }
}

function Invoke-RuntimeCopy([string]$SourceRoot, [string]$TargetRoot) {
    & "$env:SystemRoot\System32\robocopy.exe" ($SourceRoot.TrimEnd('\')) ($TargetRoot.TrimEnd('\')) /E /COPY:DT /NODCOPY /R:0 /W:0 /NFL /NDL /NJH /NJS /NP
    $script:xcopyExit = if ($LASTEXITCODE -ge 0 -and $LASTEXITCODE -lt 8) { 0 } else { $LASTEXITCODE }
}

function Remove-RuntimeDirectory([string]$Path) {
    Assert-RuntimePath $Path
    Assert-SourceReady
    Assert-CodexStopped
    Assert-OrdinaryDirectory $Path
    $drive = Mount-Subst $Path
    try { $null = Get-Map "$drive`:\" }
    finally { Dismount-Subst $drive }
    Assert-CodexStopped
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
}

try {
    $repairSid = Get-RepairUserSid
    if ($repairSid -ne $OriginalSid) {
        throw 'This repair must be elevated using the same Windows account. Do not enter credentials for another administrator account.'
    }
    # Use the canonical SID for the case-sensitive kernel mutex name.
    $OriginalSid = $repairSid
    $mutex = New-Object Threading.Mutex($false, "Global\OpenAI.Codex.RuntimeRepair.$OriginalSid")
    try { $mutexHeld = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $mutexHeld = $true }
    if (-not $mutexHeld) { throw 'Another Codex runtime repair instance is already running for this Windows account.' }

    $packages = @(Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop)
    if ($packages.Count -ne 1) { throw 'Exactly one current OpenAI.Codex package is required.' }
    $pkg = $packages[0]
    # Fail closed on uninspected versions instead of assuming future content-ID algorithms.
    if ([string]$pkg.Version -ne '26.911.7940.0') { throw "Runtime identity algorithm has not been verified for Codex $($pkg.Version). No runtime was modified." }
    $installRoot = [IO.Path]::GetFullPath($pkg.InstallLocation).TrimEnd('\')
    $src = Join-Path $installRoot 'app\resources\cua_node'
    $rt = [IO.Path]::GetFullPath((Get-RuntimeRoot)).TrimEnd('\')
    $localAppData = [IO.Path]::GetFullPath([IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($rt))))).TrimEnd('\')
    Assert-OrdinaryDirectory $src
    Initialize-DosDeviceApi
    $S = Mount-Subst $src
    $sourceIdentity = Get-RuntimeIdentity "$S`:\"
    $srcMap = Get-Map "$S`:\"
    if ($srcMap.Count -eq 0) { throw 'Official source runtime is empty.' }
    $manifest = Get-Content -LiteralPath (Join-Path $src 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.platform -ne 'windows' -or $manifest.node_path -ne 'bin/node.exe' -or
        $manifest.node_repl_path -ne 'bin/node_repl.exe' -or $manifest.node_modules -ne 'bin/node_modules') {
        throw 'Unrecognized official runtime manifest; no runtime was modified.'
    }
    $hash = $sourceIdentity.Hash
    $manual = Join-Path $rt ".manual-$hash"
    $final = Join-Path $rt $hash
    Assert-RuntimePath $manual
    Assert-RuntimePath $final
    Assert-OrdinaryDirectory $rt
    $directories = @(Get-ChildItem -LiteralPath $rt -Directory -Force -ErrorAction Stop)
    $evidence = @($directories | Where-Object { $_.Name -match "^\.staging-$hash-.+$|^\.manual-$hash(?:\.(?:old|work)-.+)?$" })
    if (-not $evidence.Count) { throw "No staging/manual for the current source hash $hash. Other hashes were left unchanged." }
    Write-Host 'Version:' $pkg.Version
    Write-Host 'Hash:' $hash

    # Only initial shutdown is automatic. Later restart checks abort without killing.
    $deadline = (Get-Date).AddSeconds(5)
    do {
        $running = @(Get-OwnedCodexProcesses)
        if (-not $running.Count) { break }
        foreach ($process in $running) { Stop-OwnedCodexProcess $process }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    Assert-CodexStopped
    Assert-SourceReady

    # ---------- Verify the existing final before deciding whether replacement is needed ----------
    $finalComplete = $false
    if (Test-Path -LiteralPath $final) {
        Assert-RuntimePath $final
        Assert-OrdinaryDirectory $final
        $T = Mount-Subst $final
        $validation = Test-Runtime "$T`:\"
        Dismount-Subst $T
        $T = $null
        $finalComplete = $validation.Complete
        if (-not $finalComplete) {
            Write-Host 'Existing final runtime differs; it will be backed up only after a replacement is verified.' -ForegroundColor Yellow
            $validation.Differences | Select-Object -First 10 | Write-Host
        }
    }

    if (-not $finalComplete) {
        # ---------- Reuse a complete manual/work/old copy; retain every invalid copy ----------
        $work = $null
        $manualCandidates = @($directories | Where-Object { $_.Name -match "^\.manual-$hash(?:\.(?:old|work)-.+)?$" } | Sort-Object @{Expression = { $_.Name -ne ".manual-$hash" }}, LastWriteTime)
        foreach ($candidate in $manualCandidates) {
            Assert-RuntimePath $candidate.FullName
            Assert-OrdinaryDirectory $candidate.FullName
            $T = Mount-Subst $candidate.FullName
            $validation = Test-Runtime "$T`:\"
            Dismount-Subst $T
            $T = $null
            if ($validation.Complete) { $work = $candidate.FullName; break }
        }
        if (-not $work) {
            if (Test-Path -LiteralPath $manual) {
                Assert-SourceReady
                Assert-CodexStopped
                $oldName = ".manual-$hash.old-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([Guid]::NewGuid().ToString('N'))"
                Assert-RuntimePath (Join-Path $rt $oldName)
                Rename-Item -LiteralPath $manual -NewName $oldName -ErrorAction Stop
            }
            $work = Join-Path $rt ".manual-$hash.work-$([Guid]::NewGuid().ToString('N'))"
            Assert-RuntimePath $work
            $null = [IO.Directory]::CreateDirectory($work)
            $T = Mount-Subst $work
            Assert-OwnedMap $S
            Assert-OwnedMap $T
            Write-Host 'Copying...'
            Invoke-RuntimeCopy $src $work
            if ($xcopyExit -ne 0) { throw "ROBOCOPY failed, exit code: $xcopyExit. Recovery copies were retained." }
            Assert-OwnedMap $S
            Assert-OwnedMap $T
            $validation = Test-Runtime "$T`:\"
            if (-not $validation.Complete) { throw "Copied runtime failed verification: $($validation.Differences -join '; ')" }
            Dismount-Subst $T
            $T = $null
        }

        # ---------- Commit only a verified copy; keep final and manual backups until then ----------
        Assert-SourceReady
        Assert-CodexStopped
        Assert-RuntimePath $work
        if (Test-Path -LiteralPath $final) {
            Assert-RuntimePath $final
            $backupName = "$hash.bad-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([Guid]::NewGuid().ToString('N'))"
            $finalBackup = Join-Path $rt $backupName
            Assert-RuntimePath $finalBackup
            Rename-Item -LiteralPath $final -NewName $backupName -ErrorAction Stop
        }
        Assert-SourceReady
        Assert-CodexStopped
        Rename-Item -LiteralPath $work -NewName $hash -ErrorAction Stop
        $committed = $true
    }

    # The fast RUNTIME_OK branch and the rebuild branch share final key/content/tree validation.
    Assert-SourceReady
    Assert-CodexStopped
    Assert-RuntimePath $final
    $T = Mount-Subst $final
    $validation = Test-Runtime "$T`:\"
    if (-not $validation.Complete) { throw 'Final runtime failed verification. Backups and staging were retained.' }
    Dismount-Subst $T
    $T = $null

    # Delete only temporary directories of this source hash, after the final is verified.
    $cleanupDirectories = @(Get-ChildItem -LiteralPath $rt -Directory -Force | Where-Object { $_.Name -match "^\.staging-$hash-.+$|^\.manual-$hash(?:\.(?:old|work)-.+)?$" })
    foreach ($directory in $cleanupDirectories) { Remove-RuntimeDirectory $directory.FullName }
    $successMessage = if ($finalComplete) { 'RUNTIME_OK' } else { 'Runtime repair succeeded.' }
}
catch {
    $failure = $_.Exception.Message
    # If commit failed after moving the old final, restore its original name when safe.
    if ($finalBackup -and -not $committed) {
        try {
            Assert-CodexStopped
            Assert-SourceReady
            Assert-RuntimePath $finalBackup
            Assert-RuntimePath $final
            if (-not (Test-Path -LiteralPath $final) -and (Test-Path -LiteralPath $finalBackup -PathType Container)) {
                Rename-Item -LiteralPath $finalBackup -NewName $hash -ErrorAction Stop
            }
        }
        catch { Write-Host "Original final retained at $finalBackup. Restore was not performed: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
}
finally {
    $cleanupErrors = @(Remove-Maps)
    foreach ($cleanupError in $cleanupErrors) { Write-Host "Cleanup failed: $cleanupError" -ForegroundColor Red }
    if ($cleanupErrors.Count -and -not $failure) { $failure = 'Owned SUBST cleanup failed; success was not reported.' }
    if ($mutexHeld) {
        try { $mutex.ReleaseMutex() }
        catch { if (-not $failure) { $failure = "Mutex release failed: $($_.Exception.Message)" } }
    }
    if ($null -ne $mutex) {
        try { $mutex.Dispose() }
        catch { if (-not $failure) { $failure = "Mutex disposal failed: $($_.Exception.Message)" } }
    }
}

if ($failure) {
    Write-Host 'FAILED' -ForegroundColor Red
    Write-Host $failure
    exit 1
}
if (-not $successMessage) { throw 'Repair interrupted before completion.' }
Write-Host $successMessage -ForegroundColor Green
exit 0
