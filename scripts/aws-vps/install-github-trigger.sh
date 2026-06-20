#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/opt/github-oci-trigger"
LOG_DIR="/var/log/github-oci-trigger"

if [[ $EUID -ne 0 ]]; then
  echo "install script must run as root" >&2
  exit 1
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "GITHUB_TOKEN is required" >&2
  exit 2
fi

REPO="${REPO:-dlq4455/oci-free-arm-instance}"
WORKFLOW="${WORKFLOW:-create-vm.yml}"
REF="${REF:-main}"

systemctl stop oci-vm-requester.timer oci-vm-requester.service >/dev/null 2>&1 || true
systemctl disable oci-vm-requester.timer >/dev/null 2>&1 || true
rm -f /etc/systemd/system/oci-vm-requester.timer /etc/systemd/system/oci-vm-requester.service
rm -rf /opt/oci-vm-requester

install -d -m 700 -o root -g root "$BASE_DIR"
install -d -m 755 -o root -g root "$LOG_DIR"

cat > "$BASE_DIR/config.env" <<EOF
GITHUB_TOKEN=$(printf '%q' "$GITHUB_TOKEN")
REPO=$(printf '%q' "$REPO")
WORKFLOW=$(printf '%q' "$WORKFLOW")
REF=$(printf '%q' "$REF")
EOF
chmod 600 "$BASE_DIR/config.env"
chown root:root "$BASE_DIR/config.env"

cat > "$BASE_DIR/trigger.py" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone


def log(message: str) -> None:
    print(f"{datetime.now(timezone.utc).isoformat()} {message}", flush=True)


def request(method: str, url: str, token: str, body: dict | None = None):
    data = None
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "aws-vps-oci-workflow-trigger",
    }
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = resp.read().decode("utf-8", errors="replace")
            if not payload:
                return resp.status, None
            return resp.status, json.loads(payload)
    except urllib.error.HTTPError as exc:
        payload = exc.read().decode("utf-8", errors="replace")
        log(f"http_error status={exc.code} body={payload[:1000]}")
        return exc.code, None


def main() -> int:
    token = os.environ["GITHUB_TOKEN"]
    repo = os.environ.get("REPO", "dlq4455/oci-free-arm-instance")
    workflow = os.environ.get("WORKFLOW", "create-vm.yml")
    ref = os.environ.get("REF", "main")
    base = f"https://api.github.com/repos/{repo}/actions/workflows/{workflow}"

    status, workflow_data = request("GET", base, token)
    if status != 200 or not workflow_data:
        log(f"workflow_lookup_failed status={status}")
        return 1

    state = workflow_data.get("state")
    if state != "active":
        log(f"workflow_not_active state={state}; stopping trigger timer")
        os.system("systemctl disable --now github-oci-trigger.timer >/dev/null 2>&1 || true")
        return 0

    runs_url = f"{base}/runs?branch={ref}&per_page=5"
    status, runs_data = request("GET", runs_url, token)
    if status != 200 or not runs_data:
        log(f"runs_lookup_failed status={status}")
        return 1

    for run in runs_data.get("workflow_runs", []):
        if run.get("status") in {"queued", "in_progress", "waiting", "requested", "pending"}:
            log(f"skip_existing_run id={run.get('id')} status={run.get('status')} conclusion={run.get('conclusion')}")
            return 0

    status, _ = request("POST", f"{base}/dispatches", token, {"ref": ref})
    if status == 204:
        log(f"dispatched repo={repo} workflow={workflow} ref={ref}")
        return 0

    log(f"dispatch_failed status={status}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
PY
chmod 700 "$BASE_DIR/trigger.py"
chown root:root "$BASE_DIR/trigger.py"

cat > "$BASE_DIR/trigger.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/opt/github-oci-trigger"
LOG_DIR="/var/log/github-oci-trigger"
mkdir -p "$LOG_DIR"

set -a
# shellcheck disable=SC1091
source "$BASE_DIR/config.env"
set +a

exec /usr/bin/python3 "$BASE_DIR/trigger.py" >> "$LOG_DIR/trigger.log" 2>&1
EOF
chmod 700 "$BASE_DIR/trigger.sh"
chown root:root "$BASE_DIR/trigger.sh"

cat > /etc/systemd/system/github-oci-trigger.service <<'EOF'
[Unit]
Description=Trigger GitHub OCI VM workflow
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/github-oci-trigger/trigger.sh
EOF

cat > /etc/systemd/system/github-oci-trigger.timer <<'EOF'
[Unit]
Description=Trigger GitHub OCI VM workflow every 10 minutes

[Timer]
OnActiveSec=10min
OnUnitActiveSec=10min
AccuracySec=30s
Persistent=false
Unit=github-oci-trigger.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable github-oci-trigger.timer >/dev/null
systemctl list-timers --all github-oci-trigger.timer --no-pager
