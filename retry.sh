#!/usr/bin/env bash
# Tries to create ONE Always Free Ampere server (2 OCPU / 12 GB / 150 GB disk)
# in Oracle Cloud, Chicago. Rotates through all availability domains.
# Safe by design:
#   - only ever requests VM.Standard.A1.Flex with 2 OCPU / 12 GB (Always Free limit)
#   - stops if ANY A1 server already exists, so it can never create a second one
#   - stops if total disk would go over the free 200 GB
set -uo pipefail

NAME="main-server"
SHAPE="VM.Standard.A1.Flex"
OCPUS=2
MEMORY_GB=12
BOOT_GB=150
FREE_DISK_GB=200
SUBNET_NAME="public subnet-main-vcn"
C="${OCI_TENANCY_OCID:?missing OCI_TENANCY_OCID}"   # root compartment = tenancy
KEY_FILE="${SSH_PUBLIC_KEY_FILE:?missing SSH_PUBLIC_KEY_FILE}"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# 1) Already have an A1 server? Then we are done - never create a second one.
existing=$(oci compute instance list -c "$C" --all \
  --query "data[?shape=='$SHAPE' && \"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'].\"display-name\"" \
  --raw-output 2>/dev/null)
if [[ -n "$existing" && "$existing" != "[]" && "$existing" != "null" ]]; then
  log "An Ampere server already exists: $existing - nothing to do."
  echo "result=exists" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

# 2) Disk budget check (boot + block volumes must stay within free 200 GB).
used_boot=$(oci bv boot-volume list -c "$C" --all \
  --query "sum(data[?\"lifecycle-state\"!='TERMINATED'].\"size-in-gbs\")" --raw-output 2>/dev/null || echo 0)
used_block=$(oci bv volume list -c "$C" --all \
  --query "sum(data[?\"lifecycle-state\"!='TERMINATED'].\"size-in-gbs\")" --raw-output 2>/dev/null || echo 0)
toint() { local v="${1%%.*}"; [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0; }
used=$(( $(toint "$used_boot") + $(toint "$used_block") ))
if (( used + BOOT_GB > FREE_DISK_GB )); then
  log "Disk check failed: ${used} GB already used + ${BOOT_GB} GB > ${FREE_DISK_GB} GB free. Stopping."
  exit 1
fi

# 3) Look up subnet, latest Ubuntu 24.04 ARM image, and availability domains.
SUBNET=$(oci network subnet list -c "$C" --display-name "$SUBNET_NAME" \
  --query 'data[0].id' --raw-output)
IMAGE=$(oci compute image list -c "$C" --operating-system "Canonical Ubuntu" \
  --operating-system-version "24.04" --shape "$SHAPE" \
  --sort-by TIMECREATED --sort-order DESC \
  --query 'data[?!contains("display-name", `Minimal`)] | [0].id' --raw-output)
mapfile -t ADS < <(oci iam availability-domain list -c "$C" \
  --query 'join(`\n`, data[].name)' --raw-output | sed '/^$/d')

[[ -z "$SUBNET" || "$SUBNET" == "null" ]] && { log "Subnet '$SUBNET_NAME' not found."; exit 1; }
[[ -z "$IMAGE"  || "$IMAGE"  == "null" ]] && { log "Ubuntu 24.04 ARM image not found."; exit 1; }
log "Subnet: $SUBNET"
log "Image:  $IMAGE"
log "ADs:    ${ADS[*]}"

# 4) Try each availability domain once.
for AD in "${ADS[@]}"; do
  log "Trying $AD ..."
  out=$(oci compute instance launch \
    --no-retry -c "$C" \
    --availability-domain "$AD" \
    --display-name "$NAME" \
    --shape "$SHAPE" \
    --shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY_GB}" \
    --image-id "$IMAGE" \
    --boot-volume-size-in-gbs "$BOOT_GB" \
    --subnet-id "$SUBNET" \
    --assign-public-ip true \
    --ssh-authorized-keys-file "$KEY_FILE" 2>&1)
  rc=$?

  if [[ $rc -eq 0 ]]; then
    log "SUCCESS - server created in $AD"
    echo "$out" | grep -E '"(id|lifecycle-state|display-name)"' | head -n 5
    echo "result=created" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 0
  fi

  if grep -qiE "out of host capacity|out of capacity|InternalError" <<<"$out"; then
    log "No capacity in $AD."
  elif grep -qiE "TooManyRequests" <<<"$out"; then
    log "Rate limited by Oracle - will try again next run."
    exit 0
  elif grep -qiE "LimitExceeded|QuotaExceeded" <<<"$out"; then
    log "Free-tier limit reached - stopping (nothing will be created)."
    echo "$out" | tail -n 20
    exit 1
  else
    log "Unexpected error in $AD:"
    echo "$out" | tail -n 20
  fi
  sleep 5
done

log "No capacity anywhere this run. Will retry on next schedule."
exit 0
