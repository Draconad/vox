# Waits for the newest iOS build on GitHub and downloads Vox.ipa into build-out\.
#
# push-to-github.bat calls this for you. You can also run it on its own
# (right-click -> Run with PowerShell) if the push worked but the download didn't;
# it never pushes anything.

param(
    [string]$Repo = "",
    [int]$TimeoutMinutes = 45
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

if (-not $Repo) {
    if (Test-Path "github-repo.txt") { $Repo = (Get-Content "github-repo.txt" -First 1).Trim() }
}
if (-not $Repo) {
    Write-Host "No repository known. Run push-to-github.bat first." -ForegroundColor Red
    exit 1
}

Write-Host "Repository: $Repo"
Write-Host ""

function Get-LatestRun {
    $json = gh run list --repo $Repo --workflow ios.yml --limit 1 `
        --json databaseId,status,conclusion,createdAt,displayTitle 2>$null
    if (-not $json) { return $null }
    return ($json | ConvertFrom-Json)[0]
}

# The run can take a few seconds to appear after `workflow run`.
$run = $null
for ($i = 0; $i -lt 12; $i++) {
    $run = Get-LatestRun
    if ($run) { break }
    Start-Sleep -Seconds 5
}
if (-not $run) {
    Write-Host "No build found. Check https://github.com/$Repo/actions" -ForegroundColor Yellow
    exit 1
}

# Keep the id in its own variable. Two reasons: PowerShell does NOT do property
# access inside a native command's arguments ("gh run view $run.databaseId" passes
# the stringified $run with the literal text ".databaseId" glued on, and gh answers
# "run or job ID required"), and the poll below replaces $run with an object that
# only carries status/conclusion, so the id would be gone after the first pass.
$runId = $run.databaseId

Write-Host "Build #$runId - $($run.displayTitle)"
Write-Host "Live progress: https://github.com/$Repo/actions/runs/$runId"
Write-Host ""

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$spin = @('|', '/', '-', '\')
$n = 0
$state = $null

while ((Get-Date) -lt $deadline) {
    $json = gh run view $runId --repo $Repo --json status,conclusion 2>$null
    if ($json) { $state = $json | ConvertFrom-Json }
    if ($state -and $state.status -eq "completed") { break }
    Write-Host -NoNewline ("`r  {0} building... (a Mac build usually takes 4-8 minutes)   " -f $spin[$n % 4])
    $n++
    Start-Sleep -Seconds 10
}
Write-Host ""

if (-not $state -or $state.status -ne "completed") {
    Write-Host "Still going after $TimeoutMinutes minutes. Check the Actions tab." -ForegroundColor Yellow
    Write-Host "  https://github.com/$Repo/actions/runs/$runId"
    exit 1
}

New-Item -ItemType Directory -Force -Path "build-out" | Out-Null

if ($state.conclusion -ne "success") {
    Write-Host "The build failed. Downloading the log into build-out\..." -ForegroundColor Red
    gh run download $runId --repo $Repo --name ios-build-log --dir "build-out" 2>$null
    Write-Host ""
    Write-Host "Send me build-out\build.log and I'll fix it."
    exit 1
}

Write-Host "Build succeeded. Downloading the app..." -ForegroundColor Green
gh run download $runId --repo $Repo --name Vox-ipa --dir "build-out"
if ($LASTEXITCODE -ne 0) {
    Write-Host "Couldn't download it. Grab it from the Actions page instead." -ForegroundColor Yellow
    exit 1
}

$ipa = Get-ChildItem "build-out\Vox.ipa" -ErrorAction SilentlyContinue
if ($ipa) {
    $stamped = "build-out\Vox-$(Get-Date -Format 'yyyyMMdd-HHmm').ipa"
    Copy-Item $ipa.FullName $stamped -Force
    Write-Host ""
    Write-Host "Done:" -ForegroundColor Green
    Write-Host "  $($ipa.FullName)"
    Write-Host "  $stamped"
    Write-Host ""
    Write-Host "Open iLoader, pick that .ipa, and install it to your iPhone."
}
exit 0
