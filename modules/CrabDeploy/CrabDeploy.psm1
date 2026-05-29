# CrabDeploy - shared deploy helpers for a self-hosted Windows GitHub Actions runner.
# Phase 1 scope: Angular -> IIS static site. Console/msbuild helpers come in later phases.
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
        [string]$HostHeader
    )
    $headers = @{}
    if ($HostHeader) { $headers['Host'] = $HostHeader }
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -TimeoutSec 30
            if ($resp.StatusCode -eq $ExpectStatus) {
                Write-Host "Smoke OK: $Url -> $($resp.StatusCode)"
                return
            }
            Write-Host "Smoke attempt $i/$Retries -> got $($resp.StatusCode), want $ExpectStatus"
        } catch {
            Write-Host "Smoke attempt $i/$Retries failed: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds $DelaySec
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
        [string[]]$Preserve = @('web.config')
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
        foreach ($f in $Preserve) { $rc += '/XF'; $rc += $f }
        Write-Host "Deploy: '$ArtifactDir' -> '$SiteFolder' (preserving: $($Preserve -join ', '))"
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

Export-ModuleMember -Function Backup-AppFolder, Rotate-Backups, Test-Smoke, Deploy-Angular-IIS
