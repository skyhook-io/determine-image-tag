#!/usr/bin/env bash
#
# Generate an image tag from service / branch / date and an optional counter.
#
# Reads inputs from env vars (same names the GitHub Action passes):
#   SERVICE_NAME, CUSTOM_TAG, TAG_FORMAT, MAX_LENGTH, INCLUDE_COUNTER,
#   BRANCH_REF, PR_REF, BRANCH_SEP
#
# Test-only overrides:
#   DATE_OVERRIDE         use this string instead of `date +%Y-%m-%d`
#   COMMIT_HASH_OVERRIDE  use this instead of `git rev-parse HEAD`
#   HIGHEST_OVERRIDE      use this as the highest existing counter
#                         (empty = "no existing tags")
#
# Writes:
#   stdout            final tag
#   $GITHUB_OUTPUT    tag=, commit_hash=, branch=  (if env var set)
#   $GITHUB_ENV       TAG=, COMMIT_HASH=           (if env var set)
#
# Design invariants:
#   1. Date and counter are never truncated. They're treated as a fixed
#      reservation in the length budget.
#   2. Service is preserved when it fits, otherwise truncated and any trailing
#      '-' or '_' is stripped.
#   3. Branch is the elastic component: it takes whatever space is left,
#      then has any trailing '-' or '_' stripped.
#   4. Empty parts are dropped from the tag entirely, so the join never emits
#      adjacent separators ("__") or leading/trailing separators.
#   5. If max_length cannot fit the always-present parts (date + counter),
#      the script fails fast rather than emitting a broken tag.

set -o pipefail

# -----------------------------------------------------------------------------
# Inputs
# -----------------------------------------------------------------------------
SERVICE_NAME="${SERVICE_NAME-}"
CUSTOM_TAG="${CUSTOM_TAG-}"
TAG_FORMAT="${TAG_FORMAT:-service-date-branch-counter}"
MAX_LENGTH="${MAX_LENGTH:-63}"
INCLUDE_COUNTER="${INCLUDE_COUNTER:-true}"
BRANCH_REF="${BRANCH_REF-}"
PR_REF="${PR_REF-}"
BRANCH_SEP="${BRANCH_SEP:--}"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
trim_trailing_sep() {
  local s="$1"
  while [[ "$s" =~ [-_]$ ]]; do s="${s%?}"; done
  printf '%s' "$s"
}

join_nonempty() {
  local sep="$1"; shift
  local out=""
  local p
  for p in "$@"; do
    [ -z "$p" ] && continue
    [ -z "$out" ] && out="$p" || out="${out}${sep}${p}"
  done
  printf '%s' "$out"
}

emit_output() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >> "$GITHUB_OUTPUT"; return 0; }
emit_env()    { [ -n "${GITHUB_ENV:-}" ]    && echo "$1" >> "$GITHUB_ENV";    return 0; }
log()         { echo "$@" >&2; }

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------
if ! [[ "$MAX_LENGTH" =~ ^[0-9]+$ ]] || [ "$MAX_LENGTH" -le 0 ]; then
  log "❌ Error: max_length must be a positive integer"
  exit 1
fi

# Commit hash (always emitted regardless of path)
if [ -n "${COMMIT_HASH_OVERRIDE-}" ]; then
  COMMIT_HASH="$COMMIT_HASH_OVERRIDE"
else
  if ! COMMIT_HASH=$(git rev-parse HEAD 2>/dev/null); then
    log "❌ Error: Not in a git repository or git is not available"
    exit 1
  fi
fi
emit_output "commit_hash=$COMMIT_HASH"
emit_env    "COMMIT_HASH=$COMMIT_HASH"

# -----------------------------------------------------------------------------
# custom_tag path
# -----------------------------------------------------------------------------
if [ -n "$CUSTOM_TAG" ]; then
  TAG=$(echo "$CUSTOM_TAG" | tr '/:' "$BRANCH_SEP")
  if [ ${#TAG} -gt "$MAX_LENGTH" ]; then
    TAG=$(trim_trailing_sep "${TAG:0:$MAX_LENGTH}")
    log "✂️ Truncated custom tag to $MAX_LENGTH characters"
  fi
  log "✅ Using custom tag: $TAG"
  emit_output "tag=$TAG"
  emit_env    "TAG=$TAG"
  echo "$TAG"
  exit 0
fi

# -----------------------------------------------------------------------------
# Auto-generated tag path
# -----------------------------------------------------------------------------

# Pick branch from explicit input > PR ref > github.ref
if [ -n "$BRANCH_REF" ]; then
  BRANCH=$(echo "$BRANCH_REF" | sed 's#refs/heads/##')
elif [ -n "$PR_REF" ]; then
  BRANCH="$PR_REF"
else
  BRANCH=""
fi
# Normalise special characters
BRANCH=$(echo "$BRANCH" | tr '/:@#' "$BRANCH_SEP")
emit_output "branch=$BRANCH"
log "📋 Branch: $BRANCH"

# Date
if [ -n "${DATE_OVERRIDE-}" ]; then
  DATE="$DATE_OVERRIDE"
else
  DATE=$(date +'%Y-%m-%d')
fi
log "📅 Date: $DATE"

# Format -> ordering of (service, branch, date) slots.
# Counter is appended last, separately, when INCLUDE_COUNTER=true.
FMT_USES_SVC=0
case "$TAG_FORMAT" in
  service-date-branch-counter|service_date_branch_counter|service-date-branch|service_date_branch)
    ORDER=("service" "date" "branch"); FMT_USES_SVC=1 ;;
  service-branch-date-counter|service_branch_date_counter|service-branch-date|service_branch_date)
    ORDER=("service" "branch" "date"); FMT_USES_SVC=1 ;;
  branch-date|branch_date|branch-date-counter|branch_date_counter)
    ORDER=("branch" "date") ;;
  date-branch|date_branch|date-branch-counter|date_branch_counter)
    ORDER=("date" "branch") ;;
  *)
    log "❌ Invalid TAG_FORMAT: $TAG_FORMAT"
    log "Valid formats: service-date-branch[-counter], service-branch-date[-counter], branch-date[-counter], date-branch[-counter] (with optional _ alias)"
    exit 1
    ;;
esac

HAS_COUNTER=0
[ "$INCLUDE_COUNTER" = "true" ] && HAS_COUNTER=1

# Minimum possible tag length: date(10) + optional "_NN"(3)
MIN_TAG_LEN=10
[ "$HAS_COUNTER" = "1" ] && MIN_TAG_LEN=$((MIN_TAG_LEN + 3))
if [ "$MIN_TAG_LEN" -gt "$MAX_LENGTH" ]; then
  log "❌ max_length=$MAX_LENGTH too small for the always-present parts (need at least $MIN_TAG_LEN)"
  exit 1
fi

# Length budget assuming branch+date concatenated with one '_' (reserved 11),
# and counter taking "_NN" (reserved 3).
FIXED_LEN=$((10 + 1))                              # date + leading separator
[ "$HAS_COUNTER" = "1" ] && FIXED_LEN=$((FIXED_LEN + 3))

# Service: only consume budget when the format actually uses service.
TRUNCATED_SERVICE=""
if [ "$FMT_USES_SVC" = "1" ] && [ -n "$SERVICE_NAME" ]; then
  # Max service len = whole budget - fixed - own separator - 1 char for branch
  MAX_SERVICE_LEN=$((MAX_LENGTH - FIXED_LEN - 2))
  if [ "$MAX_SERVICE_LEN" -le 0 ]; then
    TRUNCATED_SERVICE=""
  elif [ ${#SERVICE_NAME} -gt "$MAX_SERVICE_LEN" ]; then
    TRUNCATED_SERVICE=$(trim_trailing_sep "${SERVICE_NAME:0:$MAX_SERVICE_LEN}")
    log "✂️ Truncating service name to fit budget"
  else
    TRUNCATED_SERVICE="$SERVICE_NAME"
  fi
fi

# Branch: whatever is left after fixed + service
USED=$FIXED_LEN
[ -n "$TRUNCATED_SERVICE" ] && USED=$((USED + ${#TRUNCATED_SERVICE} + 1))
AVAIL_BRANCH=$((MAX_LENGTH - USED))

TRUNCATED_BRANCH=""
if [ "$AVAIL_BRANCH" -ge 1 ] && [ -n "$BRANCH" ]; then
  if [ ${#BRANCH} -gt "$AVAIL_BRANCH" ]; then
    TRUNCATED_BRANCH=$(trim_trailing_sep "${BRANCH:0:$AVAIL_BRANCH}")
    log "✂️ Truncating branch to fit budget"
  else
    TRUNCATED_BRANCH="$BRANCH"
  fi
fi

# Build base tag by walking the format's slot ordering, skipping empty parts.
build_base_tag() {
  local slot
  local parts=()
  for slot in "${ORDER[@]}"; do
    case "$slot" in
      service) [ -n "$TRUNCATED_SERVICE" ] && parts+=("$TRUNCATED_SERVICE") ;;
      branch)  [ -n "$TRUNCATED_BRANCH" ]  && parts+=("$TRUNCATED_BRANCH")  ;;
      date)    parts+=("$DATE") ;;
    esac
  done
  if [ "${#parts[@]}" -eq 0 ]; then
    printf ''
  else
    join_nonempty "_" "${parts[@]}"
  fi
}

TAG=$(build_base_tag)
log "🔨 Base tag: $TAG"

# Counter (computed AFTER base tag is known, since the lookup key is the base).
if [ "$HAS_COUNTER" = "1" ]; then
  if [ -n "${HIGHEST_OVERRIDE+x}" ]; then
    HIGHEST="$HIGHEST_OVERRIDE"
  else
    HIGHEST=""
    if git ls-remote --tags origin >/dev/null 2>&1; then
      HIGHEST=$(git ls-remote --tags origin | grep -v '\^{}' | grep -oE "refs/tags/${TAG}_[0-9]+$" | grep -oE '[0-9]+$' | sort -n | tail -1 || true)
    else
      log "⚠️  Cannot access remote tags, using local tags for counter"
      HIGHEST=$(git tag -l "${TAG}_*" | grep -oE "${TAG}_[0-9]+$" | grep -oE '[0-9]+$' | sort -n | tail -1 || true)
    fi
  fi
  if [ -n "$HIGHEST" ]; then
    COUNTER=$(printf '%02d' $((10#$HIGHEST + 1)))
  else
    COUNTER="01"
  fi
  log "🔢 Counter: $COUNTER"

  # If the counter is wider than the 2-char reservation (i.e. _100+), trim the
  # branch by the overflow so the final tag still fits max_length.
  COUNTER_OVERFLOW=$(( ${#COUNTER} - 2 ))
  if [ "$COUNTER_OVERFLOW" -gt 0 ] && [ -n "$TRUNCATED_BRANCH" ]; then
    NEW_LEN=$(( ${#TRUNCATED_BRANCH} - COUNTER_OVERFLOW ))
    if [ "$NEW_LEN" -gt 0 ]; then
      TRUNCATED_BRANCH=$(trim_trailing_sep "${TRUNCATED_BRANCH:0:$NEW_LEN}")
    else
      TRUNCATED_BRANCH=""
    fi
    TAG=$(build_base_tag)
    log "✂️ Adjusted branch for counter overflow"
  fi

  TAG="${TAG}_${COUNTER}"
fi

log "🎯 Final tag: $TAG"
emit_output "tag=$TAG"
emit_env    "TAG=$TAG"
echo "$TAG"
