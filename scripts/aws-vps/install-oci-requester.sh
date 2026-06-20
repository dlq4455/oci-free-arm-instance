#!/usr/bin/env bash
set -Eeuo pipefail

PACKAGE_DIR="${1:-/tmp/oci-vm-requester-package}"
BASE_DIR="/opt/oci-vm-requester"
LOG_DIR="/var/log/oci-vm-requester"
LOCK_DIR="/var/lock"

if [[ $EUID -ne 0 ]]; then
  echo "install script must run as root" >&2
  exit 1
fi

for required in config.env oci_api_key.pem ssh_authorized_key.pub; do
  if [[ ! -f "$PACKAGE_DIR/$required" ]]; then
    echo "missing package file: $required" >&2
    exit 1
  fi
done

dnf install -y python3 python3-pip jq curl util-linux >/dev/null
python3 -m pip install --upgrade --user oci-cli >/dev/null

install -d -m 700 -o root -g root "$BASE_DIR"
install -d -m 755 -o root -g root "$LOG_DIR"
install -d -m 755 -o root -g root "$LOCK_DIR"
install -m 600 -o root -g root "$PACKAGE_DIR/config.env" "$BASE_DIR/config.env"
install -m 600 -o root -g root "$PACKAGE_DIR/oci_api_key.pem" "$BASE_DIR/oci_api_key.pem"
install -m 644 -o root -g root "$PACKAGE_DIR/ssh_authorized_key.pub" "$BASE_DIR/ssh_authorized_key.pub"

# shellcheck disable=SC1091
source "$BASE_DIR/config.env"

cat > "$BASE_DIR/oci_config" <<EOF
[DEFAULT]
user=${OCI_CLI_USER}
tenancy=${OCI_CLI_TENANCY}
fingerprint=${OCI_CLI_FINGERPRINT}
key_file=${BASE_DIR}/oci_api_key.pem
region=${OCI_CLI_REGION}
EOF
chmod 600 "$BASE_DIR/oci_config"
chown root:root "$BASE_DIR/oci_config"

cat > "$BASE_DIR/cloud-init.yaml" <<'EOF'
#cloud-config
package_update: true
runcmd:
  - curl -fsSL https://gitlab.com/spiritysdx/Oracle-server-keep-alive-script/-/raw/main/oalive.sh -o /root/oalive.sh
  - chmod +x /root/oalive.sh
  - printf '1\nn\n1\ny\ny\n2\nn\n' | bash /root/oalive.sh
EOF
chmod 644 "$BASE_DIR/cloud-init.yaml"
chown root:root "$BASE_DIR/cloud-init.yaml"

cat > "$BASE_DIR/send_mail.py" <<'PY'
#!/usr/bin/env python3
import os
import smtplib
import sys
from email.message import EmailMessage


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: send_mail.py SUBJECT", file=sys.stderr)
        return 2

    username = os.environ["MAIL_USERNAME"]
    password = os.environ["MAIL_PASSWORD"]
    mail_to = os.environ.get("MAIL_TO", username)
    subject = sys.argv[1]
    body = sys.stdin.read()

    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = f"OCI A1 Notifier <{username}>"
    msg["To"] = mail_to
    msg.set_content(body)

    with smtplib.SMTP_SSL("smtp.gmail.com", 465, timeout=30) as smtp:
        smtp.login(username, password)
        smtp.send_message(msg)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
chmod 700 "$BASE_DIR/send_mail.py"
chown root:root "$BASE_DIR/send_mail.py"

cat > "$BASE_DIR/runner.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/opt/oci-vm-requester"
LOG_DIR="/var/log/oci-vm-requester"
LOG_FILE="$LOG_DIR/requester.log"
LOCK_FILE="/var/lock/oci-vm-requester.lock"
TEST_NOTIFY=false

if [[ "${1:-}" == "--test-notify" ]]; then
  TEST_NOTIFY=true
fi

mkdir -p "$LOG_DIR"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "$(date -Is) another requester run is active" >> "$LOG_FILE"
  exit 0
fi

{
  echo "===== $(date -Is) run start test_notify=${TEST_NOTIFY} ====="
  if [[ -f "$BASE_DIR/succeeded" ]]; then
    echo "success marker exists; skipping"
    exit 0
  fi

  # shellcheck disable=SC1091
  source "$BASE_DIR/config.env"
  export OCI_CLI_CONFIG_FILE="$BASE_DIR/oci_config"
  export MAIL_USERNAME MAIL_PASSWORD MAIL_TO

  OCI_BIN="/root/.local/bin/oci"
  if [[ ! -x "$OCI_BIN" ]]; then
    OCI_BIN="$(command -v oci || true)"
  fi
  if [[ -z "$OCI_BIN" || ! -x "$OCI_BIN" ]]; then
    echo "oci CLI not found"
    exit 2
  fi

  all_output=""
  success=false
  instance_id=""
  IFS=', ' read -r -a availability_domains <<< "$AD_NAMES"

  for ad_name in "${availability_domains[@]}"; do
    [[ -z "$ad_name" ]] && continue
    echo "Trying availability domain: $ad_name"
    oci_output=$("$OCI_BIN" compute instance launch \
      --compartment-id "$COMPARTMENT_ID" \
      --availability-domain "$ad_name" \
      --shape "VM.Standard.A1.Flex" \
      --shape-config '{"ocpus":2,"memoryInGBs":12}' \
      --subnet-id "$SUBNET_ID" \
      --image-id "$IMAGE_ID" \
      --ssh-authorized-keys-file "$BASE_DIR/ssh_authorized_key.pub" \
      --user-data-file "$BASE_DIR/cloud-init.yaml" \
      --assign-public-ip true \
      --display-name "oracle-a1-free-2c12g" \
      --boot-volume-size-in-gbs 50 2>&1 || true)

    all_output="${all_output}"$'\n'"===== ${ad_name} ====="$'\n'"${oci_output}"$'\n'
    echo "$oci_output"

    if grep -q '"lifecycle-state": "PROVISIONING"' <<< "$oci_output"; then
      success=true
      instance_id="$(jq -r '.data.id // empty' <<< "$oci_output" 2>/dev/null || true)"
      break
    fi
  done

  if [[ "$success" == true ]]; then
    touch "$BASE_DIR/succeeded"
    subject="OCI A1 VM created: oracle-a1-free-2c12g"
    body=$(cat <<EOF
Oracle A1 VM creation succeeded.

Shape: VM.Standard.A1.Flex
OCPU/RAM: 2 OCPU / 12 GB
Boot volume: 50 GB
Region: ${OCI_CLI_REGION}
Instance OCID: ${instance_id:-unknown}
SSH private key on your PC: F:\dev\test\oracle_key

The AWS VPS requester timer has been disabled after success.
EOF
)
    printf '%s\n' "$body" | "$BASE_DIR/send_mail.py" "$subject" || true
    systemctl disable --now oci-vm-requester.timer >/dev/null 2>&1 || true
    echo "success; timer disabled"
    exit 0
  fi

  echo "No capacity or another OCI error prevented VM creation."
  if [[ "$TEST_NOTIFY" == true ]]; then
    subject="OCI requester test: no VM created"
    body=$(cat <<EOF
Initial AWS VPS requester test completed.

Result: no Oracle VM was created in this test run.
This is expected when OCI returns out-of-capacity.

After this initial test, scheduled failure runs will not send email.
Only a successful VM creation will send email.

Last output:
${all_output: -6000}
EOF
)
    printf '%s\n' "$body" | "$BASE_DIR/send_mail.py" "$subject" || true
    echo "test notification sent"
  fi
  exit 0
} >> "$LOG_FILE" 2>&1
SH
chmod 700 "$BASE_DIR/runner.sh"
chown root:root "$BASE_DIR/runner.sh"

cat > /etc/systemd/system/oci-vm-requester.service <<'EOF'
[Unit]
Description=Try to create Oracle Cloud A1 Free VM
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/oci-vm-requester/runner.sh
EOF

cat > /etc/systemd/system/oci-vm-requester.timer <<'EOF'
[Unit]
Description=Run Oracle Cloud A1 Free VM requester every 10 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
AccuracySec=30s
Persistent=false
Unit=oci-vm-requester.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now oci-vm-requester.timer >/dev/null
systemctl list-timers --all oci-vm-requester.timer
