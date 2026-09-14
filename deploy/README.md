# CI/CD — push to GitHub → auto-deploy to production

Design and rationale: `../10-SEPT-2026-PRODUCTION-DEPLOYMENT.md` §9, and the
approved plan `~/.claude/plans/can-you-setup-ci-cd-*.md`.

**Model:** each app repo pushes to its production branch → a GitHub Action SSHes
to the Hetzner box and runs `/opt/apps/deploy.sh <AppDir>`, which does: global
lock → `git reset --hard origin/<branch>` → `docker compose build` → `up -d` →
migrate → HTTPS health gate → **auto-rollback + red job on any failure**. No
test gate (by choice); the build and health check are the gates. Secrets never
leave the box.

## Files here

| File | Goes where |
|---|---|
| `deploy.sh` | `/opt/apps/deploy.sh` on the box (pushed by `bootstrap.sh`) |
| `manifests/<AppDir>.json` | `/opt/apps/<AppDir>/.deploy.json` on the box |
| `bootstrap.sh` | run from your workstation, one-time + on every `deploy.sh`/manifest change |
| `github/deploy-reusable.yml` | `.github/workflows/deploy-reusable.yml` in a new repo `usamarasheed26/stratagem-deploy` |
| `github/app-deploy.yml` | template → `.github/workflows/deploy.yml` in each app repo |

## Rollout order

Do these **in order**. Each app is only onboarded after its repo is the source
of truth (Phase 0). Order = safest first:

`www → leadership → AIEnterpriseTransformation → Macrolab → FMCG-Simulataor → ZeroToPMF → SimulationStudio → autorevive → AIRevenueLeakage → platform`

## One-time setup

1. **Answer the open items** (below).
2. `bash deploy/bootstrap.sh` — creates the `deploy` user, sudoers entry, pushes `deploy.sh`.
3. Create repo **`usamarasheed26/stratagem-deploy`**, add `github/deploy-reusable.yml`.
4. Set GitHub **org secrets** (Settings → Secrets → Actions):
   `DEPLOY_HOST=46.224.15.73`, `DEPLOY_USER=deploy`, `DEPLOY_SSH_KEY=`(contents of `ssh/deploy-key`).

## Per-app onboarding (Phase 0 + wire-up)

For `<App>` (dir under `/opt/apps`, repo per its manifest):

1. **Snapshot:** `ssh root@box 'tar czf /opt/backups/predeploy/<App>-$(date +%F).tgz -C /opt/apps <App>'`
2. **Reconcile the repo** — make GitHub match what's running:
   - App **has `.git` on the box** (`platform`, `leadership`, `www`): review `git status`, commit + push the real state to the canonical branch. `leadership` = 27 files; `platform` = pick the canonical branch and remove the committed `.env.production` (`git rm --cached`, add to `.gitignore`, **rotate** the keys).
   - App **has no `.git`** (everything else): clone the repo to a scratch dir, `diff -r` against `/opt/apps/<App>`, fold the server-only fixes (see `../DEPLOYMENT.md` §3 for the documented ones) into a branch, PR, merge to the canonical branch.
   - Move any secrets embedded in `docker-compose*.yml` (`FMCG-Simulataor`, `ZeroToPMF`, `SimulationStudio`, `AIRevenueLeakage`) to an `env_file:` and rotate them.
   - Add `.env`, `.env.production`, `.env.prod`, `.deploy.json` to the repo `.gitignore`.
3. **Clean checkout on the box:**
   ```
   mv /opt/apps/<App> /opt/apps/<App>.pre-cicd
   git clone -b <branch> git@github.com:<repo>.git /opt/apps/<App>
   # recreate the box-only env file(s) from <App>.pre-cicd
   cp deploy/manifests/<App>.json  →  /opt/apps/<App>/.deploy.json   (bootstrap.sh does this)
   chown -R deploy:deploy /opt/apps/<App>     # so `git reset` works under sudo-run deploy.sh
   ```
4. **Dry run:** `ssh deploy@box 'sudo -n /opt/apps/deploy.sh <App> --check'` → expect `--check OK`.
5. **Manual deploy once:** `ssh deploy@box 'sudo -n /opt/apps/deploy.sh <App>'` → expect `✅ DEPLOYED`, then run the §14 health sweep.
6. **Wire GitHub:** copy `github/app-deploy.yml` → the repo's `.github/workflows/deploy.yml`, fill `<PROD_BRANCH>` + `<APP_DIR>`. For `autorevive` also delete the dead `deploy.yml` + `ci-cd.yml`.
7. **Prove it:** `git commit --allow-empty -m "ci: trigger deploy" && git push` → watch the Action go green → confirm the new image (`docker inspect <container> --format '{{.Image}}'`).

## Rollback drill (do once)

On a low-risk sim, push a commit that breaks the Docker build (or the app's
health). Confirm: the Action goes **red**, `deploy.sh` logs a rollback, the site
stays up on the previous image, and `/opt/apps/.deploy-history.log` shows
`rollback:...`.

## Manual operations

```bash
ssh deploy@46.224.15.73
sudo -n /opt/apps/deploy.sh <App>            # deploy origin/<branch> now
sudo -n /opt/apps/deploy.sh <App> --check    # validate only
tail -n 50 /opt/apps/.deploy-history.log     # audit trail
```

## Platform — reconciliation detail (verified 2026-09-11)

Good news: the box's `/opt/apps/platform` has **no divergent code** — HEAD
`40011a6` is a direct ancestor of `origin/master` (`1a7c17f`), fast-forwardable;
`docker-compose.prod.yml` + `Dockerfile` match `origin/master` exactly. The only
real drift is `.env.production` (tracked, 2 lines):

| key | committed on GitHub | actual on box |
|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | `…supabase.co` (**cloud**) | `platform.stratagemengine.com` (**self-hosted layer**) |
| `SUPER_ADMIN_CLERK_USER_ID` | `user_3Ggc…` | `user_3J81…` |

If `deploy.sh` ran a `git reset --hard` with `.env.production` still tracked, it
would revert the platform to **cloud Supabase** → break DB access. So step 1 is
non-negotiable: **untrack it.** `.dockerignore` does not exclude `.env*`, so
`next build` still bakes `NEXT_PUBLIC_*` from the on-disk file.

**Operator commits (local Platform repo):**
```
git checkout master && git pull
git rm --cached .env.production
printf '\n.env.production\n' >> .gitignore
git commit -m "chore: untrack .env.production — prod secrets live on the box only"
git push origin master
```

**Then (box reconciliation — automated by the assistant):**
```
cd /opt/apps/platform
cp .env.production /root/_backup/platform.env.production.$(date +%s)   # safety
git fetch origin
git checkout -- .env.production          # drop the 2-line drift so the tree is clean
git reset --hard origin/master           # FF + apply the untrack commit
cp /root/_backup/platform.env.production.*  .env.production   # restore the box-real file
docker compose -f docker-compose.prod.yml build && docker compose -f docker-compose.prod.yml up -d
# health: https://platform.stratagemengine.com/ -> 401 (Clerk gate = healthy)
```

**Follow-up (not blocking):** rotate the secrets exposed in the Platform repo's
git history — `CLERK_SECRET_KEY`, `STRIPE_SECRET_KEY`, `SUPABASE_SERVICE_ROLE_KEY`,
`SUPABASE_JWT_SECRET` (also update `/opt/apps/supabase/.env`), `ANTHROPIC_API_KEY`,
and the `*_SECRET` HMAC values.

## Open items (need answers before setup)

- **`AIRevenueLeakage` repo** — the account deploy key can't see
  `usamarasheed26/AIRevenueLeakage`. Confirm the real name/owner and grant
  access (fill `manifests/AIRevenueLeakage.json` `repo`).
- **Canonical production branch per repo.** Manifests currently assume:
  `www` main, `platform` master (BUT it's running `fix/prod-clerk-middleware-domain`),
  `leadership` main, `autorevive` master, `AIEnterpriseTransformation` master,
  `FMCG-Simulataor` master (running a `feature/*`?), `Macrolab` master,
  `ZeroToPMF` main (running a `feature/*`?), `SimulationStudio` main.
- **`SimulationStudio` schema management** for `simulationstudio_db` — set
  `.migrate` in its manifest once known.
- OK to create the `deploy` Linux user + the `stratagem-deploy` GitHub repo.

## Not in this pass (Phase 5)

CI-gated deploys (branch protection + required checks); self-hosted runner on
the box; GHCR build-offload; Slack notifications.
