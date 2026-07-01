# XMLA CI/CD Utility

Interactive PowerShell console for running XMLA/TMSL commands against Power BI Premium workspaces through the XMLA endpoint. Sign in once with Entra ID, pick an environment (DEV / BENCH / PROD), then paste and execute commands in a loop.

## Prerequisites

- Windows with Windows PowerShell 5.1 (built in)
- A Power BI account with write access to the target workspace's XMLA endpoint
- **No SSMS required** — all libraries are bundled in this repo

## Usage

1. Clone or download this repository.
2. Copy `settings.example.json` to `settings.json` and fill in your tenant ID, client ID, and workspace names. `settings.json` is gitignored, so the real values never reach source control.
3. Double-click `run.cmd` (it launches `run.ps1` and works even where `.ps1` execution is disabled by policy). Alternatively, right-click `run.ps1` > *Run with PowerShell*.
4. Enter your professional email and complete the browser sign-in.
5. Choose the environment. An environment named `PROD` requires typing `PROD` to confirm.
6. Paste an XMLA/TMSL command, press Enter twice to send it. Type `exit` to quit.

The access token is refreshed automatically when it is close to expiry, so long sessions keep working.

## Repository layout

| Path | Purpose |
|------|---------|
| `run.cmd` | Double-click launcher for `run.ps1` |
| `run.ps1` | The interactive XMLA console |
| `settings.example.json` | Template for `settings.json` (tenant, client ID, environments) |
| `libs-msal/` | Microsoft Authentication Library (MSAL) for the Entra ID sign-in |
| `libs-adomd/` | ADOMD.NET client used for the XMLA connection |

## Bundled libraries

The DLLs are taken as-is from the official Microsoft NuGet packages:

| Folder | NuGet package | Version | Target |
|--------|---------------|---------|--------|
| `libs-msal` | [Microsoft.Identity.Client](https://www.nuget.org/packages/Microsoft.Identity.Client/4.44.0) | 4.44.0 | net461 |
| `libs-adomd` | [Microsoft.AnalysisServices.AdomdClient.retail.amd64](https://www.nuget.org/packages/Microsoft.AnalysisServices.AdomdClient.retail.amd64/19.84.1) | 19.84.1 | net45 |

MSAL is pinned to 4.44.0 on purpose: it is the last major line that ships as a single self-contained DLL for .NET Framework, which keeps the repo drop-in runnable under Windows PowerShell 5.1 without a chain of transitive dependencies.

To update a library, download the newer `.nupkg` from NuGet, extract it (it is a zip), and replace the DLL in the matching `libs-*` folder.

If a `libs-*` folder is missing, the script falls back to auto-detecting the DLL from a local **DAX Studio** or **SSMS** installation — both ship MSAL and ADOMD. Useful on locked-down machines where the bundled binaries cannot be brought in but one of those tools is already installed.
