#!/usr/bin/env bash
# =============================================================================
# Precision Patcher - orchestrator.sh
# Version: 1.0.0
# Description: Fault-tolerant, surgical code modification system.
# Usage: ./orchestrator.sh [--dry-run] [--help]
# =============================================================================

set -euo pipefail

# --- Resolve script directory (so relative paths always work) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- File paths ---
CONF_FILE="${SCRIPT_DIR}/patcher.conf"
TARGET_LIST="${SCRIPT_DIR}/target_files.list"
PAYLOAD_FILE="${SCRIPT_DIR}/payload.txt"
LOG_FILE="${SCRIPT_DIR}/patch_history.log"

# --- Runtime flags ---
DRY_RUN=false
DRYRUN_DIR="/tmp/dryrun"

# =============================================================================
# HELP
# =============================================================================
show_help() {
  cat <<EOF

╔══════════════════════════════════════════════════════════════════╗
║                  PRECISION PATCHER - HELP                        ║
╚══════════════════════════════════════════════════════════════════╝

USAGE:
  ./orchestrator.sh [OPTIONS]

OPTIONS:
  --dry-run     Simulate all operations. Output goes to /tmp/dryrun/
                instead of overwriting live files.
  --help        Show this help message.

REQUIRED FILES (must exist in the same directory as this script):
  patcher.conf       Configuration file (key=value format)
  target_files.list  One absolute or relative file path per line
  payload.txt        Required only when ACTION=insert_before or insert_after

CONFIGURATION (patcher.conf):

  ACTION
    replace_inline   → Find and replace a string using sed
    insert_before    → Inject payload.txt content BEFORE the anchor line
    insert_after     → Inject payload.txt content AFTER the anchor line

  MATCH_MODE
    exact            → Special characters in SEARCH_TARGET are auto-escaped
    regex            → SEARCH_TARGET is treated as a raw regular expression

  REPLACE_OCCURRENCE
    first            → Only the first match in each file is patched
    all              → Every match in the file is patched

  SEARCH_TARGET="your anchor string or pattern"
  REPLACE_WITH="replacement text"   (only used when ACTION=replace_inline)

EXAMPLES:

  # Simple string swap
  ACTION=replace_inline
  MATCH_MODE=exact
  REPLACE_OCCURRENCE=all
  SEARCH_TARGET="old_value"
  REPLACE_WITH="new_value"

  # Multi-line code injection
  ACTION=insert_before
  MATCH_MODE=exact
  REPLACE_OCCURRENCE=first
  SEARCH_TARGET="return true;"
  (REPLACE_WITH is ignored — content is read from payload.txt)

LOG FILE:
  All results are recorded in: patch_history.log

EOF
  exit 0
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
for arg in "$@"; do
  case "$arg" in
    --help)    show_help ;;
    --dry-run) DRY_RUN=true ;;
    *)
      echo "[ERROR] Unknown argument: $arg"
      echo "       Run './orchestrator.sh --help' for usage."
      exit 1
      ;;
  esac
done

# =============================================================================
# LOGGING
# =============================================================================
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"

log() {
  local level="$1"
  local message="$2"
  local file="${3:-}"
  local entry

  if [[ -n "$file" ]]; then
    entry="[${TIMESTAMP}] [${level}] FILE: ${file} | ${message}"
  else
    entry="[${TIMESTAMP}] [${level}] ${message}"
  fi

  echo "$entry" | tee -a "$LOG_FILE"
}

log_separator() {
  echo "--------------------------------------------------------------------------------" >> "$LOG_FILE"
}

# =============================================================================
# PREFLIGHT CHECKS
# =============================================================================
preflight_checks() {
  log "INFO" "Starting Precision Patcher | DRY_RUN=${DRY_RUN}"
  log_separator

  # Check conf file
  if [[ ! -f "$CONF_FILE" ]]; then
    log "FATAL" "patcher.conf not found at: ${CONF_FILE}"
    exit 1
  fi

  # Check target list
  if [[ ! -f "$TARGET_LIST" ]]; then
    log "FATAL" "target_files.list not found at: ${TARGET_LIST}"
    exit 1
  fi

  # Source the conf file safely
  # shellcheck disable=SC1090
  source "$CONF_FILE"

  # Validate required conf variables
  for var in ACTION MATCH_MODE REPLACE_OCCURRENCE SEARCH_TARGET; do
    if [[ -z "${!var:-}" ]]; then
      log "FATAL" "Missing required variable '${var}' in patcher.conf"
      exit 1
    fi
  done

  # Validate ACTION value
  if [[ "$ACTION" != "replace_inline" && "$ACTION" != "insert_before" && "$ACTION" != "insert_after" ]]; then
    log "FATAL" "Invalid ACTION '${ACTION}'. Must be: replace_inline, insert_before, insert_after"
    exit 1
  fi

  # For replace_inline, REPLACE_WITH must exist
  if [[ "$ACTION" == "replace_inline" && -z "${REPLACE_WITH:-}" ]]; then
    log "FATAL" "ACTION=replace_inline requires REPLACE_WITH to be set in patcher.conf"
    exit 1
  fi

  # For injection modes, payload.txt must exist
  if [[ "$ACTION" == "insert_before" || "$ACTION" == "insert_after" ]]; then
    if [[ ! -f "$PAYLOAD_FILE" ]]; then
      log "FATAL" "payload.txt not found. Required when ACTION=${ACTION}"
      exit 1
    fi
  fi

  # Create dryrun dir if needed
  if [[ "$DRY_RUN" == true ]]; then
    mkdir -p "$DRYRUN_DIR"
    log "INFO" "DRY RUN mode active. Output will go to: ${DRYRUN_DIR}"
  fi

  log "INFO" "Config loaded | ACTION=${ACTION} | MATCH_MODE=${MATCH_MODE} | REPLACE_OCCURRENCE=${REPLACE_OCCURRENCE}"
  log_separator
}

# =============================================================================
# UTILITY: Escape string for use in sed
# =============================================================================
escape_for_sed() {
  # Escapes: . * ^ $ [ ] \ / & for safe sed literal matching
  printf '%s' "$1" | sed 's/[.[\*^$()+?{}|\\]/\\&/g' | sed 's|/|\\/|g'
}

# =============================================================================
# PATCH FUNCTION: replace_inline (sed)
# =============================================================================
apply_replace_inline() {
  local tmpfile="$1"

  local search replace
  if [[ "$MATCH_MODE" == "exact" ]]; then
    search="$(escape_for_sed "$SEARCH_TARGET")"
    replace="$(escape_for_sed "$REPLACE_WITH")"
  else
    search="$SEARCH_TARGET"
    replace="$REPLACE_WITH"
  fi

  if [[ "$REPLACE_OCCURRENCE" == "all" ]]; then
    sed -i "s/${search}/${replace}/g" "$tmpfile"
  else
    sed -i "s/${search}/${replace}/" "$tmpfile"
  fi
}

# =============================================================================
# PATCH FUNCTION: insert_before / insert_after (awk)
# =============================================================================
apply_injection() {
  local tmpfile="$1"
  local mode="$2"   # insert_before or insert_after

  local search
  if [[ "$MATCH_MODE" == "exact" ]]; then
    # For awk, escape special regex characters
    search="$(printf '%s' "$SEARCH_TARGET" | sed 's/[[\.*^$()+?{}|\\]/\\&/g')"
  else
    search="$SEARCH_TARGET"
  fi

  local awk_script
  if [[ "$mode" == "insert_before" ]]; then
    if [[ "$REPLACE_OCCURRENCE" == "first" ]]; then
      awk_script='
        !done && /'"$search"'/ {
          system("cat '"$PAYLOAD_FILE"'")
          done=1
        }
        { print }
      '
    else
      awk_script='
        /'"$search"'/ {
          system("cat '"$PAYLOAD_FILE"'")
        }
        { print }
      '
    fi
  else
    # insert_after
    if [[ "$REPLACE_OCCURRENCE" == "first" ]]; then
      awk_script='
        { print }
        !done && /'"$search"'/ {
          system("cat '"$PAYLOAD_FILE"'")
          done=1
        }
      '
    else
      awk_script='
        { print }
        /'"$search"'/ {
          system("cat '"$PAYLOAD_FILE"'")
        }
      '
    fi
  fi

  local result
  result="$(awk "$awk_script" "$tmpfile")"
  echo "$result" > "$tmpfile"
}

# =============================================================================
# PROCESS A SINGLE FILE
# =============================================================================
process_file() {
  local filepath="$1"
  local tmpfile="/tmp/temp_patch_${TIMESTAMP}_$$"

  # --- Existence check ---
  if [[ ! -f "$filepath" ]]; then
    log "FAILED" "File does not exist" "$filepath"
    return
  fi

  # --- Permission check ---
  if [[ ! -w "$filepath" ]]; then
    log "FAILED" "No write permission" "$filepath"
    return
  fi

  # --- Anchor check (verify SEARCH_TARGET exists in file) ---
  if ! grep -qF -- "$SEARCH_TARGET" "$filepath" 2>/dev/null; then
    log "FAILED" "SEARCH_TARGET not found in file" "$filepath"
    return
  fi

  # --- Copy to temp workspace ---
  cp "$filepath" "$tmpfile"

  # --- Apply patch based on ACTION ---
  case "$ACTION" in
    replace_inline)
      if ! apply_replace_inline "$tmpfile"; then
        log "FAILED" "sed operation failed" "$filepath"
        rm -f "$tmpfile"
        return
      fi
      ;;
    insert_before|insert_after)
      if ! apply_injection "$tmpfile" "$ACTION"; then
        log "FAILED" "awk injection failed" "$filepath"
        rm -f "$tmpfile"
        return
      fi
      ;;
  esac

  # --- Dry run: copy to /tmp/dryrun/ ---
  if [[ "$DRY_RUN" == true ]]; then
    local dryrun_dest="${DRYRUN_DIR}/$(basename "$filepath").dryrun"
    cp "$tmpfile" "$dryrun_dest"
    log "DRY-RUN" "Simulated patch written to ${dryrun_dest}" "$filepath"
    rm -f "$tmpfile"
    return
  fi

  # --- Create timestamped backup ---
  local backup_ts
  backup_ts="$(date '+%Y%m%d_%H%M')"
  local backup_path="${filepath}.${backup_ts}.bak"

  if ! cp "$filepath" "$backup_path"; then
    log "FAILED" "Could not create backup at ${backup_path}" "$filepath"
    rm -f "$tmpfile"
    return
  fi

  # --- Overwrite live file ---
  if ! mv "$tmpfile" "$filepath"; then
    log "FAILED" "Could not move patched file to destination" "$filepath"
    rm -f "$tmpfile"
    return
  fi

  log "SUCCESS" "Patched successfully | Backup: ${backup_path}" "$filepath"
}

# =============================================================================
# MAIN LOOP
# =============================================================================
main() {
  preflight_checks

  local total=0
  local success=0
  local failed=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip empty lines and comments
    [[ -z "$line" || "$line" == \#* ]] && continue

    total=$((total + 1))
    process_file "$line"

    # Count outcomes from last log entry
    if grep -q "\[SUCCESS\]\|DRY-RUN" "$LOG_FILE" 2>/dev/null; then
      success=$((success + 1))
    fi

  done < "$TARGET_LIST"

  failed=$((total - success))

  log_separator
  log "SUMMARY" "Total=${total} | Success=${success} | Failed=${failed}"
  log_separator
}

main "$@"
