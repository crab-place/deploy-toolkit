# CrabDeploy - shared deploy helpers for a self-hosted Windows GitHub Actions runner.
# Phase 1 scope: Angular -> IIS static site. Phase 2 adds .NET WebApi -> IIS bin swap.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Backup-AppFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SiteFolder,
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not (Test-Path -LiteralPath $SiteFolder)) {
        Write-Host "Backup-AppFolder: '$SiteFolder' does not exist yet - first deploy, nothing to back up."
        return $null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dest  = Join-Path (Join-Path $BackupRoot $Name) $stamp
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Write-Host "Backup: '$SiteFolder' -> '$dest'"
    robocopy $SiteFolder $dest /MIR /NFL /NDL /NJH /NJS /NP /R:2 /W:2 | Out-Null
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
        [string]$BodyMatch        # Optional regex - response body must match this in addition to status
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
        [hashtable[]]$ExtraSmokes = @()    # Each: @{ Url = '...'; BodyMatch = '...' (optional) }
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
        # Additive recursive copy - preserves anything in prod bin\ not in the build (GA4_Credential, etc.)
        New-Item -ItemType Directory -Path $siteBin -Force | Out-Null
        Write-Host "Copy: '$ArtifactDir' -> '$siteBin' (additive, recursive, no purge)"
        robocopy $ArtifactDir $siteBin /E /NFL /NDL /NJH /NJS /NP /R:2 /W:2 | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy deploy failed (exit $LASTEXITCODE)" }
        $global:LASTEXITCODE = 0

        # Start pool inside try - if it fails, rollback path triggers
        Write-Host "Starting app pool '$AppPool'"
        Start-WebAppPool -Name $AppPool
        Start-Sleep -Seconds 2

        # Primary smoke
        Test-Smoke -Url $SmokeUrl -HostHeader $SmokeHostHeader

        # Extra smokes (e.g. shipping endpoint with body match) - any failure triggers rollback
        foreach ($s in $ExtraSmokes) {
            $u = $s['Url']
            $bm = if ($s.ContainsKey('BodyMatch')) { $s['BodyMatch'] } else { $null }
            if ($bm) {
                Test-Smoke -Url $u -HostHeader $SmokeHostHeader -BodyMatch $bm
            } else {
                Test-Smoke -Url $u -HostHeader $SmokeHostHeader
            }
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

Export-ModuleMember -Function Backup-AppFolder, Rotate-Backups, Test-Smoke, Deploy-Angular-IIS, Deploy-DotNetWebApp-IIS