# CrabDeploy - shared deploy helpers for a self-hosted Windows GitHub Actions runner.
# Phase 1 scope: Angular -> IIS static site.
# Phase 2 adds .NET WebApi -> IIS bin swap and .NET 8 console app -> Task Scheduler swap.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Backup-AppFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SiteFolder,
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$Name,
        [string[]]$ExcludeFiles = @(),
        [string[]]$ExcludeDirs  = @()
    )
    if (-not (Test-Path -LiteralPath $SiteFolder)) {
        Write-Host "Backup-AppFolder: '$SiteFolder' does not exist yet - first deploy, nothing to back up."
        return $null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dest  = Join-Path (Join-Path $BackupRoot $Name) $stamp
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $log = @()
    if ($ExcludeFiles) { $log += "files: $($ExcludeFiles -join ', ')" }
    if ($ExcludeDirs)  { $log += "dirs: $($ExcludeDirs -join ', ')" }
    $excludeMsg = if ($log) { " (excluding $($log -join '; '))" } else { '' }
    Write-Host "Backup: '$SiteFolder' -> '$dest'$excludeMsg"
    $rc = @($SiteFolder, $dest, '/MIR','/NFL','/NDL','/NJH','/NJS','/NP','/R:2','/W:2')
    foreach ($f in $ExcludeFiles) { $rc += '/XF'; $rc += $f }
    foreach ($d in $ExcludeDirs)  { $rc += '/XD'; $rc += $d }
    robocopy @rc | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy backup failed (exit $LASTEXITCODE)" }
    $global:LASTEXITCODE = 0
    return $dest
}

function Rotate-Backups {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$Name,
        [int]$Keep = 3
    )
    $base = Join-Path $BackupRoot $Name
    if (-not (Test-Path -LiteralPath $base)) { return }
    $dirs = @(Get-ChildItem -LiteralPath $base -Directory | Sort-Object Name -Descending)
    if ($dirs.Count -le $Keep) { return }
    $dirs | Select-Object -Skip $Keep | ForEach-Object {
        Write-Host "Prune old backup: '$($_.FullName)'"
        Remove-Item -LiteralPath $_.FullName -Recurse -Force
    }
}

function Test-Smoke {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$ExpectStatus = 200,
        [int]$Retries = 5,
        [int]$DelaySec = 3,
        [string]$HostHeader,
        [string]$BodyMatch
    )
    $headers = @{}
    if ($HostHeader) { $headers['Host'] = $HostHeader }
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -TimeoutSec 30
            if ($resp.StatusCode -ne $ExpectStatus) {
                Write-Host "Smoke attempt $i/$Retries -> got $($resp.StatusCode), want $ExpectStatus"
                Start-Sleep -Seconds $DelaySec
                continue
            }
            if ($BodyMatch -and ($resp.Content -notmatch $BodyMatch)) {
                $preview = if ($resp.Content) { ($resp.Content.Substring(0, [Math]::Min(200, $resp.Content.Length))) } else { '(empty body)' }
                Write-Host "Smoke attempt $i/$Retries -> status OK but body does not match '$BodyMatch'. First 200 chars: $preview"
                Start-Sleep -Seconds $DelaySec
                continue
            }
            $detail = if ($BodyMatch) { " + body match '$BodyMatch'" } else { '' }
            Write-Host "Smoke OK: $Url -> $($resp.StatusCode)$detail"
            return
        } catch {
            Write-Host "Smoke attempt $i/$Retries failed: $($_.Exception.Message)"
            Start-Sleep -Seconds $DelaySec
        }
    }
    throw "Smoke test failed after $Retries attempts: $Url"
}

function Deploy-Angular-IIS {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArtifactDir,
        [Parameter(Mandatory)][string]$SiteFolder,
        [Parameter(Mandatory)][string]$AppPool,
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$Name,
        [int]$Retention = 3,
        [string]$SmokeUrl = 'http://localhost/',
        [string]$SmokeHostHeader,
        [string[]]$PreserveFiles = @('web.config'),
        [string[]]$PreserveDirs  = @()
    )
    if (-not (Test-Path -LiteralPath (Join-Path $ArtifactDir 'index.html'))) {
        throw "Artifact '$ArtifactDir' has no index.html at its root - wrong path?"
    }
    Import-Module WebAdministration -ErrorAction Stop
    $backup = Backup-AppFolder -SiteFolder $SiteFolder -BackupRoot $BackupRoot -Name $Name
    Rotate-Backups -BackupRoot $BackupRoot -Name $Name -Keep $Retention
    if ((Get-WebAppPoolState -Name $AppPool).Value -ne 'Stopped') {
        Write-Host "Stopping app pool '$AppPool'"
        Stop-WebAppPool -Name $AppPool
        Start-Sleep -Seconds 2
    }
    try {
        New-Item -ItemType Directory -Path $SiteFolder -Force | Out-Null
        $rc = @($ArtifactDir, $SiteFolder, '/MIR','/NFL','/NDL','/NJH','/NJS','/NP','/R:2','/W:2')
        foreach ($f in $PreserveFiles) { $rc += '/XF'; $rc += $f }
        foreach ($d in $PreserveDirs)  { $rc += '/XD'; $rc += $d }
        $log = @()
        if ($PreserveFiles) { $log += "files: $($PreserveFiles -join ', ')" }
        if ($PreserveDirs)  { $log += "dirs: $($PreserveDirs -join ', ')" }
        Write-Host "Deploy: '$ArtifactDir' -> '$SiteFolder' (preserving $($log -join '; '))"
        robocopy @rc | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy deploy failed (exit $LASTEXITCODE)" }
        $global:LASTEXITCODE = 0
    }
    catch {
        Write-Host "Deploy failed: $($_.Exception.Message)"
        if ($backup) {
            Write-Host "Rolling back from '$backup'"
            robocopy $backup $SiteFolder /MIR /NFL /NDL /NJH /NJS /NP /R:2 /W:2 | Out-Null
            $global:LASTEXITCODE = 0
        }
        Start-WebAppPool -Name $AppPool -ErrorAction SilentlyContinue
        throw
    }
    Write-Host "Starting app pool '$AppPool'"
    Start-WebAppPool -Name $AppPool
    Start-Sleep -Seconds 2
    Test-Smoke -Url $SmokeUrl -HostHeader $SmokeHostHeader
    Write-Host "Deploy-Angular-IIS complete for '$Name'."
}

function Deploy-DotNetWebApp-IIS {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArtifactDir,
        [Parameter(Mandatory)][string]$SiteFolder,
        [Parameter(Mandatory)][string]$AppPool,
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$Name,
        [int]$Retention = 3,
        [string]$SmokeUrl = 'http://localhost/',
        [string]$SmokeHostHeader,
        [string]$SmokeBodyMatch,
        [hashtable[]]$ExtraSmokes = @()
    )
    $dlls = @(Get-ChildItem -Path $ArtifactDir -Filter *.dll -File -ErrorAction SilentlyContinue)
    if ($dlls.Count -eq 0) {
        throw "Artifact '$ArtifactDir' contains no .dll files - wrong path or empty build?"
    }
    Write-Host "Artifact has $($dlls.Count) .dll files."
    Import-Module WebAdministration -ErrorAction Stop
    $siteBin    = Join-Path $SiteFolder 'bin'
    $backupName = "$Name-bin"
    $backup = Backup-AppFolder -SiteFolder $siteBin -BackupRoot $BackupRoot -Name $backupName
    Rotate-Backups -BackupRoot $BackupRoot -Name $backupName -Keep $Retention
    if ((Get-WebAppPoolState -Name $AppPool).Value -ne 'Stopped') {
        Write-Host "Stopping app pool '$AppPool'"
        Stop-WebAppPool -Name $AppPool
        Start-Sleep -Seconds 2
    }
    try {
        New-Item -ItemType Directory -Path $siteBin -Force | Out-Null
        Write-Host "Copy: '$ArtifactDir' -> '$siteBin' (additive, recursive, no purge)"
        robocopy $ArtifactDir $siteBin /E /NFL /NDL /NJH /NJS /NP /R:2 /W:2 | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy deploy failed (exit $LASTEXITCODE)" }
        $global:LASTEXITCODE = 0
        Write-Host "Starting app pool '$AppPool'"
        Start-WebAppPool -Name $AppPool
        Start-Sleep -Seconds 2
        if ($SmokeBodyMatch) {
            Test-Smoke -Url $SmokeUrl -HostHeader $SmokeHostHeader -BodyMatch $SmokeBodyMatch
        } else {
            Test-Smoke -Url $SmokeUrl -HostHeader $SmokeHostHeader
        }
        foreach ($s in $ExtraSmokes) {
            $u = $s['Url']
            $bm = if ($s.ContainsKey('BodyMatch')) { $s['BodyMatch'] } else { $null }
            if ($bm) { Test-Smoke -Url $u -HostHeader $SmokeHostHeader -BodyMatch $bm }
            else     { Test-Smoke -Url $u -HostHeader $SmokeHostHeader }
        }
    }
    catch {
        Write-Host "Deploy or smoke check failed: $($_.Exception.Message)"
        if ($backup) {
            Write-Host "Rolling back bin from '$backup' (stop pool, restore, restart pool)."
            try { Stop-WebAppPool -Name $AppPool -ErrorAction Stop; Start-Sleep -Seconds 2 } catch { Write-Host "  (pool stop during rollback: $($_.Exception.Message))" }
            robocopy $backup $siteBin /MIR /NFL /NDL /NJH /NJS /NP /R:2 /W:2 | Out-Null
            $global:LASTEXITCODE = 0
            try { Start-WebAppPool -Name $AppPool -ErrorAction Stop; Start-Sleep -Seconds 2 } catch { Write-Host "  (pool start during rollback: $($_.Exception.Message))" }
        } else {
            Write-Host "No backup available (first deploy?) - cannot roll back automatically."
            Start-WebAppPool -Name $AppPool -ErrorAction SilentlyContinue
        }
        throw
    }
    Write-Host "Deploy-DotNetWebApp-IIS complete for '$Name'."
}

# Helper for Deploy-DotnetConsole-Scheduled: read newly-appended log content
function Get-NewLogContentInternal {
    param(
        [string]$LogDir,
        [string]$BeforeName,
        [long]$BeforeSize
    )
    if (-not (Test-Path -LiteralPath $LogDir)) { return '' }
    $latest = Get-ChildItem -LiteralPath $LogDir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { return '' }
    $startOffset = if ($latest.Name -eq $BeforeName) { $BeforeSize } else { 0 }
    if ($latest.Length -le $startOffset) { return '' }
    $content = ''
    try {
        $fs = [System.IO.File]::Open($latest.FullName, 'Open', 'Read', 'ReadWrite')
        try {
            $fs.Seek($startOffset, 'Begin') | Out-Null
            $sr = New-Object System.IO.StreamReader($fs)
            $content = $sr.ReadToEnd()
            $sr.Close()
        }
        finally { $fs.Close() }
    } catch { Write-Host "  (log read warning: $($_.Exception.Message))" }
    return $content
}

function Deploy-DotnetConsole-Scheduled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArtifactDir,
        [Parameter(Mandatory)][string]$SiteFolder,
        [Parameter(Mandatory)][string[]]$TaskNames,
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$Name,
        [int]$Retention = 3,
        [string[]]$PreserveFiles = @('appsettings.json', '*.log'),
        [string[]]$PreserveDirs  = @('logs'),
        [int]$WaitForRunningSec  = 60,
        [int]$SmokeWaitSec       = 90,
        [string]$LogDir,
        [string[]]$LogMarkers    = @()
    )
    $exes = @(Get-ChildItem -Path $ArtifactDir -Filter *.exe -File -ErrorAction SilentlyContinue)
    if ($exes.Count -eq 0) { throw "Artifact '$ArtifactDir' contains no .exe files - wrong path or empty build?" }
    $dlls = @(Get-ChildItem -Path $ArtifactDir -Filter *.dll -File -ErrorAction SilentlyContinue)
    Write-Host "Artifact has $($exes.Count) .exe + $($dlls.Count) .dll files."

    Import-Module ScheduledTasks -ErrorAction Stop

    $backup = Backup-AppFolder -SiteFolder $SiteFolder -BackupRoot $BackupRoot -Name $Name -ExcludeFiles $PreserveFiles -ExcludeDirs $PreserveDirs
    Rotate-Backups -BackupRoot $BackupRoot -Name $Name -Keep $Retention

    foreach ($task in $TaskNames) {
        Write-Host "Disabling task '$task'"
        Disable-ScheduledTask -TaskName $task -ErrorAction Stop | Out-Null
    }

    Write-Host "Waiting up to ${WaitForRunningSec}s for in-flight task instances to finish..."
    $deadline = (Get-Date).AddSeconds($WaitForRunningSec)
    while ((Get-Date) -lt $deadline) {
        $running = @($TaskNames | Where-Object { (Get-ScheduledTask -TaskName $_).State -eq 'Running' })
        if ($running.Count -eq 0) { break }
        Start-Sleep -Seconds 2
    }
    $stillRunning = @($TaskNames | Where-Object { (Get-ScheduledTask -TaskName $_).State -eq 'Running' })
    if ($stillRunning.Count -gt 0) {
        Write-Host "Force-stopping still-running tasks: $($stillRunning -join ', ')"
        foreach ($t in $stillRunning) { Stop-ScheduledTask -TaskName $t }
        Start-Sleep -Seconds 3
    }

    try {
        New-Item -ItemType Directory -Path $SiteFolder -Force | Out-Null
        $rc = @($ArtifactDir, $SiteFolder, '/E','/NFL','/NDL','/NJH','/NJS','/NP','/R:2','/W:2')
        foreach ($f in $PreserveFiles) { $rc += '/XF'; $rc += $f }
        foreach ($d in $PreserveDirs)  { $rc += '/XD'; $rc += $d }
        $log = @()
        if ($PreserveFiles) { $log += "files: $($PreserveFiles -join ', ')" }
        if ($PreserveDirs)  { $log += "dirs: $($PreserveDirs -join ', ')" }
        Write-Host "Copy: '$ArtifactDir' -> '$SiteFolder' (additive; preserving $($log -join '; '))"
        robocopy @rc | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy deploy failed (exit $LASTEXITCODE)" }
        $global:LASTEXITCODE = 0

        foreach ($task in $TaskNames) {
            Write-Host "Re-enabling task '$task'"
            Enable-ScheduledTask -TaskName $task | Out-Null
        }

        # Capture log state right before smoke trigger
        $effectiveLogDir = if ($LogDir) { $LogDir } else { Join-Path $SiteFolder 'logs' }
        $logBeforeName = $null
        $logBeforeSize = [long]0
        if ($LogMarkers.Count -gt 0 -and (Test-Path -LiteralPath $effectiveLogDir)) {
            $latestLog = Get-ChildItem -LiteralPath $effectiveLogDir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latestLog) {
                $logBeforeName = $latestLog.Name
                $logBeforeSize = $latestLog.Length
                Write-Host "Log baseline: $($latestLog.Name) at $logBeforeSize bytes"
            }
        }

        # Trigger each task
        $smokeStart = Get-Date
        foreach ($task in $TaskNames) {
            Write-Host "Smoke: starting task '$task'"
            Start-ScheduledTask -TaskName $task
            Start-Sleep -Seconds 1
        }

        Write-Host "Waiting up to ${SmokeWaitSec}s for smoke runs to complete + log markers to appear..."
        $smokeDeadline = (Get-Date).AddSeconds($SmokeWaitSec)
        $results = @{}
        $foundMarkers = @{}
        while ((Get-Date) -lt $smokeDeadline) {
            $allDone = $true
            # Task exit-code check
            foreach ($task in $TaskNames) {
                if ($results.ContainsKey($task)) { continue }
                $state = (Get-ScheduledTask -TaskName $task).State
                $info = Get-ScheduledTaskInfo -TaskName $task
                if ($state -eq 'Ready' -and $info.LastRunTime -ge $smokeStart) {
                    $results[$task] = $info.LastTaskResult
                    Write-Host "Smoke: task '$task' completed with LastTaskResult=$($info.LastTaskResult)"
                } else {
                    $allDone = $false
                }
            }
            # Log marker check
            if ($LogMarkers.Count -gt 0) {
                $newContent = Get-NewLogContentInternal -LogDir $effectiveLogDir -BeforeName $logBeforeName -BeforeSize $logBeforeSize
                foreach ($m in $LogMarkers) {
                    if (-not $foundMarkers.ContainsKey($m) -and $newContent -match [regex]::Escape($m)) {
                        $foundMarkers[$m] = $true
                        Write-Host "Smoke: log marker found: '$m'"
                    }
                }
                if ($foundMarkers.Count -lt $LogMarkers.Count) { $allDone = $false }
            }
            if ($allDone) { break }
            Start-Sleep -Seconds 3
        }

        # Final verification
        $failures = @()
        foreach ($task in $TaskNames) {
            if (-not $results.ContainsKey($task)) {
                $failures += "$task (timeout after ${SmokeWaitSec}s - never returned to Ready state)"
            } elseif ($results[$task] -ne 0) {
                $failures += "$task (LastTaskResult=$($results[$task]))"
            }
        }
        if ($LogMarkers.Count -gt 0) {
            $missing = @()
            foreach ($m in $LogMarkers) {
                if (-not $foundMarkers.ContainsKey($m)) { $missing += $m }
            }
            if ($missing.Count -gt 0) {
                $failures += "log markers missing from new log content: $($missing -join ' | ')"
            } else {
                Write-Host "Smoke: all $($LogMarkers.Count) log markers verified in newly-appended log content."
            }
        }
        if ($failures.Count -gt 0) {
            throw "Smoke verification failed: $($failures -join '; ')"
        }
        Write-Host "All smoke checks passed."
    }
    catch {
        Write-Host "Deploy or smoke failed: $($_.Exception.Message)"
        if ($backup) {
            Write-Host "Rolling back from '$backup' (disable tasks, restore binaries, re-enable)."
            foreach ($task in $TaskNames) {
                try { Disable-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue | Out-Null } catch {}
            }
            Start-Sleep -Seconds 3
            $rbDeadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $rbDeadline) {
                $running = @($TaskNames | Where-Object { (Get-ScheduledTask -TaskName $_).State -eq 'Running' })
                if ($running.Count -eq 0) { break }
                Start-Sleep -Seconds 2
            }
            $rc = @($backup, $SiteFolder, '/E','/NFL','/NDL','/NJH','/NJS','/NP','/R:2','/W:2')
            foreach ($f in $PreserveFiles) { $rc += '/XF'; $rc += $f }
            foreach ($d in $PreserveDirs)  { $rc += '/XD'; $rc += $d }
            Write-Host "Restore: '$backup' -> '$SiteFolder' (additive; preserving same files + dirs)"
            robocopy @rc | Out-Null
            $global:LASTEXITCODE = 0
            foreach ($task in $TaskNames) {
                try { Enable-ScheduledTask -TaskName $task | Out-Null } catch {}
            }
        } else {
            Write-Host "No backup available (first deploy?) - cannot roll back automatically. Re-enabling tasks."
            foreach ($task in $TaskNames) {
                try { Enable-ScheduledTask -TaskName $task | Out-Null } catch {}
            }
        }
        throw
    }

    Write-Host "Deploy-DotnetConsole-Scheduled complete for '$Name'."
}

Export-ModuleMember -Function Backup-AppFolder, Rotate-Backups, Test-Smoke, Deploy-Angular-IIS, Deploy-DotNetWebApp-IIS, Deploy-DotnetConsole-Scheduled