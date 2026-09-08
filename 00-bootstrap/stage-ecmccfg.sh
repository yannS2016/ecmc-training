#!/usr/bin/env bash
#
# stage-ecmccfg.sh -- build the flattened ecmccfg "install" this course needs.
#
# WHY
# ---
# ecmccfg cannot be used from its source tree.  Its ~2400 internal references
# look like:
#
#     ${ecmccfg_DIR}addSlave.cmd          -> actually lives in scripts/
#     ${ecmccfg_DIR}ecmcEL3202-0010.cmd   -> actually lives in hardware/Beckhoff_3XXX/EL/
#     dbLoadRecords("ecmcEcPrevSlave.db") -> actually lives in db/core/
#
# i.e. every script and template is addressed by BARE FILENAME.  At PSI/ESS the
# module builder (driver.makefile / require.Makefile) flattens the tree at
# install time and that is what ecmccfg_DIR points at.  We are not using that
# builder, so we reproduce the same flattening here.
#
# This is NOT a workaround for skipping `require` -- a require-based site needs
# exactly the same flattening, it just gets it for free.  See appendix-require.md.
#
# The layout produced mirrors the SCRIPTS/TEMPLATES declarations in
# ecmccfg/GNUmakefile, so it stays faithful if ecmccfg is upgraded.
#
# Safe to re-run.  ecmccfg's source tree is only ever read.

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
  echo "       cp $repo/site.conf.example $repo/site.conf and edit it." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$repo/site.conf"

: "${ECMCCFG_SRC:?ECMCCFG_SRC must be set in site.conf}"
STAGE="${ECMCCFG_STAGE:-$repo/stage/ecmccfg}"

if [[ ! -f "$ECMCCFG_SRC/startup.cmd" ]]; then
  echo "ERROR: '$ECMCCFG_SRC' does not look like an ecmccfg checkout" >&2
  echo "       (no startup.cmd found)." >&2
  exit 1
fi

echo "==> staging ecmccfg"
echo "    from : $ECMCCFG_SRC"
echo "    to   : $STAGE"

rm -rf "$STAGE"
mkdir -p "$STAGE/db"

# --- 1. scripts, flattened --------------------------------------------------
# Mirrors GNUmakefile: SCRIPTS += scripts/*, scripts/jinja2/*,
# scripts/jinja2/templates/*.jinja2, naming/*, general/*, motion/*, protocol/*,
# hardware/*/*.cmd, hardware/<vendor>/*/*.cmd, plus startup.cmd itself.
script_srcs=(
  "$ECMCCFG_SRC"/startup.cmd
  "$ECMCCFG_SRC"/scripts/*
  "$ECMCCFG_SRC"/scripts/jinja2/*
  "$ECMCCFG_SRC"/scripts/jinja2/templates/*.jinja2
  "$ECMCCFG_SRC"/naming/*
  "$ECMCCFG_SRC"/general/*
  "$ECMCCFG_SRC"/motion/*
  "$ECMCCFG_SRC"/protocol/*
  "$ECMCCFG_SRC"/hardware/*/*.cmd
  "$ECMCCFG_SRC"/hardware/*/*/*.cmd
)

n_scripts=0
for f in "${script_srcs[@]}"; do
  [[ -f "$f" ]] || continue
  cp -p "$f" "$STAGE/${f##*/}"
  n_scripts=$((n_scripts + 1))
done

# --- 2. db templates, flattened into db/ ------------------------------------
n_db=0
while IFS= read -r -d '' f; do
  cp -p "$f" "$STAGE/db/${f##*/}"
  n_db=$((n_db + 1))
done < <(find "$ECMCCFG_SRC/db" -maxdepth 2 \
           \( -name '*.db' -o -name '*.template' \
              -o -name '*.substitutions' -o -name '*.subs' \) \
           -type f -print0)

echo "    staged $n_scripts scripts, $n_db templates"

# --- 3. collision check -----------------------------------------------------
# Flattening is only safe while basenames are unique.  If a future ecmccfg
# introduces two files with the same name in different directories, one would
# silently shadow the other and produce a bug that is very hard to find.
# Fail here instead.
check_collisions() {
  local label="$1"; shift
  local dupes f
  # Pure-shell basename: spawning one basename process per file is
  # needlessly slow on large trees (ecmccfg stages ~1100 files).
  dupes="$(for f in "$@"; do echo "${f##*/}"; done | sort | uniq -d)"
  if [[ -n "$dupes" ]]; then
    echo "ERROR: basename collisions while flattening $label:" >&2
    echo "$dupes" | sed 's/^/       /' >&2
    echo "       Flattening would silently shadow one of each pair." >&2
    echo "       ecmccfg has probably been upgraded; reconcile before continuing." >&2
    return 1
  fi
  return 0
}

existing_scripts=()
for f in "${script_srcs[@]}"; do [[ -f "$f" ]] && existing_scripts+=("$f"); done
check_collisions "scripts" "${existing_scripts[@]}"

mapfile -t db_files < <(find "$ECMCCFG_SRC/db" -maxdepth 2 \
  \( -name '*.db' -o -name '*.template' \
     -o -name '*.substitutions' -o -name '*.subs' \) -type f)
check_collisions "db templates" "${db_files[@]}"

# --- 4. sanity: the entry points the course actually calls ------------------
for must in startup.cmd addSlave.cmd configureAxis.cmd setAppMode.cmd \
            applySubstitutions.cmd initAll.cmd; do
  if [[ ! -f "$STAGE/$must" ]]; then
    echo "ERROR: '$must' missing from the staged install." >&2
    echo "       ecmccfg layout may have changed; check GNUmakefile SCRIPTS." >&2
    exit 1
  fi
done

echo "==> ecmccfg staged OK"
echo
echo "    Use these in your st.cmd (note the trailing slash on ecmccfg_DIR --"
echo "    ecmccfg concatenates it directly, as \${ecmccfg_DIR}addSlave.cmd):"
echo
echo "        epicsEnvSet(\"ecmccfg_DIR\", \"$STAGE/\")"
echo "        epicsEnvSet(\"ecmccfg_DB\",  \"$STAGE/db\")"
echo
