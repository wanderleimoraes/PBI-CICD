# publish.ps1 - one command: publish the current branch to origin (Bitbucket/GitHub),
# then deploy to a Power BI workspace. Deployment only runs if the push succeeded,
# so the workspace can never get ahead of source control.

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Exit-WithMessage {
    param([string[]]$Lines)
    foreach ($l in $Lines) { Write-Host $l -ForegroundColor Red }
    Write-Host "Press any key to close..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit
}

# ------------------------------------------------------------------ settings

$settingsPath = "$scriptDir\settings.json"
if (-not (Test-Path $settingsPath)) {
    Exit-WithMessage "ERROR: Could not find settings.json next to publish.ps1.",
        "Copy settings.example.json to settings.json and fill in your values."
}

$settings = Get-Content $settingsPath -Raw | ConvertFrom-Json

function Get-Setting {
    param($Value, $Default)
    if ($Value -and $Value -notmatch '^\s*<') { return $Value }
    return $Default
}

$repoPath = Get-Setting $settings.repoPath

if (-not $repoPath -or -not (Test-Path $repoPath)) {
    Write-Host "No valid repoPath in settings.json." -ForegroundColor Yellow
    $repoPath = Read-Host "Enter the local path of the git clone with the PBIP projects"
}
if (-not (Test-Path $repoPath)) {
    Exit-WithMessage "ERROR: Path not found: $repoPath"
}

git -C $repoPath rev-parse --is-inside-work-tree 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Exit-WithMessage "ERROR: $repoPath is not a git repository."
}

# --------------------------------------------------------- step 1: publish

$branch = (git -C $repoPath rev-parse --abbrev-ref HEAD).Trim()
Write-Host ""
Write-Host "=== Step 1 of 2: publish to origin ===" -ForegroundColor Cyan
Write-Host "Repository : $repoPath"
Write-Host "Branch     : $branch"
Write-Host ""

$dirty = git -C $repoPath status --porcelain
if ($dirty) {
    Write-Host "Uncommitted changes:" -ForegroundColor Yellow
    git -C $repoPath status --short
    Write-Host ""
    $message = Read-Host "Commit message for these changes (leave empty to abort)"
    if (-not $message) { Exit-WithMessage "Aborted - nothing was published or deployed." }
    git -C $repoPath add -A
    git -C $repoPath commit -m $message | Out-Null
    if ($LASTEXITCODE -ne 0) { Exit-WithMessage "ERROR: git commit failed." }
    Write-Host "Committed." -ForegroundColor Green
}

Write-Host "Fetching from origin..." -ForegroundColor Gray
git -C $repoPath fetch origin 2>&1 | Out-Null

# Integrate remote work first, if any (linear history - rebase local commits on top)
$counts = git -C $repoPath rev-list --left-right --count "HEAD...origin/$branch" 2>$null
if ($LASTEXITCODE -eq 0 -and $counts) {
    $behind = [int]($counts -split "\s+")[1]
    if ($behind -gt 0) {
        Write-Host "Branch is $behind commit(s) behind origin/$branch - rebasing..." -ForegroundColor Yellow
        git -C $repoPath pull --rebase 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            git -C $repoPath rebase --abort 2>&1 | Out-Null
            Exit-WithMessage "ERROR: Could not rebase on origin/$branch (conflicts?).",
                "Resolve manually, then run publish again. Nothing was deployed."
        }
    }
}

Write-Host "Pushing $branch to origin..." -ForegroundColor Yellow
git -C $repoPath push -u origin $branch
if ($LASTEXITCODE -ne 0) {
    Exit-WithMessage "ERROR: git push was rejected.",
        "If this branch is protected (e.g. main in Bitbucket), publish via a pull request instead,",
        "then run deploy.cmd after the merge. Nothing was deployed."
}

$commit = (git -C $repoPath rev-parse --short HEAD).Trim()
Write-Host "Published $branch @ $commit to origin." -ForegroundColor Green

# ---------------------------------------------------------- step 2: deploy

Write-Host ""
Write-Host "=== Step 2 of 2: deploy to Power BI ===" -ForegroundColor Cyan
& "$scriptDir\deploy.ps1"
