#!/usr/bin/env bash
#
# stage-ecmccomp.sh -- flatten the ecmccomp module, same as stage-ecmccfg.sh.
#
# WHY A FOURTH REPOSITORY
# -----------------------
# ecmccfg's applyComponent.cmd is only a wrapper. The actual component
# definitions -- motor electrical parameters, drive control loop gains, encoder
# protocol settings -- live in ecmccomp, a separate module:
#
#   ecmccfg/scripts/applyComponent.cmd
#     -> require ecmccomp
#     -> ${ecmccomp_DIR}applyComponent.cmd
#     -> the component file for COMP=<name>
#
# Its own docstring says "Only for use if the ecmccomp module is accessible (at
# PSI)", but the repository is public:
#   https://github.com/paulscherrerinstitute/ecmccomp
#
# You need it for any hardware whose configuration was moved out of ecmccfg into
# the component system -- which includes the EL7062 used in this course.
# ecmccfg ships 302 motor configs and none of them are for the EL7062.
#
# Like ecmccfg, ecmccomp is addressed by bare filename and must be flattened.
#
# Safe to re-run. The ecmccomp source tree is only ever read.

set -euo pipefail

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  echo "ERROR: do not run this as root -- it creates root-owned files a normal" >&2
  echo "       user then cannot clean up or overwrite. Only install-deps.sh needs sudo." >&2
  exit 1
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"

if [[ ! -f "$repo/site.conf" ]]; then
  echo "ERROR: $repo/site.conf not found." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$repo/site.conf"

if [[ -z "${ECMCCOMP_SRC:-}" ]]; then
  echo "NOTE: ECMCCOMP_SRC not set in site.conf -- skipping ecmccomp."
  echo "      Phase 03 needs it (EL7062 component configuration)."
  echo "      git clone https://github.com/paulscherrerinstitute/ecmccomp"
  exit 0
fi

STAGE="${ECMCCOMP_STAGE:-$repo/stage/ecmccomp}"

if [[ ! -d "$ECMCCOMP_SRC" ]]; then
  echo "ERROR: ECMCCOMP_SRC '$ECMCCOMP_SRC' does not exist." >&2
  exit 1
fi

echo "==> staging ecmccomp"
echo "    from : $ECMCCOMP_SRC"
echo "    to   : $STAGE"

rm -rf "$STAGE"
mkdir -p "$STAGE/db"

# Components are organised by category (motors/, encoders/, drive_slaves/, ...)
# in the source and flattened on install, exactly like ecmccfg's hardware/ tree.
n=0
while IFS= read -r -d '' f; do
  cp -p "$f" "$STAGE/${f##*/}"
  n=$((n + 1))
done < <(find "$ECMCCOMP_SRC" \
           -path '*/.git' -prune -o \
           \( -name '*.cmd' -o -name '*.script' \) -type f -print0)

n_db=0
if [[ -d "$ECMCCOMP_SRC/db" ]]; then
  while IFS= read -r -d '' f; do
    cp -p "$f" "$STAGE/db/${f##*/}"
    n_db=$((n_db + 1))
  done < <(find "$ECMCCOMP_SRC/db" -maxdepth 2 \
             \( -name '*.db' -o -name '*.template' \
                -o -name '*.substitutions' -o -name '*.subs' \) -type f -print0)
fi

echo "    staged $n scripts, $n_db templates"

# Same collision guard as ecmccfg: flattening is only safe while basenames are
# unique.
dupes="$(find "$ECMCCOMP_SRC" -path '*/.git' -prune -o \
           \( -name '*.cmd' -o -name '*.script' \) -type f -print \
         | while read -r f; do echo "${f##*/}"; done | sort | uniq -d)"
if [[ -n "$dupes" ]]; then
  echo "ERROR: basename collisions while flattening ecmccomp:" >&2
  echo "$dupes" | sed 's/^/       /' >&2
  exit 1
fi

if [[ ! -f "$STAGE/applyComponent.cmd" ]]; then
  echo "ERROR: applyComponent.cmd missing from the staged ecmccomp." >&2
  echo "       ecmccomp layout may have changed; check its GNUmakefile." >&2
  exit 1
fi

echo "==> ecmccomp staged OK"
echo
echo "        epicsEnvSet(\"ecmccomp_DIR\", \"$STAGE/\")"
echo
