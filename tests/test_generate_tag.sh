#!/usr/bin/env bash
#
# Unit tests for scripts/generate-tag.sh
#
# Coverage:
#   - every tag_format x include_counter (on/off): 8 formats x 2 = 16 combos
#   - per combo: happy path / long-branch clean cut / long-branch cut lands ON '-'
#     / long-service clean cut / long-service cut lands ON '-' / tiny max_length
#   - underscore aliases parity
#   - custom_tag path with and without truncation-at-separator
#   - invariants:
#       * user's case (service-branch-date-counter + counter=on) always ends _DATE_NN
#       * counter-on formats always end in _NN
#       * date-last formats with counter-off end in _DATE
#       * max_length too small for fixed parts should error
#       * service-less formats shouldn't reserve service budget when SERVICE_NAME is set
#
# Each assertion is dispatched via `expect <pass|fail-until-fixed> <name> <status>`
# so currently-broken cases stay RED (visible) until the fix lands. If a fix
# accidentally makes a fail-until-fixed pass, the harness reports XPASS so we
# know to retire the expected-fail tag.
#
# Legend:
#   PASS   - assertion passed (expected)
#   FAIL   - assertion failed (regression we did not expect)
#   RED    - expected failure observed (known bug still present, as expected)
#   XPASS  - expected failure now passing (bug likely fixed; remove fail-until-fixed)
#
# Script exits non-zero only on FAIL. RED is tolerated until fix.

set -o pipefail   # not -u: empty arrays trip unbound errors in bash 3.2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$SCRIPT_DIR/../scripts/generate-tag.sh"

PASS=0; FAIL=0; RED=0; XPASS=0
FAILED_TESTS=(); XPASS_TESTS=()

# -----------------------------------------------------------------------------
# Harness
# -----------------------------------------------------------------------------
run_gen() {
  env -i PATH="$PATH" HOME="$HOME" \
    COMMIT_HASH_OVERRIDE="abc1234" \
    DATE_OVERRIDE="2026-05-25" \
    HIGHEST_OVERRIDE="" \
    "$@" \
    bash "$GEN" 2>/dev/null
}

# expect <mode> <name> <status>   mode = pass | fail-until-fixed
expect() {
  local mode="$1" name="$2" status="$3"
  if [ "$mode" = "pass" ]; then
    if [ "$status" = "0" ]; then
      PASS=$((PASS+1)); printf "    PASS   %s\n" "$name"
    else
      FAIL=$((FAIL+1)); FAILED_TESTS+=("$name"); printf "    FAIL   %s\n" "$name"
    fi
  else
    if [ "$status" = "0" ]; then
      XPASS=$((XPASS+1)); XPASS_TESTS+=("$name"); printf "    XPASS  %s  (now passing - remove fail-until-fixed)\n" "$name"
    else
      RED=$((RED+1)); printf "    RED    %s  (known bug, still present)\n" "$name"
    fi
  fi
}

# Predicates -- return 0 if assertion holds, 1 otherwise.
check_no_trailing_sep() { [[ ! "$1" =~ [-_]$ ]]; }
check_no_leading_sep()  { [[ ! "$1" =~ ^[-_] ]]; }
check_no_double_sep()   { [[ ! "$1" =~ (__|--) ]]; }
check_max_len()         { [ ${#1} -le "$2" ]; }
check_ends_with()       { [[ "$1" == *"$2" ]]; }
check_eq()              { [ "$1" = "$2" ]; }
check_contains()        { [[ "$1" == *"$2"* ]]; }

# Build a branch where char at index `idx` is '-'.
# After truncating to (idx+1) chars, the result ends in '-'.
make_branch_dash_at() {
  local idx="$1"
  local prefix=""
  if [ "$idx" -gt 0 ]; then
    prefix=$(printf 'a%.0s' $(seq 1 "$idx"))
  fi
  printf '%s-rest' "$prefix"
}

# A long branch with no dashes near the cut position (clean cut).
make_branch_clean_long() { printf 'x%.0s' $(seq 1 80); }

# Service with '-' at index 37 -- triggers dash-on-trunc when MAX_SERVICE=38.
SVC_DASH_AT_37="serviceaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-xxxxxxxxx"

# Compute the available-for-branch length the script will use, given format + counter.
# Mirrors action.yml's budget math so the test can craft branches that hit truncation.
compute_avail_branch() {
  local fmt="$1" counter="$2" max_len="$3" svc_len="$4"
  local avail=$max_len
  [ "$counter" = "true" ] && avail=$((avail - 3))
  [[ "$fmt" =~ "date" ]] && avail=$((avail - 11))
  if [ "$svc_len" -gt 0 ]; then
    # The script subtracts svc + 1, even when format ignores the service.
    avail=$((avail - svc_len - 1))
  fi
  echo "$avail"
}

# Does the format put branch at the very end (so trailing-dash bites)?
fmt_branch_last() {
  case "$1" in
    service-date-branch*|service_date_branch*|date-branch*|date_branch*) echo 1 ;;
    *) echo 0 ;;
  esac
}

# Does the format use the service slot?
fmt_uses_service() {
  case "$1" in
    service-*|service_*) echo 1 ;;
    *) echo 0 ;;
  esac
}

section() { echo; echo "========== $1 =========="; }
sub()     { echo; echo "  -- $1 --"; }

DATE="2026-05-25"

# -----------------------------------------------------------------------------
section "Sanity: documented examples"
# -----------------------------------------------------------------------------

tag=$(run_gen SERVICE_NAME="test-service" TAG_FORMAT="service-date-branch-counter" BRANCH_REF="refs/heads/main")
check_eq "$tag" "test-service_${DATE}_main_01"; expect pass "default format: README example" $?

tag=$(run_gen SERVICE_NAME="api" TAG_FORMAT="service-branch-date-counter" BRANCH_REF="refs/heads/main")
check_eq "$tag" "api_main_${DATE}_01"; expect pass "service-branch-date-counter: example" $?

tag=$(run_gen TAG_FORMAT="branch-date-counter" BRANCH_REF="refs/heads/main")
check_eq "$tag" "main_${DATE}_01"; expect pass "branch-date-counter no service: example" $?

tag=$(run_gen TAG_FORMAT="date-branch" INCLUDE_COUNTER="false" BRANCH_REF="refs/heads/main")
check_eq "$tag" "${DATE}_main"; expect pass "date-branch no counter: example" $?

# Underscore alias parity for every format
for pair in \
  "service-date-branch-counter:service_date_branch_counter" \
  "service-date-branch:service_date_branch" \
  "service-branch-date-counter:service_branch_date_counter" \
  "service-branch-date:service_branch_date" \
  "branch-date-counter:branch_date_counter" \
  "branch-date:branch_date" \
  "date-branch-counter:date_branch_counter" \
  "date-branch:date_branch"; do
  dash="${pair%%:*}"; under="${pair##*:}"
  t1=$(run_gen SERVICE_NAME="svc" TAG_FORMAT="$dash"  BRANCH_REF="refs/heads/main")
  t2=$(run_gen SERVICE_NAME="svc" TAG_FORMAT="$under" BRANCH_REF="refs/heads/main")
  check_eq "$t1" "$t2"; expect pass "alias parity: $dash == $under" $?
done

# -----------------------------------------------------------------------------
section "User-reported invariant: service-branch-date-counter + counter=on always ends _DATE_NN"
# -----------------------------------------------------------------------------

for br in \
  "main" \
  "ggg_uni-rrrr-reintrrrrr-xxxx-ttt-fff-rrtt" \
  "$(make_branch_dash_at 40)" \
  "feature/some-thing" \
  "very-long-branch-name-with-many-dashes-and-more-segments-here-extra"; do
  tag=$(run_gen SERVICE_NAME="backend" TAG_FORMAT="service-branch-date-counter" \
        INCLUDE_COUNTER="true" BRANCH_REF="refs/heads/$br")
  check_ends_with "$tag" "_${DATE}_01"; expect pass "[user case] ends _${DATE}_01 (branch len=${#br})" $?
  check_max_len   "$tag" 63;             expect pass "[user case] within 63 (branch len=${#br})"      $?
done

for svc in "backend" "$SVC_DASH_AT_37" "$(printf 'b%.0s' $(seq 1 60))"; do
  tag=$(run_gen SERVICE_NAME="$svc" TAG_FORMAT="service-branch-date-counter" \
        INCLUDE_COUNTER="true" BRANCH_REF="refs/heads/$(make_branch_dash_at 40)")
  check_ends_with "$tag" "_${DATE}_01"; expect pass "[user case] ends _${DATE}_01 (svc len=${#svc})" $?
  check_max_len   "$tag" 63;             expect pass "[user case] within 63 (svc len=${#svc})"       $?
done

# -----------------------------------------------------------------------------
# Per-format scenario suite
# -----------------------------------------------------------------------------
run_format_suite() {
  local fmt="$1" counter="$2"
  local has_svc; has_svc=$(fmt_uses_service "$fmt")
  local branch_last; branch_last=$(fmt_branch_last "$fmt")
  local svc_len=0
  local svc_args=()
  if [ "$has_svc" = "1" ]; then
    svc_args=(SERVICE_NAME="backend")
    svc_len=7
  fi

  local mode_label
  [ "$counter" = "true" ] && mode_label="counter=on" || mode_label="counter=off"
  sub "FORMAT: $fmt ($mode_label)"

  local tag
  local avail; avail=$(compute_avail_branch "$fmt" "$counter" 63 "$svc_len")

  # 1) Happy path
  tag=$(run_gen "${svc_args[@]}" TAG_FORMAT="$fmt" INCLUDE_COUNTER="$counter" BRANCH_REF="refs/heads/main")
  check_no_trailing_sep "$tag"; expect pass "$fmt [$mode_label] happy: no trailing sep" $?
  check_no_leading_sep  "$tag"; expect pass "$fmt [$mode_label] happy: no leading sep"  $?
  check_no_double_sep   "$tag"; expect pass "$fmt [$mode_label] happy: no double sep"   $?
  check_max_len "$tag" 63;      expect pass "$fmt [$mode_label] happy: <=63"            $?

  # 2) Long branch -- clean cut (no '-' at truncation point)
  tag=$(run_gen "${svc_args[@]}" TAG_FORMAT="$fmt" INCLUDE_COUNTER="$counter" \
        BRANCH_REF="refs/heads/$(make_branch_clean_long)")
  check_no_trailing_sep "$tag"; expect pass "$fmt [$mode_label] long-branch clean-cut: no trailing sep" $?
  check_no_double_sep   "$tag"; expect pass "$fmt [$mode_label] long-branch clean-cut: no double sep"   $?
  check_max_len "$tag" 63;      expect pass "$fmt [$mode_label] long-branch clean-cut: <=63"            $?

  # 3) Long branch -- cut lands ON '-'   ** KNOWN BUG case for branch-last + counter=off **
  local crafted; crafted=$(make_branch_dash_at $((avail - 1)))
  tag=$(run_gen "${svc_args[@]}" TAG_FORMAT="$fmt" INCLUDE_COUNTER="$counter" \
        BRANCH_REF="refs/heads/$crafted")
  if [ "$branch_last" = "1" ] && [ "$counter" = "false" ]; then
    check_no_trailing_sep "$tag"; expect pass "$fmt [$mode_label] long-branch dash-cut: no trailing sep" $?
  else
    check_no_trailing_sep "$tag"; expect pass "$fmt [$mode_label] long-branch dash-cut: no trailing sep" $?
  fi
  check_no_double_sep "$tag"; expect pass "$fmt [$mode_label] long-branch dash-cut: no double sep" $?
  check_max_len "$tag" 63;    expect pass "$fmt [$mode_label] long-branch dash-cut: <=63"          $?

  # 4) Long service clean cut (service formats only)
  if [ "$has_svc" = "1" ]; then
    tag=$(run_gen SERVICE_NAME="$(printf 'b%.0s' $(seq 1 60))" TAG_FORMAT="$fmt" \
          INCLUDE_COUNTER="$counter" BRANCH_REF="refs/heads/main")
    check_no_trailing_sep "$tag"; expect pass "$fmt [$mode_label] long-svc clean-cut: no trailing sep" $?
    check_no_double_sep   "$tag"; expect pass "$fmt [$mode_label] long-svc clean-cut: no double sep"   $?
    check_max_len "$tag" 63;      expect pass "$fmt [$mode_label] long-svc clean-cut: <=63"            $?
  fi

  # 5) Long service -- cut lands ON '-' (service formats only)
  if [ "$has_svc" = "1" ]; then
    tag=$(run_gen SERVICE_NAME="$SVC_DASH_AT_37" TAG_FORMAT="$fmt" \
          INCLUDE_COUNTER="$counter" BRANCH_REF="refs/heads/main")
    # Service sits before the rest; truncated service ending in '-' then '_<next>' gives
    # '-_' (single trailing sep on service + leading sep on next). Not double-sep, not trailing.
    check_no_trailing_sep "$tag"; expect pass "$fmt [$mode_label] long-svc dash-cut: no trailing sep" $?
    check_no_double_sep   "$tag"; expect pass "$fmt [$mode_label] long-svc dash-cut: no double sep"   $?
    check_max_len "$tag" 63;      expect pass "$fmt [$mode_label] long-svc dash-cut: <=63"            $?
  fi

  # 6) Tiny max_length -- branch becomes empty / tag overflows.
  # Per-case expected bugs (current code), reasoned per format+counter:
  #
  #   service-date-branch*  + counter=off : tag = "svc_DATE_"        -> trailing '_', overflow
  #   service-date-branch*  + counter=on  : tag = "svc_DATE__01"     -> '__' double, overflow
  #   service-branch-date*  + counter=off : tag = "svc__DATE"        -> '__' double, overflow
  #   service-branch-date*  + counter=on  : tag = "svc__DATE_01"     -> '__' double, overflow
  #   branch-date* / date-branch* (no svc args): tag fits, no bug
  if [ "$has_svc" = "1" ]; then
    tag=$(run_gen SERVICE_NAME="some-service" TAG_FORMAT="$fmt" INCLUDE_COUNTER="$counter" \
          MAX_LENGTH="20" BRANCH_REF="refs/heads/some-feature-branch")
  else
    tag=$(run_gen TAG_FORMAT="$fmt" INCLUDE_COUNTER="$counter" \
          MAX_LENGTH="20" BRANCH_REF="refs/heads/some-feature-branch")
  fi

  local expect_overflow=0 expect_double=0 expect_trail=0
  if [ "$has_svc" = "1" ]; then
    expect_overflow=1
    case "$fmt" in
      service-branch-date*|service_branch_date*) expect_double=1 ;;
      service-date-branch*|service_date_branch*)
        if [ "$counter" = "true" ]; then expect_double=1; else expect_trail=1; fi
        ;;
    esac
  fi

  if [ "$expect_overflow" = "1" ]; then
    check_max_len "$tag" 20; expect pass "$fmt [$mode_label] tiny max_len: <=20" $?
  else
    check_max_len "$tag" 20; expect pass             "$fmt [$mode_label] tiny max_len: <=20" $?
  fi
  if [ "$expect_double" = "1" ]; then
    check_no_double_sep "$tag"; expect pass "$fmt [$mode_label] tiny max_len: no double sep" $?
  else
    check_no_double_sep "$tag"; expect pass             "$fmt [$mode_label] tiny max_len: no double sep" $?
  fi
  if [ "$expect_trail" = "1" ]; then
    check_no_trailing_sep "$tag"; expect pass "$fmt [$mode_label] tiny max_len: no trailing sep" $?
  else
    check_no_trailing_sep "$tag"; expect pass             "$fmt [$mode_label] tiny max_len: no trailing sep" $?
  fi
}

section "All formats x include_counter"
for fmt in \
  service-date-branch-counter \
  service-date-branch \
  service-branch-date-counter \
  service-branch-date \
  branch-date-counter \
  branch-date \
  date-branch-counter \
  date-branch; do
  for counter in true false; do
    run_format_suite "$fmt" "$counter"
  done
done

# -----------------------------------------------------------------------------
section "Invariant: date and counter visible where format dictates"
# -----------------------------------------------------------------------------

# date-last formats + counter=on -> end in "_DATE_NN"
for fmt in service-branch-date-counter service-branch-date branch-date-counter branch-date; do
  br=$(make_branch_dash_at 40)
  tag=$(run_gen SERVICE_NAME="backend" TAG_FORMAT="$fmt" INCLUDE_COUNTER="true" BRANCH_REF="refs/heads/$br")
  check_ends_with "$tag" "_${DATE}_01"; expect pass "$fmt (counter=on) ends _${DATE}_01" $?
done

# date-last formats + counter=off -> end in "_DATE"
for fmt in service-branch-date-counter service-branch-date branch-date-counter branch-date; do
  br=$(make_branch_dash_at 40)
  tag=$(run_gen SERVICE_NAME="backend" TAG_FORMAT="$fmt" INCLUDE_COUNTER="false" BRANCH_REF="refs/heads/$br")
  check_ends_with "$tag" "_${DATE}"; expect pass "$fmt (counter=off) ends _${DATE}" $?
done

# branch-last formats + counter=on -> end in "_NN" (counter saves the tail)
for fmt in service-date-branch-counter service-date-branch date-branch-counter date-branch; do
  br=$(make_branch_dash_at 40)
  tag=$(run_gen SERVICE_NAME="backend" TAG_FORMAT="$fmt" INCLUDE_COUNTER="true" BRANCH_REF="refs/heads/$br")
  [[ "$tag" =~ _[0-9]{2,}$ ]]; expect pass "$fmt (counter=on) ends _NN digit" $?
done

# branch-last + counter=off -> branch is last; dash-cut -> trailing '-' (KNOWN BUG).
# Use a per-format crafted branch so the cut actually lands on '-'.
for fmt in service-date-branch-counter service-date-branch date-branch-counter date-branch; do
  has_svc=$(fmt_uses_service "$fmt")
  svc_len=0; [ "$has_svc" = "1" ] && svc_len=7
  avail=$(compute_avail_branch "$fmt" "false" 63 "$svc_len")
  br=$(make_branch_dash_at $((avail - 1)))
  svc_args=()
  [ "$has_svc" = "1" ] && svc_args=(SERVICE_NAME="backend")
  tag=$(run_gen "${svc_args[@]}" TAG_FORMAT="$fmt" INCLUDE_COUNTER="false" BRANCH_REF="refs/heads/$br")
  check_no_trailing_sep "$tag"; expect pass "$fmt (counter=off, branch-last, dash-cut): no trailing sep" $?
done

# -----------------------------------------------------------------------------
section "Invariant: max_length too small for fixed parts should error"
# -----------------------------------------------------------------------------
# date+counter fixed = 14 chars. max_length=10 cannot hold them.
status=0
out=$(run_gen TAG_FORMAT="date-branch-counter" INCLUDE_COUNTER="true" \
      MAX_LENGTH="10" BRANCH_REF="refs/heads/main") || status=$?
if [ "$status" != "0" ]; then
  expect pass "max_length=10 with date+counter: errors out" 0
else
  expect pass "max_length=10 with date+counter: should error out" 1
  check_max_len "$out" 10; expect pass "max_length=10 with date+counter: tag <=10" $?
fi

# -----------------------------------------------------------------------------
section "Bug: service budget reserved even when format ignores service"
# -----------------------------------------------------------------------------
# For branch-date / date-branch (no 'service' slot), passing SERVICE_NAME should
# NOT shrink the branch budget. Currently it does, which can force branch empty
# and produce '__' at small max_length.
for fmt in branch-date-counter branch-date date-branch-counter date-branch; do
  with_svc=$(run_gen SERVICE_NAME="some-service" TAG_FORMAT="$fmt" INCLUDE_COUNTER="true" \
             MAX_LENGTH="30" BRANCH_REF="refs/heads/feature/auth-rewrite-token-issuer-vN")
  no_svc=$(run_gen TAG_FORMAT="$fmt" INCLUDE_COUNTER="true" \
           MAX_LENGTH="30" BRANCH_REF="refs/heads/feature/auth-rewrite-token-issuer-vN")
  check_eq "$with_svc" "$no_svc"; expect pass "$fmt: SERVICE_NAME has no effect (currently reduces branch budget)" $?
done

# -----------------------------------------------------------------------------
section "Bug: counter overflow (_99 -> _100) exceeds reserved 3-char budget"
# -----------------------------------------------------------------------------
# Reserve is 3 chars for "_NN"; when highest is 99, computed counter is "100"
# (3 digits) and suffix becomes "_100" (4 chars), overflowing max_length by 1.
long_branch=$(printf 'a%.0s' $(seq 1 50))
tag=$(env -i PATH="$PATH" HOME="$HOME" \
      COMMIT_HASH_OVERRIDE="abc" DATE_OVERRIDE="$DATE" HIGHEST_OVERRIDE="99" \
      SERVICE_NAME="api" TAG_FORMAT="service-branch-date-counter" INCLUDE_COUNTER="true" \
      BRANCH_REF="refs/heads/$long_branch" \
      bash "$GEN" 2>/dev/null)
check_max_len "$tag" 63; expect pass "counter overflow _99->_100: tag <=63" $?

# Also verify the suffix is what we think (sanity)
check_contains "$tag" "_100"; expect pass "counter overflow: suffix is _100 (sanity)" $?

# -----------------------------------------------------------------------------
section "Bug: leading separator when first part of format is empty"
# -----------------------------------------------------------------------------
# branch-date-counter with no service and max_length so small the branch becomes
# empty: tag starts with "_" because format begins with branch.
tag=$(run_gen TAG_FORMAT="branch-date-counter" INCLUDE_COUNTER="true" \
      MAX_LENGTH="14" BRANCH_REF="refs/heads/some-branch")
check_no_leading_sep "$tag"; expect pass "branch-date-counter empty branch: no leading sep" $?

tag=$(run_gen TAG_FORMAT="branch-date" INCLUDE_COUNTER="false" \
      MAX_LENGTH="11" BRANCH_REF="refs/heads/some-branch")
check_no_leading_sep "$tag"; expect pass "branch-date empty branch: no leading sep" $?

# -----------------------------------------------------------------------------
section "custom_tag path"
# -----------------------------------------------------------------------------

# Normal truncation, not on a separator
tag=$(run_gen CUSTOM_TAG="v1.2.3-release-candidate-with-extras" MAX_LENGTH="22")
check_max_len "$tag" 22;      expect pass "custom_tag normal trunc <=22"          $?
check_no_trailing_sep "$tag"; expect pass "custom_tag normal trunc: no trail sep" $?

# Truncation lands ON '-'  (KNOWN BUG)
tag=$(run_gen CUSTOM_TAG="aaaaa-bbbbb-ccccc-ddddd-eeeee" MAX_LENGTH="18")
check_max_len "$tag" 18;      expect pass             "custom_tag dash-cut <=18"           $?
check_no_trailing_sep "$tag"; expect pass "custom_tag dash-cut: no trail sep" $?

# Truncation lands ON '_'  (KNOWN BUG)
tag=$(run_gen CUSTOM_TAG="aaaaa_bbbbb_ccccc_ddddd_eeeee" MAX_LENGTH="18")
check_no_trailing_sep "$tag"; expect pass "custom_tag underscore-cut: no trail sep" $?

# Normalisation
tag=$(run_gen CUSTOM_TAG="v1.2.3/release:candidate")
check_eq "$tag" "v1.2.3-release-candidate"; expect pass "custom_tag normalises / and :" $?

# -----------------------------------------------------------------------------
section "Format-name + counter-flag parity"
# -----------------------------------------------------------------------------
# '-counter' suffix in format name is just an alias; counter inclusion is
# decided by INCLUDE_COUNTER. Pairs should produce identical tags.
t1=$(run_gen SERVICE_NAME="api" TAG_FORMAT="service-branch-date-counter" INCLUDE_COUNTER="false" BRANCH_REF="refs/heads/main")
t2=$(run_gen SERVICE_NAME="api" TAG_FORMAT="service-branch-date"         INCLUDE_COUNTER="false" BRANCH_REF="refs/heads/main")
check_eq "$t1" "$t2"; expect pass "'-counter' name + counter=off == no-counter name + counter=off" $?

t1=$(run_gen TAG_FORMAT="branch-date-counter" INCLUDE_COUNTER="true" BRANCH_REF="refs/heads/main")
t2=$(run_gen TAG_FORMAT="branch-date"         INCLUDE_COUNTER="true" BRANCH_REF="refs/heads/main")
check_eq "$t1" "$t2"; expect pass "'branch-date' + counter=on == 'branch-date-counter' + counter=on" $?

# -----------------------------------------------------------------------------
section "Invalid format rejected"
# -----------------------------------------------------------------------------
status=0
out=$(run_gen TAG_FORMAT="totally-bogus-format" BRANCH_REF="refs/heads/main") || status=$?
[ "$status" != "0" ]; expect pass "unknown tag_format errors out" $?

# -----------------------------------------------------------------------------
# Tally
# -----------------------------------------------------------------------------
echo
echo "============================================================"
printf " PASS:  %d  (assertion held, as expected)\n" "$PASS"
printf " FAIL:  %d  (assertion failed unexpectedly -- regression)\n" "$FAIL"
printf " RED:   %d  (known bug still present, as expected)\n" "$RED"
printf " XPASS: %d  (expected fails now passing -- bug fixed? remove mark)\n" "$XPASS"
if [ $FAIL -gt 0 ]; then
  echo
  echo " Unexpected failures (regressions to investigate):"
  for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
fi
if [ $XPASS -gt 0 ]; then
  echo
  echo " Unexpected passes (remove fail-until-fixed mark):"
  for t in "${XPASS_TESTS[@]}"; do echo "  - $t"; done
fi
echo "============================================================"

[ $FAIL -eq 0 ] || exit 1
exit 0
