# deploy.ps1 - Full PBIP deployment from the Bitbucket clone to a Power BI workspace.
# Deploys semantic models (TMDL) and reports (PBIR) through the Fabric item APIs,
# rebinding each report to the target workspace's semantic model.

# Load MSAL (bundled in libs-msal next to this script)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Exit-WithMessage {
    param([string[]]$Lines)
    foreach ($l in $Lines) { Write-Host $l -ForegroundColor Red }
    Write-Host "Press any key to close..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit
}

$msalPath = "$scriptDir\libs-msal\Microsoft.Identity.Client.dll"
if (-not (Test-Path $msalPath)) {
    Exit-WithMessage "ERROR: Could not find MSAL library at: $msalPath"
}
[System.Reflection.Assembly]::LoadFrom($msalPath) | Out-Null

# ------------------------------------------------------------------ settings

$settingsPath = "$scriptDir\settings.json"
if (-not (Test-Path $settingsPath)) {
    Exit-WithMessage "ERROR: Could not find settings.json next to deploy.ps1.",
        "Copy settings.example.json to settings.json and fill in your values."
}

$settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
$environments = @($settings.environments)

# Treat template placeholders like "<...>" as unset
function Get-Setting {
    param($Value, $Default)
    if ($Value -and $Value -notmatch '^\s*<') { return $Value }
    return $Default
}

$tenantId = Get-Setting $settings.tenantId
$clientId = Get-Setting $settings.clientId
$apiScope = Get-Setting $settings.apiScope "https://analysis.windows.net/powerbi/api/.default"
$repoPath = Get-Setting $settings.repoPath
$defaultBranch = Get-Setting $settings.defaultBranch "main"

if (-not $tenantId -or -not $clientId -or $environments.Count -eq 0) {
    Exit-WithMessage "ERROR: settings.json must define tenantId, clientId and at least one environment."
}

# ------------------------------------------------------- repository (git) prep

if (-not $repoPath -or -not (Test-Path $repoPath)) {
    Write-Host "No valid repoPath in settings.json." -ForegroundColor Yellow
    $repoPath = Read-Host "Enter the local path of the Bitbucket clone with the PBIP projects"
}
if (-not (Test-Path $repoPath)) {
    Exit-WithMessage "ERROR: Path not found: $repoPath"
}

git -C $repoPath rev-parse --is-inside-work-tree 2>&1 | Out-Null
$isGitRepo = ($LASTEXITCODE -eq 0)

$deployedRef = "(not a git repository)"
if ($isGitRepo) {
    $branch = (git -C $repoPath rev-parse --abbrev-ref HEAD).Trim()
    Write-Host ""
    Write-Host "Repository : $repoPath" -ForegroundColor Cyan
    Write-Host "Branch     : $branch" -ForegroundColor Cyan

    if ($branch -ne $defaultBranch) {
        Write-Host "You are not on '$defaultBranch'." -ForegroundColor Yellow
        $answer = Read-Host "Deploy from branch '$branch' anyway? (Y/n)"
        if ($answer -eq "n") { Exit-WithMessage "Aborted." }
    }

    Write-Host "Fetching from origin..." -ForegroundColor Gray
    git -C $repoPath fetch origin 2>&1 | Out-Null

    $dirty = git -C $repoPath status --porcelain
    $counts = git -C $repoPath rev-list --left-right --count "HEAD...origin/$branch" 2>$null
    if ($LASTEXITCODE -eq 0 -and $counts) {
        $behind = [int]($counts -split "\s+")[1]
        if ($behind -gt 0) {
            Write-Host "Local branch is $behind commit(s) behind origin/$branch." -ForegroundColor Yellow
            if ($dirty) {
                Write-Host "Working tree has local changes - cannot pull automatically." -ForegroundColor Yellow
            }
            else {
                $answer = Read-Host "Pull latest before deploying? (Y/n)"
                if ($answer -ne "n") {
                    git -C $repoPath pull --ff-only 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { Exit-WithMessage "ERROR: git pull failed. Resolve manually and retry." }
                    Write-Host "Pulled latest from origin/$branch." -ForegroundColor Green
                }
            }
        }
    }

    if ($dirty) {
        Write-Host ""
        Write-Host "WARNING: the working tree has UNCOMMITTED changes." -ForegroundColor Yellow
        Write-Host "You would be deploying a state that is not in Bitbucket." -ForegroundColor Yellow
        $answer = Read-Host "Type YES to deploy the local state anyway"
        if ($answer -cne "YES") { Exit-WithMessage "Aborted." }
        $deployedRef = "$branch (with uncommitted changes)"
    }
    else {
        $deployedRef = "$branch @ $((git -C $repoPath rev-parse --short HEAD).Trim())"
    }
}
else {
    Write-Host "WARNING: $repoPath is not a git repository - deploying files as-is." -ForegroundColor Yellow
}

# --------------------------------------------------------- discover PBIP items

$modelFolders = @(Get-ChildItem $repoPath -Recurse -Directory -Filter "*.SemanticModel" -ErrorAction SilentlyContinue)
$reportFolders = @(Get-ChildItem $repoPath -Recurse -Directory -Filter "*.Report" -ErrorAction SilentlyContinue)

if ($modelFolders.Count -eq 0 -and $reportFolders.Count -eq 0) {
    Exit-WithMessage "ERROR: No *.SemanticModel or *.Report folders found under $repoPath."
}

$catalog = [System.Collections.Generic.List[object]]::new()
foreach ($f in $modelFolders) {
    $catalog.Add([pscustomobject]@{ Type = "SemanticModel"; Name = ($f.Name -replace "\.SemanticModel$", ""); Folder = $f.FullName })
}
foreach ($f in $reportFolders) {
    $catalog.Add([pscustomobject]@{ Type = "Report"; Name = ($f.Name -replace "\.Report$", ""); Folder = $f.FullName })
}

Write-Host ""
Write-Host "Items found in the repository:" -ForegroundColor Cyan
for ($i = 0; $i -lt $catalog.Count; $i++) {
    Write-Host (" [{0}] {1,-14} {2}" -f ($i + 1), $catalog[$i].Type, $catalog[$i].Name)
}
Write-Host ""

$selection = Read-Host "Enter numbers to deploy (e.g. 1,3), or A for all"
if ($selection -match '^[aA]$') {
    $selected = @($catalog)
}
else {
    $selected = @()
    foreach ($token in ($selection -split ",")) {
        $n = 0
        if ([int]::TryParse($token.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $catalog.Count) {
            $selected += $catalog[$n - 1]
        }
        else {
            Exit-WithMessage "ERROR: Invalid selection: '$($token.Trim())'"
        }
    }
}

# Models must be deployed before the reports that reference them
$selected = @($selected | Sort-Object @{ Expression = { if ($_.Type -eq "SemanticModel") { 0 } else { 1 } } })

# --------------------------------------------------------------- authentication

$userEmail = Read-Host "Please enter your professional email address"

$app = [Microsoft.Identity.Client.PublicClientApplicationBuilder]::Create($clientId).WithAuthority("https://login.microsoftonline.com/$tenantId").WithRedirectUri("http://localhost").Build()
$scopes = [System.Collections.Generic.List[string]]::new()
$scopes.Add($apiScope)

function Update-AccessToken {
    if ($script:tokenResult.ExpiresOn.UtcDateTime -gt [DateTime]::UtcNow.AddMinutes(10)) { return }
    Write-Host "Access token close to expiry - refreshing..." -ForegroundColor Yellow
    try {
        $script:tokenResult = $app.AcquireTokenSilent($scopes, $script:tokenResult.Account).ExecuteAsync().GetAwaiter().GetResult()
    }
    catch {
        $script:tokenResult = $app.AcquireTokenInteractive($scopes).WithLoginHint($userEmail).ExecuteAsync().GetAwaiter().GetResult()
    }
    $script:token = $script:tokenResult.AccessToken
}

try {
    Write-Host "Opening browser for Entra ID login..." -ForegroundColor Yellow
    $tokenResult = $app.AcquireTokenInteractive($scopes).WithLoginHint($userEmail).ExecuteAsync().GetAwaiter().GetResult()
    $token = $tokenResult.AccessToken
    Write-Host "Token acquired!" -ForegroundColor Green
}
catch {
    Exit-WithMessage "Authentication failed: $_"
}

# ------------------------------------------------------------ Fabric API helpers

$fabricBase = "https://api.fabric.microsoft.com/v1"

function Invoke-FabricApi {
    param([string]$Method, [string]$Uri, $Body)

    Update-AccessToken
    $headers = @{ Authorization = "Bearer $($script:token)" }
    $json = $null
    if ($null -ne $Body) { $json = $Body | ConvertTo-Json -Depth 20 }

    $attempts = 0
    while ($true) {
        $attempts++
        try {
            if ($json) {
                $resp = Invoke-WebRequest -UseBasicParsing -Method $Method -Uri $Uri -Headers $headers -Body $json -ContentType "application/json; charset=utf-8"
            }
            else {
                $resp = Invoke-WebRequest -UseBasicParsing -Method $Method -Uri $Uri -Headers $headers
            }
            break
        }
        catch {
            $status = 0
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            if ($status -eq 429 -and $attempts -le 5) {
                $wait = 15
                try { $wait = [int]$_.Exception.Response.Headers["Retry-After"] } catch {}
                Write-Host "Throttled (429) - waiting $wait s..." -ForegroundColor Yellow
                Start-Sleep -Seconds $wait
                continue
            }
            $detail = $_.ErrorDetails.Message
            if (-not $detail) { $detail = $_.Exception.Message }
            throw "Fabric API $Method $Uri failed (HTTP $status): $detail"
        }
    }

    # Long-running operation: poll until it finishes, then fetch the result
    if ($resp.StatusCode -eq 202) {
        $opId = $resp.Headers["x-ms-operation-id"]
        if (-not $opId) { throw "202 Accepted without x-ms-operation-id header." }
        $interval = 3
        try { $interval = [math]::Min([int]$resp.Headers["Retry-After"], 30) } catch {}
        $deadline = (Get-Date).AddMinutes(20)
        while ($true) {
            Start-Sleep -Seconds $interval
            Update-AccessToken
            $op = Invoke-RestMethod -Method Get -Uri "$fabricBase/operations/$opId" -Headers @{ Authorization = "Bearer $($script:token)" }
            if ($op.status -eq "Succeeded") { break }
            if ($op.status -eq "Failed") { throw "Operation failed: $($op.error | ConvertTo-Json -Depth 5 -Compress)" }
            if ((Get-Date) -gt $deadline) { throw "Operation $opId timed out after 20 minutes." }
        }
        try {
            return Invoke-RestMethod -Method Get -Uri "$fabricBase/operations/$opId/result" -Headers @{ Authorization = "Bearer $($script:token)" }
        }
        catch { return $null }  # some operations have no result body
    }

    if ($resp.Content) { return $resp.Content | ConvertFrom-Json }
    return $null
}

function Get-FabricPaged {
    param([string]$Uri)
    $all = @()
    $next = $Uri
    while ($next) {
        $page = Invoke-FabricApi "Get" $next
        $all += @($page.value)
        $next = $page.continuationUri
    }
    return $all
}

function Wait-DatasetRefresh {
    param([string]$WorkspaceId, [string]$DatasetId, [int]$TimeoutMinutes = 30, [int]$PollSeconds = 10)

    Update-AccessToken
    $refreshUri = "https://api.powerbi.com/v1.0/myorg/groups/$WorkspaceId/datasets/$DatasetId/refreshes"
    $resp = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $refreshUri -Headers @{ Authorization = "Bearer $($script:token)" } -Body '{"notifyOption":"NoNotification"}' -ContentType "application/json"

    # The refresh id normally comes back in the RequestId header; fall back to reading
    # the most recent history entry if a proxy/gateway ever strips it.
    $refreshId = $null
    try { $refreshId = ($resp.Headers["RequestId"] | Select-Object -First 1) } catch {}
    if (-not $refreshId) {
        Start-Sleep -Seconds 2
        Update-AccessToken
        $latest = Invoke-RestMethod -Method Get -Uri "$refreshUri`?`$top=1" -Headers @{ Authorization = "Bearer $($script:token)" }
        $refreshId = $latest.value[0].requestId
    }
    if (-not $refreshId) { throw "Refresh started but no refresh id could be determined - cannot confirm completion." }

    Write-Host "  refresh $refreshId started, waiting for completion..." -ForegroundColor Gray
    $statusUri = "$refreshUri/$refreshId"
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($true) {
        Start-Sleep -Seconds $PollSeconds
        Update-AccessToken
        $status = Invoke-RestMethod -Method Get -Uri $statusUri -Headers @{ Authorization = "Bearer $($script:token)" }
        if ($status.status -eq "Completed") {
            Write-Host "  refresh completed" -ForegroundColor Green
            return
        }
        if ($status.status -in @("Failed", "Disabled", "Cancelled")) {
            throw "Refresh ended with status '$($status.status)': $($status.serviceExceptionJson)"
        }
        if ((Get-Date) -gt $deadline) { throw "Refresh $refreshId timed out after $TimeoutMinutes minutes (still '$($status.status)')." }
    }
}

# ------------------------------------------------------- definition part builders

function Get-DefinitionParts {
    param([string]$ItemFolder, [hashtable]$OverridePayloads = @{})

    $parts = @()
    $files = Get-ChildItem $ItemFolder -Recurse -File
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($ItemFolder.Length).TrimStart("\").Replace("\", "/")
        if ($rel -match '(^|/)\.pbi(/|$)') { continue }      # local cache/settings - never deploy
        if ($rel -eq ".platform") { continue }               # workspace-specific metadata
        if ($f.Extension -eq ".abf") { continue }            # data cache
        if ($OverridePayloads.ContainsKey($rel)) {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($OverridePayloads[$rel])
        }
        else {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        }
        $parts += @{ path = $rel; payload = [Convert]::ToBase64String($bytes); payloadType = "InlineBase64" }
    }
    return $parts
}

function Convert-PbirToByConnection {
    param([string]$PbirFile, [string]$SemanticModelId)
    # Rebinds a byPath reference to the semantic model deployed in the workspace.
    $pbir = Get-Content $PbirFile -Raw | ConvertFrom-Json
    if (-not $pbir.datasetReference.byPath) { return $null }  # already byConnection - leave untouched
    $pbir.datasetReference = [pscustomobject]@{
        byConnection = [pscustomobject]@{
            connectionString          = $null
            pbiServiceModelId         = $null
            pbiModelVirtualServerName = "sobe_wowvirtualserver"
            pbiModelDatabaseName      = $SemanticModelId
            name                      = "EntityDataSource"
            connectionType            = "pbiServiceXmlaStyleLive"
        }
    }
    return $pbir | ConvertTo-Json -Depth 10
}

function Resolve-ReportModelName {
    param([string]$ReportFolder)
    # Reads definition.pbir and returns the name of the semantic model it points to.
    $pbirFile = Join-Path $ReportFolder "definition.pbir"
    if (-not (Test-Path $pbirFile)) { return $null }
    $pbir = Get-Content $pbirFile -Raw | ConvertFrom-Json
    if (-not $pbir.datasetReference.byPath.path) { return $null }
    $target = Join-Path $ReportFolder $pbir.datasetReference.byPath.path
    $resolved = Resolve-Path $target -ErrorAction SilentlyContinue
    if (-not $resolved) { return $null }
    return (Split-Path $resolved -Leaf) -replace "\.SemanticModel$", ""
}

# -------------------------------------------------------- environment selection

Write-Host ""
Write-Host "Select the target environment:" -ForegroundColor Cyan
for ($i = 0; $i -lt $environments.Count; $i++) {
    Write-Host (" [{0}] {1}" -f ($i + 1), $environments[$i].name)
}
Write-Host ""

$envChoice = Read-Host "Enter your choice (1-$($environments.Count))"
$choiceIndex = 0
if ([int]::TryParse($envChoice, [ref]$choiceIndex) -and $choiceIndex -ge 1 -and $choiceIndex -le $environments.Count) {
    $selectedEnv = $environments[$choiceIndex - 1]
}
else {
    Exit-WithMessage "Invalid choice."
}

$envName = $selectedEnv.name
$workspaceName = $selectedEnv.workspace

if ($envName -eq "PROD") {
    Write-Host ""
    Write-Host "WARNING: You are about to DEPLOY to the PROD workspace." -ForegroundColor Yellow
    $confirmation = Read-Host "Type PROD to confirm"
    if ($confirmation -cne "PROD") { Exit-WithMessage "PROD not confirmed. Aborted." }
}

# ------------------------------------------------------------------- deployment

$startTime = Get-Date

try {
    Write-Host ""
    Write-Host "Resolving workspace '$workspaceName'..." -ForegroundColor Yellow
    $workspace = Get-FabricPaged "$fabricBase/workspaces" | Where-Object { $_.displayName -eq $workspaceName } | Select-Object -First 1
    if (-not $workspace) { throw "Workspace '$workspaceName' not found or not accessible." }
    $wsId = $workspace.id
    Write-Host "Workspace id: $wsId" -ForegroundColor Gray

    $existingItems = Get-FabricPaged "$fabricBase/workspaces/$wsId/items"
    $modelIds = @{}
    foreach ($it in ($existingItems | Where-Object { $_.type -eq "SemanticModel" })) { $modelIds[$it.displayName] = $it.id }

    $results = @()
    $deployedModelIds = @()

    foreach ($item in $selected) {
        Write-Host ""
        Write-Host "Deploying $($item.Type) '$($item.Name)'..." -ForegroundColor Yellow
        try {
            $overrides = @{}
            $format = $null

            if ($item.Type -eq "SemanticModel") {
                if (Test-Path (Join-Path $item.Folder "definition")) { $format = "TMDL" }
            }
            else {
                if (Test-Path (Join-Path $item.Folder "definition")) { $format = "PBIR" } else { $format = "PBIR-Legacy" }
                $modelName = Resolve-ReportModelName $item.Folder
                if ($modelName) {
                    if (-not $modelIds.ContainsKey($modelName)) {
                        throw "Report references semantic model '$modelName', which is not in the workspace. Deploy the model first."
                    }
                    $rebound = Convert-PbirToByConnection (Join-Path $item.Folder "definition.pbir") $modelIds[$modelName]
                    if ($rebound) {
                        $overrides["definition.pbir"] = $rebound
                        Write-Host "Rebound report to semantic model '$modelName' ($($modelIds[$modelName]))" -ForegroundColor Gray
                    }
                }
                else {
                    Write-Host "definition.pbir has no byPath reference - deploying as-is." -ForegroundColor Yellow
                }
            }

            $parts = Get-DefinitionParts $item.Folder $overrides
            if ($parts.Count -eq 0) { throw "No deployable files found in $($item.Folder)." }
            $definition = @{ parts = $parts }
            if ($format) { $definition["format"] = $format }

            $existing = $existingItems | Where-Object { $_.type -eq $item.Type -and $_.displayName -eq $item.Name } | Select-Object -First 1
            if ($existing) {
                Invoke-FabricApi "Post" "$fabricBase/workspaces/$wsId/items/$($existing.id)/updateDefinition" @{ definition = $definition } | Out-Null
                $itemId = $existing.id
                $action = "updated"
            }
            else {
                $created = Invoke-FabricApi "Post" "$fabricBase/workspaces/$wsId/items" @{ displayName = $item.Name; type = $item.Type; definition = $definition }
                $itemId = $created.id
                $action = "created"
            }

            if ($item.Type -eq "SemanticModel" -and $itemId) {
                $modelIds[$item.Name] = $itemId
                $deployedModelIds += $itemId
            }

            Write-Host "$($item.Type) '$($item.Name)' $action." -ForegroundColor Green
            $results += [pscustomobject]@{ Item = "$($item.Type) $($item.Name)"; Status = $action.ToUpper() }
        }
        catch {
            Write-Host "FAILED: $_" -ForegroundColor Red
            $results += [pscustomobject]@{ Item = "$($item.Type) $($item.Name)"; Status = "FAILED" }
        }
    }

    # Optional refresh of the deployed semantic models (Power BI REST API) - waits for
    # completion and reports success/failure, rather than firing and hoping.
    if ($deployedModelIds.Count -gt 0) {
        Write-Host ""
        $answer = Read-Host "Trigger a refresh of the deployed semantic model(s) now? (y/N)"
        if ($answer -eq "y") {
            foreach ($id in $deployedModelIds) {
                try {
                    Wait-DatasetRefresh -WorkspaceId $wsId -DatasetId $id
                    $results += [pscustomobject]@{ Item = "Refresh $id"; Status = "COMPLETED" }
                }
                catch {
                    Write-Host "Refresh failed for $id : $_" -ForegroundColor Red
                    $results += [pscustomobject]@{ Item = "Refresh $id"; Status = "FAILED" }
                }
            }
        }
    }

    # Summary
    $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
    $failed = @($results | Where-Object { $_.Status -eq "FAILED" }).Count
    $color = "Green"; if ($failed -gt 0) { $color = "Red" }
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor $color
    Write-Host "                 DEPLOYMENT SUMMARY                       " -ForegroundColor $color
    Write-Host "==========================================================" -ForegroundColor $color
    Write-Host ""
    Write-Host " User        : $userEmail"
    Write-Host " Environment : $envName ($workspaceName)"
    Write-Host " Source      : $deployedRef"
    Write-Host " Duration    : $elapsed seconds"
    Write-Host ""
    foreach ($r in $results) {
        $c = "Green"; if ($r.Status -eq "FAILED") { $c = "Red" }
        Write-Host (" {0,-10} {1}" -f $r.Status, $r.Item) -ForegroundColor $c
    }
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor $color
}
catch {
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host "                 DEPLOYMENT FAILED                        " -ForegroundColor Red
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host " Error : $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Red
}

Write-Host ""
Write-Host "Press any key to close..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
