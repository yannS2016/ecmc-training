#!/usr/bin/env bash
#
# deps-lib.sh -- shared lookup for the source-dependency tree.
#
# Source dependencies live at $DEPS_DIR/<package>/<version>, one directory per
# version so several can coexist and each consumer pins the one it wants.
#
# That means nothing may hardcode a dependency path: the version lives in
# deps.conf, and everything else resolves it from there. This file is what
# bootstrap.sh and preflight.sh use to do that, so there is exactly one
# definition of where a package is.
#
# Source it, do not run it:
#     source "$here/deps-lib.sh"
#     ruckig_dir="$(dep_dir ruckig)"

# Directory holding deps.conf. Set by the caller if it differs.
: "${DEPS_CONF_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
: "${DEPS_DIR:=}"

# dep_version <name> -- the version pinned in deps.conf, or empty.
dep_version() {
  local name="$1" conf="$DEPS_CONF_DIR/deps.conf"
  [[ -f "$conf" ]] || return 1
  sed 's/[[:space:]]*#.*$//' "$conf" \
    | awk -v n="$name" '$1 == n { print $3; exit }'
}

# dep_dir <name> -- full path to the pinned version, or empty if not declared.
dep_dir() {
  local name="$1" v r
  v="$(dep_version "$name")" || return 1
  [[ -n "$v" ]] || return 1
  # The directory is named by the SITE release (R0.19.4), not the upstream ref
  # (v0.19.4). See release_name below.
  r="$(dep_release "$name")"
  printf '%s/%s/%s\n' "$DEPS_DIR" "$name" "$r"
}

# ---------------------------------------------------------------------------
# EPICS module paths.
#
# Module trees may be versioned -- $EPICS_MODULES/<module>/<version>, the PCDS
# convention -- or flat. The version comes from <NAME>_MODULE_VERSION in
# site.conf; empty or unset means flat.
#
#     module_dir asyn   ->  $EPICS_MODULES/asyn/R4.42-1.0.0
#                       or  $EPICS_MODULES/asyn        (if no version set)
# ---------------------------------------------------------------------------
module_version() {
  local name="$1" var
  var="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')_MODULE_VERSION"
  printf '%s' "${!var:-}"
}

module_dir() {
  local name="$1" v
  v="$(module_version "$name")"
  if [[ -n "$v" ]]; then
    printf '%s/%s/%s\n' "${EPICS_MODULES:-}" "$name" "$v"
  else
    printf '%s/%s\n' "${EPICS_MODULES:-}" "$name"
  fi
}

# ---------------------------------------------------------------------------
# Source-dependency release naming.
#
# Two different names for the same thing, and they must not be confused:
#
#   upstream ref     what you check out from git: ruckig tags as "v0.19.4"
#   release name     what the directory is called here: "R0.19.4"
#
# The site convention is RX.Y.Z, matching the EPICS module tree (asyn/R4.42-1.0.0).
# Upstream projects use whatever they like, so the ref is translated:
# strip a leading v or V, prepend R.
#
# A package whose upstream naming does not survive that can override it in
# deps.conf with --release=<name> in the options field.
# ---------------------------------------------------------------------------
release_name() {
  local v="$1"
  v="${v#v}"; v="${v#V}"
  printf 'R%s\n' "$v"
}

# dep_options <name> -- the options field from deps.conf, or empty.
dep_options() {
  local name="$1" conf="$DEPS_CONF_DIR/deps.conf"
  [[ -f "$conf" ]] || return 1
  sed 's/[[:space:]]*#.*$//' "$conf" \
    | awk -v n="$name" '$1 == n { $1=""; $2=""; $3=""; $4=""; sub(/^ +/,""); print; exit }'
}

# dep_release <name> -- release directory name, honouring any --release= override.
dep_release() {
  local name="$1" opts tok
  opts="$(dep_options "$name")"
  for tok in $opts; do
    if [[ "$tok" == --release=* ]]; then
      printf '%s\n' "${tok#--release=}"
      return 0
    fi
  done
  release_name "$(dep_version "$name")"
}
