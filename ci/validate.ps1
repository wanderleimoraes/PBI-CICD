# validate.ps1 - CI validation of a PBIP dashboards repository.
# Fails (exit 1) when the repo contains data artifacts or broken PBIP structure.
# Runs on Windows PowerShell 5.1 and PowerShell 7+ (Linux pipeline containers).

param([string]$RepoPath = ".")

$ErrorActionPreference = "Stop"
$RepoPath = (Resolve-Path $RepoPath).Path
$failures = [System.Collections.Generic.List[string]]::new()

function Fail { param($Message) $failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }
function Pass { param($Message) Write-Host "ok    $Message" -ForegroundColor Green }

# 1. No data artifacts in source control (.pbix, .abf caches, .pbi folders)
if (Get-Command git -ErrorAction SilentlyContinue) {
    $tracked = @(git -C $RepoPath ls-files)
}
else {
    # CI checkouts contain only committed files, so a filesystem scan is equivalent
    $tracked = @(Get-ChildItem $RepoPath -Recurse -File | ForEach-Object {
        $_.FullName.Substring($RepoPath.Length).TrimStart('\', '/').Replace('\', '/')
    })
}
$forbidden = @($tracked | Where-Object { $_ -match '\.pbix$|\.abf$|(^|/)\.pbi/' -and $_ -notmatch '(^|/)\.git/' })
if ($forbidden.Count -gt 0) {
    foreach ($f in $forbidden) { Fail "data artifact must not be committed: $f" }
}
else {
    Pass "no .pbix / .abf / .pbi artifacts tracked"
}

# 2. Semantic models: definition present and definition.pbism valid
$models = @(Get-ChildItem $RepoPath -Recurse -Directory -Filter "*.SemanticModel")
foreach ($m in $models) {
    $defFolder = Join-Path $m.FullName "definition"
    $hasTmdl = (Test-Path $defFolder) -and (@(Get-ChildItem $defFolder -Recurse -Filter "*.tmdl").Count -gt 0)
    $hasBim = Test-Path (Join-Path $m.FullName "model.bim")
    if ($hasTmdl -or $hasBim) { Pass "$($m.Name): model definition present" }
    else { Fail "$($m.Name): no TMDL definition folder and no model.bim" }

    $pbism = Join-Path $m.FullName "definition.pbism"
    if (-not (Test-Path $pbism)) {
        Fail "$($m.Name): definition.pbism missing"
    }
    else {
        try { Get-Content $pbism -Raw | ConvertFrom-Json | Out-Null; Pass "$($m.Name): definition.pbism valid" }
        catch { Fail "$($m.Name): definition.pbism is not valid JSON" }
    }
}
if ($models.Count -eq 0) { Write-Host "note: no *.SemanticModel folders found" -ForegroundColor Yellow }

# 3. Reports: definition.pbir valid and its model reference resolvable
$reports = @(Get-ChildItem $RepoPath -Recurse -Directory -Filter "*.Report")
foreach ($r in $reports) {
    $pbirFile = Join-Path $r.FullName "definition.pbir"
    if (-not (Test-Path $pbirFile)) { Fail "$($r.Name): definition.pbir missing"; continue }
    try { $pbir = Get-Content $pbirFile -Raw | ConvertFrom-Json }
    catch { Fail "$($r.Name): definition.pbir is not valid JSON"; continue }

    if ($pbir.datasetReference.byPath.path) {
        $target = Join-Path $r.FullName $pbir.datasetReference.byPath.path
        if (Resolve-Path $target -ErrorAction SilentlyContinue) { Pass "$($r.Name): byPath model reference resolves" }
        else { Fail "$($r.Name): byPath target not found: $($pbir.datasetReference.byPath.path)" }
    }
    elseif ($pbir.datasetReference.byConnection) {
        Write-Host "note: $($r.Name) uses a fixed byConnection binding" -ForegroundColor Yellow
    }
    else {
        Fail "$($r.Name): definition.pbir has no dataset reference"
    }
}

# 4. Every JSON file inside the items must parse
foreach ($folder in (@($models) + @($reports))) {
    $jsonFiles = @(Get-ChildItem $folder.FullName -Recurse -File |
        Where-Object { $_.Extension -in ".json", ".pbir", ".pbism" -and $_.FullName -notmatch '[\\/]\.pbi[\\/]' })
    foreach ($j in $jsonFiles) {
        try { Get-Content $j.FullName -Raw | ConvertFrom-Json | Out-Null }
        catch { Fail ("invalid JSON: " + $j.FullName.Substring($RepoPath.Length).TrimStart('\', '/')) }
    }
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "VALIDATION FAILED - $($failures.Count) issue(s)" -ForegroundColor Red
    exit 1
}
Write-Host "VALIDATION PASSED" -ForegroundColor Green
exit 0
