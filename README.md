# XMLA CI/CD Utility

Two PowerShell utilities for Power BI Premium CI/CD, sharing one `settings.json` and one Entra ID sign-in flow:

- **`run.ps1`** — interactive XMLA console: sign in, pick an environment (DEV / BENCH / PROD), then paste and execute XMLA/TMSL commands in a loop. Semantic model operations only (deploy via `createOrReplace`, refresh, etc.).
- **`deploy.ps1`** — full PBIP deployment: takes the PBIP projects from your git (Bitbucket) clone and pushes **semantic models (TMDL) and reports (PBIR)** to the target workspace through the Fabric item APIs. This covers what XMLA cannot: the report layer.
- **`publish.ps1`** — one command for both: commits pending changes (asking for a message), pushes the current branch to origin, and then chains into `deploy.ps1`. Deployment only starts if the push succeeded, so the workspace can never get ahead of source control. If the push is rejected (protected branch), it tells you to publish via pull request and deploy after the merge.

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

## Full deployment (deploy.ps1)

Deploys everything that is in the git clone to a workspace — the "release" path. Start it with `deploy.cmd`. The flow:

1. **Git sync** — shows the branch of `repoPath`, fetches, offers a fast-forward pull if behind, and demands a typed `YES` if the working tree has uncommitted changes (you would be deploying something that is not in Bitbucket). The deployed branch/commit appears in the summary.
2. **Discovery** — finds every `*.SemanticModel` and `*.Report` folder in the repo (works with separate `semantic-models/` and `reports/` trees). Pick items by number or `A` for all.
3. **Sign-in and environment** — same Entra ID flow and PROD confirmation gate as `run.ps1`.
4. **Deployment** — models first, then reports. Each item is created if absent, otherwise its definition is updated in place (`createOrReplace` semantics, item IDs preserved). Each report's `definition.pbir` is rebound from its local `byPath` reference to the semantic model in the target workspace.
5. **Optional refresh** of the deployed models at the end.

Requirements and notes:

- The workspace must be on Premium/Fabric capacity (same requirement as the XMLA endpoint).
- `.pbi/` folders, `.platform` files, and `*.abf` caches are never uploaded.
- The token is requested with the Power BI scope by default, which the Fabric APIs accept; if your tenant rejects it, set `apiScope` in `settings.json` to `https://api.fabric.microsoft.com/.default`.
- Updating an existing semantic model's definition does not delete its data — but a schema change may require a refresh before reports render.

## Repository layout

| Path | Purpose |
|------|---------|
| `run.cmd` | Double-click launcher for `run.ps1` |
| `run.ps1` | The interactive XMLA console |
| `deploy.cmd` | Double-click launcher for `deploy.ps1` |
| `deploy.ps1` | Full PBIP deployment (models + reports) from the git clone |
| `publish.cmd` | Double-click launcher for `publish.ps1` |
| `publish.ps1` | Commit + push to origin, then chain into `deploy.ps1` |
| `settings.example.json` | Template for `settings.json` (tenant, client ID, repo path, environments) |
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
