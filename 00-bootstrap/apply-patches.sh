#!/usr/bin/env bash
#
# apply-patches.sh -- apply the course's patches to the upstream checkouts.
#
# The course treats upstream checkouts as read-only, with one exception: ecmc
# 11.0.x does not compile against upstream `motor` at any released version. See
# ../patches/README.md for the diagnosis.
#
# Patches live in ../patches/ and are named <NNNN>-<target>-<description>.patch,
# where <target> selects which checkout they apply to:
#
#     0001-ecmc-guard-motorLimitRO.patch   ->  $ECMC_SRC
#
# Safe to re-run: an already-applied patch is detected and skipped, not retried.
#
#   ./apply-patches.sh              apply what is missing
#   ./apply-patches.sh --check      report status, change nothing
#   ./apply-patches.sh --reverse    unapply (restore the pristine checkout)

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
patchdir="$repo/patches"

MODE=apply
case "${1:-}" in
  --check)   MODE=check ;;
  --reverse) MODE=reverse ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  "")        ;;
  *)         echo "unknown option: $1" >&2; exit 2 ;;
esac

if [[ ! -f "$repo/site.conf" ]]; then
  echo "ERROR: $repo/site.conf not found." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$repo/site.conf"

if [[ ! -d "$patchdir" ]]; then
  echo "No patches directory; nothing to do."
  exit 0
fi

n_applied=0 n_skipped=0 n_fail=0

# Map a patch's <target> field to the checkout it belongs to.
target_dir() {
  case "$1" in
    ecmc)     printf '%s' "${ECMC_SRC:-}" ;;
    ecmccfg)  printf '%s' "${ECMCCFG_SRC:-}" ;;
    ecmccomp) printf '%s' "${ECMCCOMP_SRC:-}" ;;
    *)        printf '' ;;
  esac
}

shopt -s nullglob
for p in "$patchdir"/*.patch; do
  base="$(basename "$p")"
  # 0001-ecmc-guard-... -> ecmc
  target="$(printf '%s' "$base" | sed -E 's/^[0-9]+-([a-z]+)-.*/\1/')"
  dir="$(target_dir "$target")"

  printf '\n== %s -> %s ==\n' "$base" "${target:-<unknown>}"

  if [[ -z "$dir" ]]; then
    echo "    FAIL: cannot map '$target' to a checkout; is it set in site.conf?"
    n_fail=$((n_fail + 1)); continue
  fi
  if [[ ! -d "$dir/.git" ]]; then
    echo "    FAIL: $dir is not a git checkout"
    n_fail=$((n_fail + 1)); continue
  fi

  applied=0
  git -C "$dir" apply --reverse --check "$p" 2>/dev/null && applied=1

  case "$MODE" in
    check)
      if [[ $applied -eq 1 ]]; then
        echo "    applied"
      elif git -C "$dir" apply --check "$p" 2>/dev/null; then
        echo "    NOT applied (would apply cleanly)"
        n_fail=$((n_fail + 1))
      else
        echo "    NOT applied and does NOT apply cleanly -- checkout version changed?"
        n_fail=$((n_fail + 1))
      fi
      ;;
    reverse)
      if [[ $applied -eq 1 ]]; then
        git -C "$dir" apply --reverse "$p" && echo "    reversed" \
          || { echo "    FAIL: reverse failed"; n_fail=$((n_fail + 1)); }
      else
        echo "    not applied; nothing to reverse"
        n_skipped=$((n_skipped + 1))
      fi
      ;;
    apply)
      if [[ $applied -eq 1 ]]; then
        echo "    already applied, skipping"
        n_skipped=$((n_skipped + 1))
      elif git -C "$dir" apply "$p" 2>/dev/null; then
        echo "    applied to $dir"
        n_applied=$((n_applied + 1))
      else
        echo "    FAIL: does not apply to $dir"
        echo "          The checkout may be on a different version than the patch"
        echo "          targets. Check: git -C $dir describe --tags"
        n_fail=$((n_fail + 1))
      fi
      ;;
  esac
done

printf '\n== summary ==\n'
printf '    applied %d, skipped %d, failed %d\n' "$n_applied" "$n_skipped" "$n_fail"
[[ $n_fail -gt 0 ]] && exit 1
exit 0
