# deploy-ci.ps1 - non-interactive PBIP deployment for CI pipelines.
# Same deployment logic as deploy.ps1, but authenticates with a SERVICE PRINCIPAL
# (client credentials) instead of a browser sign-in, takes everything from
# parameters/environment variables, and reports through exit codes.
# Runs on Windows PowerShell 5.1 and PowerShell 7+ (Linux pipeline containers).

param(
    [string]$RepoPath = ".",
    [string]$WorkspaceName = $env:WORKSPACE_NAME,
    [string]$TenantId = $env:AZURE_TENANT_ID,
    [string]$ClientId = $env:AZURE_CLIENT_ID,
    [string]$ClientSecret = $env:AZURE_CLIENT_SECRET,
    [string]$ApiScope = $(if ($env:PBI_API_SCOPE) { $env:PBI_API_SCOPE } else { "https://api.fabric.microsoft.com/.default" }),
    [switch]$Refresh
)

$ErrorActionPreference = "Stop"

foreach ($required in "WorkspaceName", "TenantId", "ClientId", "ClientSecret") {
    if (-not (Get-Variable $required -ValueOnly)) {
        Write-Host "ERROR: $required not provided (parameter or environment variable)." -ForegroundColor Red
        exit 1
    }
}

$RepoPath = (Resolve-Path $RepoPath).Path
$fabricBase = "https://api.fabric.microsoft.com/v1"

# ------------------------------------------------- token (client credentials)

$script:tokenExpires = [DateTime]::MinValue
function Update-AccessToken {
    if ($script:tokenExpires -gt (Get-Date).AddMinutes(5)) { return }
    $resp = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = $ApiScope
    }
    $script:token = $resp.access_token
    $script:tokenExpires = (Get-Date).AddSeconds([int]$resp.expires_in)
    Write-Host "Access token acquired (service principal)."
}

# ------------------------------------------------------------ Fabric API helpers

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
                try { $wait = [int]("$($_.Exception.Response.Headers['Retry-After'])" -split "\s+" | Select-Object -First 1) } catch {}
                Write-Host "Throttled (429) - waiting $wait s..."
                Start-Sleep -Seconds $wait
                continue
            }
            $detail = $_.ErrorDetails.Message
            if (-not $detail) { $detail = $_.Exception.Message }
            throw "Fabric API $Method $Uri failed (HTTP $status): $detail"
        }
    }

    if ([int]$resp.StatusCode -eq 202) {
        $opId = "$($resp.Headers['x-ms-operation-id'] | Select-Object -First 1)"
        if (-not $opId) { throw "202 Accepted without x-ms-operation-id header." }
        $interval = 3
        try { $interval = [math]::Min([int]"$($resp.Headers['Retry-After'] | Select-Object -First 1)", 30) } catch {}
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
        catch { return $null }
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

    Write-Host "  refresh $refreshId started, waiting for completion..."
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
        $rel = $f.FullName.Substring($ItemFolder.Length).TrimStart('\', '/').Replace('\', '/')
        if ($rel -match '(^|/)\.pbi(/|$)') { continue }
        if ($rel -eq ".platform") { continue }
        if ($f.Extension -eq ".abf") { continue }
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
    $pbir = Get-Content $PbirFile -Raw | ConvertFrom-Json
    if (-not $pbir.datasetReference.byPath) { return $null }
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
    $pbirFile = Join-Path $ReportFolder "definition.pbir"
    if (-not (Test-Path $pbirFile)) { return $null }
    $pbir = Get-Content $pbirFile -Raw | ConvertFrom-Json
    if (-not $pbir.datasetReference.byPath.path) { return $null }
    $resolved = Resolve-Path (Join-Path $ReportFolder $pbir.datasetReference.byPath.path) -ErrorAction SilentlyContinue
    if (-not $resolved) { return $null }
    return (Split-Path $resolved -Leaf) -replace "\.SemanticModel$", ""
}

# ------------------------------------------------------------------- deployment

Write-Host "=== PBIP deployment (CI) ==="
Write-Host "Repo      : $RepoPath"
Write-Host "Workspace : $WorkspaceName"

Update-AccessToken

$workspace = Get-FabricPaged "$fabricBase/workspaces" | Where-Object { $_.displayName -eq $WorkspaceName } | Select-Object -First 1
if (-not $workspace) {
    Write-Host "ERROR: Workspace '$WorkspaceName' not found or the service principal has no access." -ForegroundColor Red
    exit 1
}
$wsId = $workspace.id
Write-Host "Workspace id: $wsId"

$existingItems = Get-FabricPaged "$fabricBase/workspaces/$wsId/items"
$modelIds = @{}
foreach ($it in ($existingItems | Where-Object { $_.type -eq "SemanticModel" })) { $modelIds[$it.displayName] = $it.id }

$catalog = @()
foreach ($f in @(Get-ChildItem $RepoPath -Recurse -Directory -Filter "*.SemanticModel")) {
    $catalog += [pscustomobject]@{ Type = "SemanticModel"; Name = ($f.Name -replace "\.SemanticModel$", ""); Folder = $f.FullName }
}
foreach ($f in @(Get-ChildItem $RepoPath -Recurse -Directory -Filter "*.Report")) {
    $catalog += [pscustomobject]@{ Type = "Report"; Name = ($f.Name -replace "\.Report$", ""); Folder = $f.FullName }
}
if ($catalog.Count -eq 0) {
    Write-Host "ERROR: no *.SemanticModel or *.Report folders found under $RepoPath" -ForegroundColor Red
    exit 1
}

$failedCount = 0
$deployedModelIds = @()
foreach ($item in ($catalog | Sort-Object @{ Expression = { if ($_.Type -eq "SemanticModel") { 0 } else { 1 } } })) {
    Write-Host ""
    Write-Host "Deploying $($item.Type) '$($item.Name)'..."
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
                    throw "Report references semantic model '$modelName', which is not in the workspace."
                }
                $rebound = Convert-PbirToByConnection (Join-Path $item.Folder "definition.pbir") $modelIds[$modelName]
                if ($rebound) { $overrides["definition.pbir"] = $rebound }
            }
        }

        $parts = Get-DefinitionParts $item.Folder $overrides
        $definition = @{ parts = $parts }
        if ($format) { $definition["format"] = $format }

        $existing = $existingItems | Where-Object { $_.type -eq $item.Type -and $_.displayName -eq $item.Name } | Select-Object -First 1
        if ($existing) {
            Invoke-FabricApi "Post" "$fabricBase/workspaces/$wsId/items/$($existing.id)/updateDefinition" @{ definition = $definition } | Out-Null
            $itemId = $existing.id
            Write-Host "  updated ($itemId)"
        }
        else {
            $created = Invoke-FabricApi "Post" "$fabricBase/workspaces/$wsId/items" @{ displayName = $item.Name; type = $item.Type; definition = $definition }
            $itemId = $created.id
            Write-Host "  created ($itemId)"
        }
        if ($item.Type -eq "SemanticModel" -and $itemId) {
            $modelIds[$item.Name] = $itemId
            $deployedModelIds += $itemId
        }
    }
    catch {
        Write-Host "  FAILED: $_" -ForegroundColor Red
        $failedCount++
    }
}

if ($Refresh -and $deployedModelIds.Count -gt 0) {
    Write-Host ""
    Write-Host "=== Refreshing deployed semantic model(s) ==="
    foreach ($id in $deployedModelIds) {
        try {
            Wait-DatasetRefresh -WorkspaceId $wsId -DatasetId $id
        }
        catch {
            Write-Host "  Refresh FAILED for $id : $_" -ForegroundColor Red
            $failedCount++
        }
    }
}

Write-Host ""
if ($failedCount -gt 0) {
    Write-Host "DEPLOYMENT FINISHED WITH $failedCount FAILURE(S)" -ForegroundColor Red
    exit 1
}
Write-Host "DEPLOYMENT SUCCEEDED" -ForegroundColor Green
exit 0
