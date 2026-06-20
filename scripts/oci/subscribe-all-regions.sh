#!/usr/bin/env bash
set -Eeuo pipefail

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "$name is required" >&2
    exit 1
  fi
}

oci_json() {
  local output
  if ! output=$(oci --no-retry "$@" --output json 2>&1); then
    echo "$output" >&2
    return 1
  fi
  printf '%s\n' "$output"
}

setup_oci_config() {
  mkdir -p ~/.oci
  printf '%s\n' "$OCI_CLI_KEY_CONTENT" > ~/.oci/oci_api_key.pem
  chmod 600 ~/.oci/oci_api_key.pem

  {
    echo "[DEFAULT]"
    echo "user=$OCI_CLI_USER"
    echo "tenancy=$OCI_CLI_TENANCY"
    echo "fingerprint=$OCI_CLI_FINGERPRINT"
    echo "key_file=~/.oci/oci_api_key.pem"
    echo "region=$OCI_CLI_REGION"
  } > ~/.oci/config
}

main() {
  require_env OCI_CLI_REGION
  require_env OCI_CLI_USER
  require_env OCI_CLI_TENANCY
  require_env OCI_CLI_FINGERPRINT
  require_env OCI_CLI_KEY_CONTENT

  export SUPPRESS_LABEL_WARNING=True
  setup_oci_config

  local regions_json
  local subscriptions_json
  local current_realm
  local existing_keys
  local attempted=0
  local subscribed=0
  local failed=0

  regions_json=$(oci_json iam region list --all)
  subscriptions_json=$(oci_json iam region-subscription list --tenancy-id "$OCI_CLI_TENANCY" --all)

  current_realm=$(jq -r --arg region "$OCI_CLI_REGION" '.data[] | select(.name == $region) | ."realm-key" // empty' <<< "$regions_json")
  if [[ -z "$current_realm" || "$current_realm" == "null" ]]; then
    echo "Could not determine realm for current region: $OCI_CLI_REGION" >&2
    exit 1
  fi

  existing_keys="$(jq -r '.data[] | ."region-key"' <<< "$subscriptions_json" | sort -u)"

  echo "Current region: $OCI_CLI_REGION"
  echo "Current realm: $current_realm"
  echo "Existing subscriptions:"
  jq -r '.data[] | "  - \(.["region-name"]) (\(.["region-key"])) status=\(.status) home=\(.["is-home-region"])"' <<< "$subscriptions_json"
  echo "Attempting to subscribe every un-subscribed region in realm $current_realm serially."

  while IFS=$'\t' read -r region_key region_name; do
    [[ -z "$region_key" || -z "$region_name" ]] && continue

    if grep -qx "$region_key" <<< "$existing_keys"; then
      echo "Already subscribed: $region_name ($region_key)"
      continue
    fi

    attempted=$((attempted + 1))
    echo "Subscribing: $region_name ($region_key)"

    set +e
    output=$(oci --no-retry iam region-subscription create \
      --tenancy-id "$OCI_CLI_TENANCY" \
      --region-key "$region_key" \
      --output json 2>&1)
    status=$?
    set -e

    if [[ "$status" -eq 0 ]]; then
      subscribed=$((subscribed + 1))
      echo "Subscribed or activation started: $region_name ($region_key)"
      echo "$output" | jq -r '.data | "  status=\(.status) region=\(.["region-name"]) key=\(.["region-key"])"' 2>/dev/null || true
    else
      failed=$((failed + 1))
      echo "Subscribe failed: $region_name ($region_key)"
      echo "$output"
    fi
  done < <(
    jq -r --arg realm "$current_realm" '.data[]
      | select(."realm-key" == $realm)
      | [.key, .name]
      | @tsv' <<< "$regions_json"
  )

  echo "Summary: attempted=$attempted subscribed_or_started=$subscribed failed=$failed"

  echo "Current subscriptions after attempts:"
  if subscriptions_json=$(oci_json iam region-subscription list --tenancy-id "$OCI_CLI_TENANCY" --all); then
    jq -r '.data[] | "  - \(.["region-name"]) (\(.["region-key"])) status=\(.status) home=\(.["is-home-region"])"' <<< "$subscriptions_json"
  fi

  if [[ "$failed" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
