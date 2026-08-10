# CrabDeploy - shared deploy helpers for a self-hosted Windows GitHub Actions runner.
# Phase 1: Angular -> IIS. Phase 2: .NET WebApi -> IIS bin swap. Phase 3: .NET 8 / .NET Fx
# console app -> Task Scheduler (or direct-exec smoke when the task runs too long for canary).
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

function Get-AppPoolStateSafe {
    <#
    .SYNOPSIS
    Current app-pool state, or 'Unknown' when IIS will not answer.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppPool)
    try { return (Get-WebAppPoolState -Name $AppPool).Value } catch { return 'Unknown' }
}

function Stop-AppPoolAndWait {
    <#
    .SYNOPSIS
    Stop an app pool and block until it is really 'Stopped'.

    .DESCRIPTION
    IIS reports a pool as 'Stopping' while its worker drains. Any control message
    sent during that window - Start-WebAppPool, or a second Stop-WebAppPool - throws
    "The service cannot accept control messages at this time" (HRESULT 0x80070425).
    Because Stop -> copy -> Start ran back-to-back, a slow-shutdown worker failed the
    deploy AND then failed the rollback that followed it, leaving the pool wedged.

    So: ask it to stop, wait for the state to actually settle, and only if the worker
    refuses to die inside -GracefulSec, kill the w3wp belonging to THIS pool (matched
    on the -ap argument, so a sibling pool's worker is never touched).

    Throws if the pool will not reach 'Stopped' - callers must not swap files under a
    live worker.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppPool,
        [int]$GracefulSec = 45,
        [int]$PostKillSec = 20
    )
    Import-Module WebAdministration -ErrorAction Stop
    $state = Get-AppPoolStateSafe -AppPool $AppPool
    if ($state -eq 'Stopped') { Write-Host "App pool '$AppPool' already Stopped."; return }
    Write-Host "Stopping app pool '$AppPool' (state=$state, graceful window ${GracefulSec}s)"
    # A pool already in 'Stopping' rejects this call - not a failure, the wait decides.
    try { Stop-WebAppPool -Name $AppPool -ErrorAction Stop }
    catch { Write-Host "  (Stop-WebAppPool: $($_.Exception.Message))" }
    $deadline = (Get-Date).AddSeconds($GracefulSec)
    while ((Get-AppPoolStateSafe -AppPool $AppPool) -ne 'Stopped' -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
    }
    if ((Get-AppPoolStateSafe -AppPool $AppPool) -ne 'Stopped') {
        Write-Host "Pool still '$(Get-AppPoolStateSafe -AppPool $AppPool)' after ${GracefulSec}s - force-killing its worker(s)."
        $procIds = @()
        try {
            $procIds += @(Get-ChildItem "IIS:\AppPools\$AppPool\WorkerProcesses" -ErrorAction SilentlyContinue |
                ForEach-Object { $_.processId })
        } catch { Write-Host "  (WorkerProcesses lookup: $($_.Exception.Message))" }
        try {
            $procIds += @(Get-CimInstance Win32_Process -Filter "Name='w3wp.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape("-ap `"$AppPool`"") } |
                ForEach-Object { $_.ProcessId })
        } catch { Write-Host "  (Win32_Process lookup: $($_.Exception.Message))" }
        $procIds = @($procIds | Where-Object { $_ } | Sort-Object -Unique)
        if ($procIds.Count -eq 0) { Write-Host "  (no w3wp worker found for '$AppPool')" }
        foreach ($procId in $procIds) {
            try { Stop-Process -Id $procId -Force -ErrorAction Stop; Write-Host "  killed w3wp PID $procId" }
            catch { Write-Host "  kill PID ${procId} failed: $($_.Exception.Message)" }
        }
        $deadline2 = (Get-Date).AddSeconds($PostKillSec)
        while ((Get-AppPoolStateSafe -AppPool $AppPool) -ne 'Stopped' -and (Get-Date) -lt $deadline2) {
            Start-Sleep -Seconds 2
        }
    }
    $final = Get-AppPoolStateSafe -AppPool $AppPool
    if ($final -ne 'Stopped') {
        throw "App pool '$AppPool' would not stop (state=$final) - refusing to swap files under a live worker."
    }
    Write-Host "App pool '$AppPool' is Stopped."
}

function Start-AppPoolAndWait {
    <#
    .SYNOPSIS
    Start an app pool and block until it reports 'Started'.

    .DESCRIPTION
    The mirror of Stop-AppPoolAndWait: a Start issued while the pool is still
    transitioning is silently dropped (or throws 0x80070425), so poll the state and
    re-issue until it takes. Throws if the pool never reaches 'Started', which lets
    the caller's catch block roll back rather than smoke-test a dead site.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppPool,
        [int]$TimeoutSec = 30
    )
    Import-Module WebAdministration -ErrorAction Stop
    Write-Host "Starting app pool '$AppPool'"
    try { Start-WebAppPool -Name $AppPool -ErrorAction Stop }
    catch { Write-Host "  (Start-WebAppPool: $($_.Exception.Message))" }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-AppPoolStateSafe -AppPool $AppPool) -ne 'Started' -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        try { Start-WebAppPool -Name $AppPool -ErrorAction Stop } catch { }
    }
    $final = Get-AppPoolStateSafe -AppPool $AppPool
    if ($final -ne 'Started') { throw "App pool '$AppPool' did not reach Started (state=$final)." }
    Write-Host "App pool '$AppPool' is Started."
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
    Stop-AppPoolAndWait -AppPool $AppPool
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
        try { Start-AppPoolAndWait -AppPool $AppPool } catch { Write-Host "  (best-effort pool start: $($_.Exception.Message))" }
        throw
    }
    Start-AppPoolAndWait -AppPool $AppPool
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
    Stop-AppPoolAndWait -AppPool $AppPool
    try {
        New-Item -ItemType Directory -Path $siteBin -Force | Out-Null
        Write-Host "Copy: '$ArtifactDir' -> '$siteBin' (additive, recursive, no purge)"
        robocopy $ArtifactDir $siteBin /E /NFL /NDL /NJH /NJS /NP /R:2 /W:2 | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy deploy failed (exit $LASTEXITCODE)" }
        $global:LASTEXITCODE = 0
        Start-AppPoolAndWait -AppPool $AppPool
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
            try { Stop-AppPoolAndWait -AppPool $AppPool } catch { Write-Host "  (pool stop during rollback: $($_.Exception.Message))" }
            robocopy $backup $siteBin /MIR /NFL /NDL /NJH /NJS /NP /R:2 /W:2 | Out-Null
            $global:LASTEXITCODE = 0
            try { Start-AppPoolAndWait -AppPool $AppPool } catch { Write-Host "  (pool start during rollback: $($_.Exception.Message))" }
        } else {
            Write-Host "No backup available (first deploy?) - cannot roll back automatically."
            try { Start-AppPoolAndWait -AppPool $AppPool } catch { Write-Host "  (best-effort pool start: $($_.Exception.Message))" }
        }
        throw
    }
    Write-Host "Deploy-DotNetWebApp-IIS complete for '$Name'."
}

# Internal helper - reads newly-appended log content since a captured baseline
function Get-NewLogContentInternal {
    param(
        [string]$LogDir,
        [string]$BeforeName,
        [long]$BeforeSize,
        [string]$LogFilePattern = '*'
    )
    if (-not (Test-Path -LiteralPath $LogDir)) { return '' }
    $latest = Get-ChildItem -LiteralPath $LogDir -File -Filter $LogFilePattern -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
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
        [string]$LogFilePattern  = '*',
        [string[]]$LogMarkers    = @(),
        # When provided, after re-enabling tasks, smoke runs the deployed exe DIRECTLY with these args
        # instead of triggering scheduled tasks (which may be too long-running, e.g. monthly UPS refresh).
        # The exe used is the first .exe found in $SiteFolder (matched by name to the artifact's primary exe).
        [string[]]$SmokeDirectArgs = @()
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

        # Capture log state before smoke
        $effectiveLogDir = if ($LogDir) { $LogDir } else { Join-Path $SiteFolder 'logs' }
        $logBeforeName = $null
        $logBeforeSize = [long]0
        if ($LogMarkers.Count -gt 0 -and (Test-Path -LiteralPath $effectiveLogDir)) {
            $latestLog = Get-ChildItem -LiteralPath $effectiveLogDir -File -Filter $LogFilePattern -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latestLog) {
                $logBeforeName = $latestLog.Name
                $logBeforeSize = $latestLog.Length
                Write-Host "Log baseline: $($latestLog.Name) at $logBeforeSize bytes"
            }
        }
        $smokeStart = Get-Date

        if ($SmokeDirectArgs.Count -gt 0) {
            # ----- DIRECT-EXEC smoke (for tasks whose normal run is too long, e.g. monthly --ups-api 76min) -----
            $mainExeName = $exes[0].Name
            $mainExePath = Join-Path $SiteFolder $mainExeName
            if (-not (Test-Path -LiteralPath $mainExePath)) {
                throw "Direct smoke: expected exe '$mainExeName' not found in '$SiteFolder' after deploy"
            }
            # Run with CWD = SiteFolder so log4net (and any other relative-path resource
            # the exe uses) resolves the same way the scheduled task does in prod. Without
            # this, an exe configured to log to "FedExZipImporter.log" writes to the
            # runner's working dir instead of the prod log file, and log-marker smoke fails.
            Write-Host "Smoke: running '$mainExePath' $($SmokeDirectArgs -join ' ') (CWD=$SiteFolder)"
            Push-Location -LiteralPath $SiteFolder
            try {
                & $mainExePath @SmokeDirectArgs
                $directExit = $LASTEXITCODE
            } finally {
                Pop-Location
            }
            $global:LASTEXITCODE = 0
            if ($directExit -ne 0) {
                throw "Direct smoke failed: '$mainExeName $($SmokeDirectArgs -join ' ')' returned exit $directExit"
            }
            Write-Host "Direct smoke OK: exit=0"

            # Verify log markers (if requested) - read appended content
            if ($LogMarkers.Count -gt 0) {
                Start-Sleep -Seconds 2  # let log4net flush
                $newContent = Get-NewLogContentInternal -LogDir $effectiveLogDir -BeforeName $logBeforeName -BeforeSize $logBeforeSize -LogFilePattern $LogFilePattern
                $missing = @()
                foreach ($m in $LogMarkers) {
                    if ($newContent -notmatch [regex]::Escape($m)) { $missing += $m }
                }
                if ($missing.Count -gt 0) {
                    throw "Log markers missing from new log content: $($missing -join ' | ')"
                }
                Write-Host "Smoke: all $($LogMarkers.Count) log markers verified in newly-appended log content."
            }
        }
        else {
            # ----- TASK-TRIGGERED smoke (original behavior) -----
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
                # Refresh markers FIRST so run-evidence is current for the task check below.
                if ($LogMarkers.Count -gt 0) {
                    $newContent = Get-NewLogContentInternal -LogDir $effectiveLogDir -BeforeName $logBeforeName -BeforeSize $logBeforeSize -LogFilePattern $LogFilePattern
                    foreach ($m in $LogMarkers) {
                        if (-not $foundMarkers.ContainsKey($m) -and $newContent -match [regex]::Escape($m)) {
                            $foundMarkers[$m] = $true
                            Write-Host "Smoke: log marker found: '$m'"
                        }
                    }
                }
                # Every configured end-marker appearing in NEWLY-appended log content proves each
                # task ran to the end of Main during this window - a more reliable completion signal
                # than LastRunTime, which the task's own schedule can suppress: a scheduled instance
                # already running makes our manual Start-ScheduledTask a no-op (MultipleInstances=
                # IgnoreNew), so LastRunTime never advances past smokeStart even though the task ran
                # and exited cleanly. Accept markers as run-evidence; fall back to LastRunTime when
                # a caller configured no markers.
                $markersProveRun = ($LogMarkers.Count -gt 0 -and $foundMarkers.Count -ge $LogMarkers.Count)

                $allDone = $true
                foreach ($task in $TaskNames) {
                    if ($results.ContainsKey($task)) { continue }
                    $state = (Get-ScheduledTask -TaskName $task).State
                    $info = Get-ScheduledTaskInfo -TaskName $task
                    $ranThisWindow = ($info.LastRunTime -ge $smokeStart)
                    if ($state -eq 'Ready' -and ($ranThisWindow -or $markersProveRun)) {
                        $results[$task] = $info.LastTaskResult
                        Write-Host "Smoke: task '$task' completed with LastTaskResult=$($info.LastTaskResult)"
                    } else {
                        $allDone = $false
                    }
                }
                if ($LogMarkers.Count -gt 0 -and $foundMarkers.Count -lt $LogMarkers.Count) { $allDone = $false }
                if ($allDone) { break }
                Start-Sleep -Seconds 3
            }

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


function Deploy-AspNetCore-IIS {
    <#
    .SYNOPSIS
    Deploy an SDK-style ASP.NET Core app (net6.0+) to an IIS site.

    .DESCRIPTION
    Unlike Deploy-DotNetWebApp-IIS (which swaps <SiteFolder>\bin for .NET Framework
    apps), a `dotnet publish` payload is FLAT and belongs at the site ROOT: the app
    dll sits next to web.config, appsettings*.json and wwwroot\. Copying it into bin\
    would leave the site running its old files and report success.

    Assumes ANCM V2 + the ASP.NET Core hosting bundle are installed. Works for both
    inprocess and outofprocess hostingModel: the app pool is stopped before the copy,
    which releases the file locks w3wp holds under inprocess.

    Copy is additive (/E, no purge) to match the house pattern - it never deletes
    server-side files the artifact does not know about (e.g. logs\).
    #>
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
        [hashtable[]]$ExtraSmokes = @(),
        [string[]]$PreserveDirs = @('logs')
    )

    # Validate the artifact really is a published ASP.NET Core root, not a bin folder
    # or an empty/incorrect path. web.config carries the aspNetCore handler; without it
    # IIS would serve the payload as static files.
    $dlls = @(Get-ChildItem -Path $ArtifactDir -Filter *.dll -File -ErrorAction SilentlyContinue)
    if ($dlls.Count -eq 0) {
        throw "Artifact '$ArtifactDir' contains no .dll files - wrong path or empty build?"
    }
    $webConfig = Join-Path $ArtifactDir 'web.config'
    if (-not (Test-Path -LiteralPath $webConfig)) {
        throw "Artifact '$ArtifactDir' has no web.config - not a published ASP.NET Core app (did you run 'dotnet publish'?)."
    }
    if ((Get-Content -LiteralPath $webConfig -Raw) -notmatch 'AspNetCoreModuleV2') {
        throw "Artifact web.config has no AspNetCoreModuleV2 handler - unexpected publish output."
    }
    Write-Host "Artifact has $($dlls.Count) .dll files + a valid ASP.NET Core web.config."

    Import-Module WebAdministration -ErrorAction Stop

    $backup = Backup-AppFolder -SiteFolder $SiteFolder -BackupRoot $BackupRoot -Name $Name -ExcludeDirs $PreserveDirs
    Rotate-Backups -BackupRoot $BackupRoot -Name $Name -Keep $Retention

    Stop-AppPoolAndWait -AppPool $AppPool

    try {
        New-Item -ItemType Directory -Path $SiteFolder -Force | Out-Null
        Write-Host "Copy: '$ArtifactDir' -> '$SiteFolder' (root, additive, recursive, no purge)"
        robocopy $ArtifactDir $SiteFolder /E /NFL /NDL /NJH /NJS /NP /R:2 /W:2 | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy deploy failed (exit $LASTEXITCODE)" }
        $global:LASTEXITCODE = 0

        Start-AppPoolAndWait -AppPool $AppPool

        if ($SmokeBodyMatch) {
            Test-Smoke -Url $SmokeUrl -HostHeader $SmokeHostHeader -BodyMatch $SmokeBodyMatch
        } else {
            Test-Smoke -Url $SmokeUrl -HostHeader $SmokeHostHeader
        }
        foreach ($s in $ExtraSmokes) {
            $u  = $s['Url']
            $bm = if ($s.ContainsKey('BodyMatch')) { $s['BodyMatch'] } else { $null }
            if ($bm) { Test-Smoke -Url $u -HostHeader $SmokeHostHeader -BodyMatch $bm }
            else     { Test-Smoke -Url $u -HostHeader $SmokeHostHeader }
        }
    }
    catch {
        Write-Host "Deploy or smoke check failed: $($_.Exception.Message)"
        if ($backup) {
            Write-Host "Rolling back site root from '$backup' (stop pool, restore, restart pool)."
            try { Stop-AppPoolAndWait -AppPool $AppPool } catch { Write-Host "  (pool stop during rollback: $($_.Exception.Message))" }
            $rc = @($backup, $SiteFolder, '/MIR','/NFL','/NDL','/NJH','/NJS','/NP','/R:2','/W:2')
            foreach ($d in $PreserveDirs) { $rc += '/XD'; $rc += (Join-Path $SiteFolder $d) }
            robocopy @rc | Out-Null
            $global:LASTEXITCODE = 0
            try { Start-AppPoolAndWait -AppPool $AppPool } catch { Write-Host "  (pool start during rollback: $($_.Exception.Message))" }
        } else {
            Write-Host "No backup available (first deploy?) - cannot roll back automatically."
            try { Start-AppPoolAndWait -AppPool $AppPool } catch { Write-Host "  (best-effort pool start: $($_.Exception.Message))" }
        }
        throw
    }

    Write-Host "Deploy-AspNetCore-IIS complete for '$Name'."
}

Export-ModuleMember -Function Backup-AppFolder, Rotate-Backups, Test-Smoke, Get-AppPoolStateSafe, Stop-AppPoolAndWait, Start-AppPoolAndWait, Deploy-Angular-IIS, Deploy-DotNetWebApp-IIS, Deploy-AspNetCore-IIS, Deploy-DotnetConsole-Scheduled
