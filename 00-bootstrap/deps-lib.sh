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
  local name="$1" v
  v="$(dep_version "$name")" || return 1
  [[ -n "$v" ]] || return 1
  printf '%s/%s/%s\n' "$DEPS_DIR" "$name" "$v"
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
