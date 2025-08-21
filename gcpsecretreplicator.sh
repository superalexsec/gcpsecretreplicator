#!/usr/bin/env bash
# Replicate all Secret Manager secrets from one GCP project to another
# - Preserves replication policy and labels
# - Copies latest enabled version (or all enabled versions if configured)
# - Never writes secret data to disk; streams payload via stdin
# - Logs status/errors to a file and uses colored console output

set -o pipefail

# ------------------------- Configurable defaults -------------------------
COPY_ALL_VERSIONS="${COPY_ALL_VERSIONS:-false}"  # set to "true" to copy all enabled versions
# ------------------------------------------------------------------------

if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud is required on PATH"; exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required on PATH"; exit 1
fi

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <SOURCE_PROJECT_ID> <DEST_PROJECT_ID>"
  exit 1
fi

SRC_PROJECT="$1"
DST_PROJECT="$2"

# Colors
if [[ -t 1 ]]; then
  RED="$(printf '\033[31m')" ; GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')" ; BLUE="$(printf '\033[34m')"
  BOLD="$(printf '\033[1m')" ; RESET="$(printf '\033[0m')"
else
  RED="" ; GREEN="" ; YELLOW="" ; BLUE="" ; BOLD="" ; RESET=""
fi

# Logging
TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="replicate-secrets_${SRC_PROJECT}_to_${DST_PROJECT}_${TS}.log"

log() {
  # $1 = level, $2 = message
  local level="$1"; shift
  local msg="$*"
  local tstamp
  tstamp="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$tstamp] [$level] $msg" | tee -a "$LOG_FILE" >/dev/null
}

say() {
  # colored console message (also log INFO)
  local color="$1"; shift
  local msg="$*"
  echo -e "${color}${msg}${RESET}"
  log INFO "$msg"
}

warn() { say "$YELLOW" "⚠️  $*"; }
info() { say "$BLUE" "ℹ️  $*"; }
ok()   { say "$GREEN" "✅ $*"; }
fail() { say "$RED"   "❌ $*"; }

# Verify access to projects
if ! gcloud --quiet projects describe "$SRC_PROJECT" >/dev/null 2>&1; then
  fail "Cannot access source project: $SRC_PROJECT"
  exit 1
fi
if ! gcloud --quiet projects describe "$DST_PROJECT" >/dev/null 2>&1; then
  fail "Cannot access destination project: $DST_PROJECT"
  exit 1
fi

info "Log file: ${BOLD}$LOG_FILE${RESET}"
info "Source: ${BOLD}$SRC_PROJECT${RESET}  →  Destination: ${BOLD}$DST_PROJECT${RESET}"
info "Copy all enabled versions: ${BOLD}$COPY_ALL_VERSIONS${RESET}"

# Helper: create dest secret if missing, preserving replication policy and labels
ensure_dest_secret() {
  local secret="$1"

  if gcloud secrets describe "$secret" --project="$DST_PROJECT" --format="none" >/dev/null 2>&1; then
    return 0
  fi

  # Describe source to fetch replication policy and labels
  local meta
  if ! meta="$(gcloud secrets describe "$secret" --project="$SRC_PROJECT" --format=json 2>>"$LOG_FILE")"; then
    log ERROR "Failed to describe source secret '$secret'"
    return 1
  fi

  local repl_flag=""
  if echo "$meta" | jq -e '.replication.automatic' >/dev/null 2>&1; then
    repl_flag="--replication-policy=automatic"
  else
    # gather user-managed locations
    local locs
    locs="$(echo "$meta" | jq -r '.replication.userManaged.replicas[].location' | paste -sd, -)"
    if [[ -z "$locs" || "$locs" == "null" ]]; then
      log ERROR "Secret '$secret' has unknown replication config"
      return 1
    fi
    repl_flag="--replication-policy=user-managed --locations=$locs"
  fi

  # Labels
  local labels
  labels="$(echo "$meta" | jq -r 'if (.labels // {} | length) > 0
                                  then (.labels | to_entries | map("\(.key)=\(.value)") | join(","))
                                  else "" end')"
  local label_flag=()
  if [[ -n "$labels" && "$labels" != "null" ]]; then
    label_flag=(--labels "$labels")
  fi

  if gcloud secrets create "$secret" --project="$DST_PROJECT" $repl_flag "${label_flag[@]}" \
        --format="none" >>"$LOG_FILE" 2>&1; then
    ok "Created destination secret '${BOLD}$secret${RESET}' (replication + labels preserved)"
    return 0
  else
    log ERROR "Failed to create destination secret '$secret' (see log)"
    return 1
  fi
}

# Helper: copy a single version number (N) from SRC to DST (streaming; no disk writes)
copy_one_version() {
  local secret="$1"
  local ver="$2" # numeric or 'latest'

  # Access payload from source and immediately stream to destination add
  # No intermediate files; entirely via stdin/stdout pipe
  if gcloud secrets versions access "$ver" --secret="$secret" --project="$SRC_PROJECT" \
      2>>"$LOG_FILE" | \
     gcloud secrets versions add "$secret" --project="$DST_PROJECT" --data-file=- \
      --format="none" >>"$LOG_FILE" 2>&1; then
    return 0
  else
    return 1
  fi
}

# Enumerate all secrets in source
mapfile -t SECRETS < <(gcloud secrets list --project="$SRC_PROJECT" --format="value(name)")
if [[ ${#SECRETS[@]} -eq 0 ]]; then
  warn "No secrets found in source project '$SRC_PROJECT'. Nothing to do."
  exit 0
fi

TOTAL=${#SECRETS[@]}
info "Found ${BOLD}$TOTAL${RESET} secrets in source."

SUCCESS=0
FAILED=0

for secret in "${SECRETS[@]}"; do
  echo
  info "Processing secret: ${BOLD}$secret${RESET}"

  # Ensure destination secret exists (create if needed)
  if ! ensure_dest_secret "$secret"; then
    fail "Skipping '$secret' due to create/describe error."
    log ERROR "SECRET $secret : create/describe error; skipped"
    ((FAILED++))
    continue
  fi

  if [[ "$COPY_ALL_VERSIONS" == "true" ]]; then
    # Copy all ENABLED versions in ascending creation time
    mapfile -t VERS < <(gcloud secrets versions list "$secret" --project="$SRC_PROJECT" \
                        --filter="state=ENABLED" --sort-by=createTime --format="value(name)")
    if [[ ${#VERS[@]} -eq 0 ]]; then
      warn "No ENABLED versions to copy for '$secret'."
      log INFO "SECRET $secret : no enabled versions"
      ((SUCCESS++))
      continue
    fi

    OKCNT=0; ERCNT=0
    for full in "${VERS[@]}"; do
      ver="${full##*/}"  # extract numeric from resource path
      if copy_one_version "$secret" "$ver"; then
        ok "Added version ${BOLD}#$ver${RESET} to destination '$secret'"
        log INFO "SECRET $secret : version $ver copied"
        ((OKCNT++))
      else
        fail "Failed to copy version #$ver for '$secret' (see log)"
        log ERROR "SECRET $secret : version $ver failed"
        ((ERCNT++))
      fi
    done

    if [[ $ERCNT -eq 0 ]]; then
      ok "Completed '$secret' (${OKCNT} versions)"
      ((SUCCESS++))
      log INFO "SECRET $secret : SUCCESS ($OKCNT versions)"
    else
      warn "Completed '$secret' with ${ERCNT} errors (${OKCNT} succeeded)"
      ((FAILED++))
      log ERROR "SECRET $secret : PARTIAL ($OKCNT ok, $ERCNT failed)"
    fi
  else
    # Copy only the LATEST ENABLED version
    latest_full="$(gcloud secrets versions list "$secret" --project="$SRC_PROJECT" \
                   --filter="state=ENABLED" --sort-by=~createTime --limit=1 --format="value(name)")"
    if [[ -z "$latest_full" ]]; then
      warn "No ENABLED versions to copy for '$secret'."
      log INFO "SECRET $secret : no enabled versions"
      ((SUCCESS++))
      continue
    fi
    latest_ver="${latest_full##*/}"

    if copy_one_version "$secret" "$latest_ver"; then
      ok "Copied latest enabled version ${BOLD}#$latest_ver${RESET} for '$secret'"
      ((SUCCESS++))
      log INFO "SECRET $secret : SUCCESS (latest #$latest_ver)"
    else
      fail "Failed to copy latest version for '$secret' (see log)"
      ((FAILED++))
      log ERROR "SECRET $secret : FAILED (latest #$latest_ver)"
    fi
  fi
done

echo
info "Done. Secrets processed: ${BOLD}$TOTAL${RESET}  ✓ ${GREEN}$SUCCESS${RESET}  ✗ ${RED}$FAILED${RESET}"
info "Detailed log: ${BOLD}$LOG_FILE${RESET}"

# Exit non-zero if any failures occurred
if [[ $FAILED -gt 0 ]]; then
  exit 2
fi

