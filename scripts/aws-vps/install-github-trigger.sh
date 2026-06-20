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

GITHUB_TOKEN="${GITHUB_TOKEN//$'\r'/}"
GITHUB_TOKEN="${GITHUB_TOKEN//$'\n'/}"
REPO="${REPO:-dlq4455/oci-free-arm-instance}"
WORKFLOW="${WORKFLOW:-create-vm.yml}"
REF="${REF:-main}"
AD_COUNT="${AD_COUNT:-3}"

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
AD_COUNT=$(printf '%q' "$AD_COUNT")
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

STATE_FILE = "/opt/github-oci-trigger/ad_index"


def log(message: str) -> None:
    print(f"{datetime.now(timezone.utc).isoformat()} {message}", flush=True)


def request(method: str, url: str, token: str, body=None):
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
    except Exception as exc:
        log(f"request_error type={type(exc).__name__}")
        return 0, None


def get_ad_count() -> int:
    raw_value = os.environ.get("AD_COUNT", "3").strip()
    try:
        return max(1, int(raw_value))
    except ValueError:
        log(f"invalid_ad_count value={raw_value!r}; using 3")
        return 3


def read_ad_index(ad_count: int) -> int:
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as handle:
            return int(handle.read().strip()) % ad_count
    except (FileNotFoundError, ValueError, OSError):
        return 0


def write_next_ad_index(current_index: int, ad_count: int) -> None:
    next_index = (current_index + 1) % ad_count
    tmp_path = f"{STATE_FILE}.tmp"
    with open(tmp_path, "w", encoding="utf-8") as handle:
        handle.write(f"{next_index}\n")
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, STATE_FILE)


def main() -> int:
    token = os.environ["GITHUB_TOKEN"].strip()
    repo = os.environ.get("REPO", "dlq4455/oci-free-arm-instance")
    workflow = os.environ.get("WORKFLOW", "create-vm.yml")
    ref = os.environ.get("REF", "main")
    ad_count = get_ad_count()
    ad_index = read_ad_index(ad_count)
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

    status, _ = request("POST", f"{base}/dispatches", token, {"ref": ref, "inputs": {"ad_index": str(ad_index)}})
    if status == 204:
        write_next_ad_index(ad_index, ad_count)
        log(f"dispatched repo={repo} workflow={workflow} ref={ref} ad_index={ad_index} ad_count={ad_count}")
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
find "$LOG_DIR" -type f -name '*.log*' -mtime +10 -delete

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

cat > /etc/logrotate.d/github-oci-trigger <<'EOF'
/var/log/github-oci-trigger/*.log {
    size 5M
    rotate 10
    maxage 10
    compress
    missingok
    notifempty
    copytruncate
}
EOF

systemctl daemon-reload
systemctl enable github-oci-trigger.timer >/dev/null
systemctl list-timers --all github-oci-trigger.timer --no-pager
