# Load libraries
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Local installs known to ship the DLLs below (used only if the libs-* folders are missing).
# Loading from the install folder keeps each DLL next to its own dependencies.
$fallbackRoots = @(
    "C:\Program Files\DAX Studio*",
    "$env:LOCALAPPDATA\DaxStudio*",
    "C:\Program Files\Microsoft SQL Server Management Studio*"
)

function Find-FallbackDll {
    param([string]$DllName)
    # Newest by ProductVersion: the FileVersion on these DLLs is an engine build
    # number (e.g. 17.0.x) and does not reflect the actual library version.
    Get-ChildItem $script:fallbackRoots -Recurse -Filter $DllName -ErrorAction SilentlyContinue |
        Sort-Object -Descending {
            $v = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($_.FullName).ProductVersion
            $parsed = [version]"0.0"
            if ([version]::TryParse(($v -split '[+-]')[0], [ref]$parsed)) { $parsed } else { [version]"0.0" }
        } |
        Select-Object -First 1 -ExpandProperty FullName
}

# MSAL: use the bundled copy in libs-msal; if missing, fall back to DAX Studio / SSMS
$msalPath = "$scriptDir\libs-msal\Microsoft.Identity.Client.dll"
if (-not (Test-Path $msalPath)) {
    $msalPath = Find-FallbackDll "Microsoft.Identity.Client.dll"
}

if (-not $msalPath) {
    Write-Host "ERROR: Could not find MSAL library." -ForegroundColor Red
    Write-Host "Place Microsoft.Identity.Client.dll in $scriptDir\libs-msal, or install DAX Studio or SSMS." -ForegroundColor Red
    Write-Host "Press any key to close..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit
}

Write-Host "Found MSAL at: $msalPath" -ForegroundColor Gray
[System.Reflection.Assembly]::LoadFrom($msalPath) | Out-Null

# ADOMD: use the bundled copy in libs-adomd; if missing, fall back to DAX Studio / SSMS
$adomdPath = "$scriptDir\libs-adomd\Microsoft.AnalysisServices.AdomdClient.dll"
if (-not (Test-Path $adomdPath)) {
    $adomdPath = Find-FallbackDll "Microsoft.AnalysisServices.AdomdClient.dll"
}

if (-not $adomdPath) {
    Write-Host "ERROR: Could not find ADOMD library." -ForegroundColor Red
    Write-Host "Place Microsoft.AnalysisServices.AdomdClient.dll in $scriptDir\libs-adomd, or install DAX Studio or SSMS." -ForegroundColor Red
    Write-Host "Press any key to close..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit
}

Write-Host "Found ADOMD at: $adomdPath" -ForegroundColor Gray
[System.Reflection.Assembly]::LoadFrom($adomdPath) | Out-Null

# Load settings (kept out of source control - see settings.example.json)
$settingsPath = "$scriptDir\settings.json"
if (-not (Test-Path $settingsPath)) {
    Write-Host "ERROR: Could not find settings.json next to run.ps1." -ForegroundColor Red
    Write-Host "Copy settings.example.json to settings.json and fill in your values." -ForegroundColor Red
    Write-Host "Press any key to close..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit
}

$settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
$environments = @($settings.environments)

if (-not $settings.tenantId -or -not $settings.clientId -or $environments.Count -eq 0) {
    Write-Host "ERROR: settings.json must define tenantId, clientId and at least one environment." -ForegroundColor Red
    Write-Host "Press any key to close..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit
}

# Entra ID config
$tenantId = $settings.tenantId
$clientId = $settings.clientId
$redirectUri = "http://localhost"
$scopes = [System.Collections.Generic.List[string]]::new()
$scopes.Add("https://analysis.windows.net/powerbi/api/.default")

# Start timer
$startTime = Get-Date

# Ask for the user email
$userEmail = Read-Host "Please enter your professional email address"

# Build MSAL app
$app = [Microsoft.Identity.Client.PublicClientApplicationBuilder]::Create($clientId).WithAuthority("https://login.microsoftonline.com/$tenantId").WithRedirectUri($redirectUri).Build()

# Refreshes the access token when it is within 10 minutes of expiry.
# Returns $true when a new token was issued (the XMLA connection must then be reopened).
function Update-AccessToken {
    if ($script:tokenResult.ExpiresOn.UtcDateTime -gt [DateTime]::UtcNow.AddMinutes(10)) {
        return $false
    }
    Write-Host "Access token close to expiry - refreshing..." -ForegroundColor Yellow
    try {
        $script:tokenResult = $app.AcquireTokenSilent($scopes, $script:tokenResult.Account).ExecuteAsync().GetAwaiter().GetResult()
    }
    catch {
        Write-Host "Silent refresh failed, opening browser for a new login..." -ForegroundColor Yellow
        $script:tokenResult = $app.AcquireTokenInteractive($scopes).WithLoginHint($userEmail).ExecuteAsync().GetAwaiter().GetResult()
    }
    $script:token = $script:tokenResult.AccessToken
    Write-Host "Token refreshed!" -ForegroundColor Green
    return $true
}

try {
    Write-Host "Opening browser for Entra ID login..." -ForegroundColor Yellow
    $tokenResult = $app.AcquireTokenInteractive($scopes).WithLoginHint($userEmail).ExecuteAsync().GetAwaiter().GetResult()
    $token = $tokenResult.AccessToken
    $authTime = Get-Date
    Write-Host "Token acquired!" -ForegroundColor Green
}
catch {
    Write-Host "Authentication failed: $_" -ForegroundColor Red
    Write-Host "Press any key to close..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit
}

# Environment selection menu (built from settings.json)
Write-Host ""
Write-Host "Select the environment:" -ForegroundColor Cyan
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
    Write-Host "Invalid choice. Defaulting to $($environments[0].name)." -ForegroundColor Yellow
    $selectedEnv = $environments[0]
}

$envName = $selectedEnv.name
$workspace = [uri]::EscapeDataString($selectedEnv.workspace)

# Safety gate before touching production
if ($envName -eq "PROD") {
    Write-Host ""
    Write-Host "WARNING: You are about to connect to the PROD workspace." -ForegroundColor Yellow
    $confirmation = Read-Host "Type PROD to confirm"
    if ($confirmation -cne "PROD") {
        Write-Host "PROD not confirmed. Closing without connecting." -ForegroundColor Red
        Write-Host "Press any key to close..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit
    }
}

# Connect to Power BI XMLA
$connectionString = "Data Source=powerbi://api.powerbi.com/v1.0/myorg/$workspace;Password=$token;"

try {
    $connection = New-Object Microsoft.AnalysisServices.AdomdClient.AdomdConnection($connectionString)
    $connection.Open()
    Write-Host "Connected to Power BI XMLA - [$envName] workspace" -ForegroundColor Green

    # Loop to keep asking for new XMLA commands
    while ($true) {

        # Reopen the connection with a fresh token if the current one is about to expire
        if (Update-AccessToken) {
            $connection.Close()
            $connectionString = "Data Source=powerbi://api.powerbi.com/v1.0/myorg/$workspace;Password=$token;"
            $connection = New-Object Microsoft.AnalysisServices.AdomdClient.AdomdConnection($connectionString)
            $connection.Open()
            Write-Host "Reconnected to Power BI XMLA - [$envName] workspace" -ForegroundColor Green
        }

        $command = $connection.CreateCommand()

        Write-Host ""
        Write-Host "Please paste your XMLA command below, then press Enter twice when done:" -ForegroundColor Cyan
        Write-Host "(or type 'exit' and press Enter to disconnect and close)" -ForegroundColor Gray

        $lines = [System.Collections.Generic.List[string]]::new()
        while ($true) {
            $line = Read-Host
            if ($line -eq "") { break }
            if ($line -eq "exit") {
                Write-Host "Disconnecting..." -ForegroundColor Yellow
                $connection.Close()
                Write-Host "Press any key to close..."
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                exit
            }
            $lines.Add($line)
        }

        if ($lines.Count -eq 0) {
            Write-Host "Nothing to send - paste a command or type 'exit'." -ForegroundColor Yellow
            continue
        }

        $command.CommandText = $lines -join "`n"

        try {
            Write-Host "Sending command..." -ForegroundColor Yellow
            $commandStart = Get-Date
            $command.ExecuteNonQuery()
            $commandEnd = Get-Date

            # Calculate durations
            $totalDuration = [math]::Round(($commandEnd - $startTime).TotalSeconds, 1)
            $authDuration = [math]::Round(($authTime - $startTime).TotalSeconds, 1)
            $commandDuration = [math]::Round(($commandEnd - $commandStart).TotalSeconds, 1)

            # Print summary
            Write-Host ""
            Write-Host "==========================================================" -ForegroundColor Green
            Write-Host "                 EXECUTION SUCCESSFUL                     " -ForegroundColor Green
            Write-Host "==========================================================" -ForegroundColor Green
            Write-Host ""
            Write-Host " User           : $userEmail"
            Write-Host " Environment    : $envName"
            Write-Host " Started at     : $($startTime.ToString('HH:mm:ss'))"
            Write-Host " Completed at   : $($commandEnd.ToString('HH:mm:ss'))"
            Write-Host " Authentication : $authDuration seconds"
            Write-Host " Command exec.  : $commandDuration seconds"
            Write-Host " Total duration : $totalDuration seconds"
            Write-Host ""
            Write-Host "==========================================================" -ForegroundColor Green
            Write-Host ""
            Write-Host "Ready for next command!" -ForegroundColor Cyan
        }
        catch {
            # Command failed but connection still alive - ask for new command
            Write-Host ""
            Write-Host "==========================================================" -ForegroundColor Red
            Write-Host "                   COMMAND FAILED                         " -ForegroundColor Red
            Write-Host "==========================================================" -ForegroundColor Red
            Write-Host ""
            Write-Host " Error : $_" -ForegroundColor Red
            Write-Host ""
            Write-Host "==========================================================" -ForegroundColor Red
            Write-Host ""
            Write-Host "You can try a new command or type 'exit' to close." -ForegroundColor Yellow
        }

    } # end while loop

}
catch {
    # Connection failed
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host "                  CONNECTION FAILED                       " -ForegroundColor Red
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host " User        : $userEmail"
    Write-Host " Environment : $envName"
    Write-Host " Error       : $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Press any key to close..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
