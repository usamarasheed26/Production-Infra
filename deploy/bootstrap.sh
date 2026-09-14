#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# One-time box preparation for the CI/CD pipeline. Run from the Production
# Infrastructure repo on your workstation:
#
#     bash deploy/bootstrap.sh
#
# Idempotent. Does:
#   1. generate a dedicated deploy SSH keypair  -> ssh/deploy-key(.pub)   (gitignored)
#   2. create the `deploy` user on the box (no docker-group membership --
#      see the note in the REMOTE block below on why that would defeat the
#      sudoers restriction in step 4)
#   3. authorise the deploy key for `deploy`
#   4. NOPASSWD sudoers entry: deploy may run ONLY /opt/apps/deploy.sh
#   5. install jq; create /opt/backups/predeploy
#   6. push deploy/deploy.sh -> /opt/apps/deploy.sh  and each manifest ->
#      /opt/apps/<AppDir>/.deploy.json   (only for apps that already have a
#      git checkout — the rest get theirs during Phase 0)
#
# It does NOT: create git checkouts, touch app containers, or change the
# firewall. Re-run any time to resync deploy.sh / manifests.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/.."

KEY="ssh/production-infra-key"
HOST="root@46.224.15.73"
DEPLOY_KEY="ssh/deploy-key"
SSH="ssh -i $KEY -o StrictHostKeyChecking=accept-new"

command -v ssh-keygen >/dev/null || { echo "ssh-keygen not found"; exit 1; }

# 1. deploy keypair
if [ ! -f "$DEPLOY_KEY" ]; then
  echo "→ generating $DEPLOY_KEY"
  ssh-keygen -t ed25519 -f "$DEPLOY_KEY" -N "" -C "stratagem-deploy"
fi
PUB=$(cat "$DEPLOY_KEY.pub")

# 2-5. box user + sudoers + deps
# The deploy public key is sent as the first stdin line (it contains spaces).
{ printf '%s\n' "$PUB"; cat <<'REMOTE'
set -euo pipefail
read -r DEPLOY_PUB   # first line = the deploy public key
id deploy &>/dev/null || { useradd -m -s /bin/bash deploy; echo "created user deploy"; }
# Deliberately NOT in the `docker` group: docker-group membership is
# root-equivalent (docker run -v /:/host ... gives a root shell), which
# would make the sudoers restriction below meaningless. deploy.sh itself
# runs as root via the sudoers NOPASSWD entry (ALL=(root)), so every
# docker/docker compose command it issues already runs as root — the
# deploy user never needs docker-group access of its own.
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
touch /home/deploy/.ssh/authorized_keys
grep -qF "$DEPLOY_PUB" /home/deploy/.ssh/authorized_keys || echo "$DEPLOY_PUB" >> /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys

cat > /etc/sudoers.d/deploy <<'SUDO'
deploy ALL=(root) NOPASSWD: /opt/apps/deploy.sh
Defaults:deploy env_keep += "GITHUB_ACTOR GITHUB_SHA"
SUDO
chmod 440 /etc/sudoers.d/deploy
visudo -cf /etc/sudoers.d/deploy

command -v jq >/dev/null || { apt-get update -qq && apt-get install -y -qq jq; }
install -d -m 755 /opt/backups/predeploy
echo "box prep OK: $(id deploy)"
REMOTE
} | $SSH "$HOST" 'bash -s'

# 6. push deploy.sh + manifests
echo "→ pushing deploy.sh"
scp -i "$KEY" deploy/deploy.sh "$HOST:/opt/apps/deploy.sh"
$SSH "$HOST" 'chmod 755 /opt/apps/deploy.sh && chown root:root /opt/apps/deploy.sh'

for m in deploy/manifests/*.json; do
  app=$(basename "$m" .json)
  if $SSH "$HOST" "test -d /opt/apps/$app/.git"; then
    echo "→ manifest: $app"
    scp -i "$KEY" "$m" "$HOST:/opt/apps/$app/.deploy.json"
  else
    echo "→ skip manifest $app (no git checkout yet — Phase 0)"
  fi
done

echo
echo "Done. GitHub secrets to set (org level or per-repo):"
echo "  DEPLOY_HOST = 46.224.15.73"
echo "  DEPLOY_USER = deploy"
echo "  DEPLOY_SSH_KEY = (contents of $DEPLOY_KEY)"
