# Team workflow — Power BI dashboards on Bitbucket

This replaces "open Power BI Desktop, click Publish, done." Copy this file into the dashboards repository's `docs/` folder alongside `ci/bitbucket-pipelines.yml`.

## The model: one trunk, environments are pipeline stages

There is **no branch per environment** (no `staging`, `dev`, `prod` branches). `main` is the only long-lived branch. DEV, BENCH and PROD are deployment stages inside one pipeline, promoted forward by clicking a button — never by merging one branch into another.

```
feature/my-change --PR--> validate --squash-merge--> main
                                                        |
                                                        v
                                          Deploy to DEV   (automatic)
                                                        |
                                              [click "Run"]
                                                        v
                                          Deploy to BENCH  (manual)
                                                        |
                                              [click "Run"]
                                                        v
                                          Deploy to PROD   (manual)
```

Why not environment branches: they drift apart, need their own merges, and "what's actually in PROD" stops having one clear answer. With this model the answer is always a commit SHA on `main`.

## Day-to-day steps

1. **Branch.** `git switch -c feature/short-description` (or `chore/...`, `fix/...`) from an up-to-date `main`.
2. **Edit in Power BI Desktop as usual.** Save. This writes TMDL (model) / PBIR (report) files to disk in the repo — do **not** use the Desktop "Publish" button.
3. **Commit and push.**
   ```bash
   git add -A
   git commit -m "feat(sales): add region filter"
   git push -u origin feature/short-description
   ```
4. **Open a pull request** into `main`. Bitbucket Pipelines runs `validate.ps1` automatically — it fails the PR if a `.pbix`/`.abf` sneaks in, a TMDL/PBIR file is malformed, or a report points at a model that isn't there.
5. **Get it reviewed and merge** (squash). Merging **is** the publish step — no manual deploy command needed by the developer.
6. **DEV deploys automatically.** The pipeline runs `deploy-ci.ps1` unattended (service principal) the moment `main` moves. Go look at DEV.
7. **Promote to BENCH**, when ready: in Bitbucket, open the pipeline run for that commit and click **Run** on the "Deploy to BENCH" stage. Whoever does UAT works from BENCH.
8. **Promote to PROD**, after BENCH is signed off: click **Run** on "Deploy to PROD" for that same commit/run.

Steps 7 and 8 deploy the exact same build that went to DEV — nothing is rebuilt or re-picked from a different branch.

## What to configure in Bitbucket for this to hold

- **Branch permissions on `main`**: PR-only, no direct push, no force-push, no deletion, 1+ approval required (already part of the toolkit's governance).
- **Deployment environments** (Repository settings → Deployments): create `DEV`, `BENCH`, `PROD`. Restrict who can trigger `BENCH` and `PROD` (Environment → Restrictions) to the people actually authorized to promote to those tiers — this is where the approval control really lives, not in the YAML.
- **Repository variables** for the service principal (`AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, marked secured) — see the header of `ci/bitbucket-pipelines.yml`.

## The two local scripts, and when to still use them

- **`deploy.ps1`** (interactive, browser sign-in) — for a developer's own sanity check before opening a PR ("does this even deploy cleanly?"), or as a break-glass tool if the pipeline is down. Not the team's normal path to any shared environment anymore.
- **`run.ps1`** — unrelated to deployment; the ad-hoc XMLA/TMSL console for operational tasks (refreshes, partition maintenance) against an already-deployed model.
