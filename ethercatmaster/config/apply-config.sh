#!/usr/bin/env bash
#
# apply-config.sh -- write this site's EtherCAT configuration into /etc.
#
# Why this exists: none of the EtherCAT master's configuration lives inside its
# source tree. `./configure` output is gitignored build product, and the master
# INSTALLS its ethercat.conf template to /etc. So the site settings cannot be
# carried as a patch against the upstream checkout -- they are tracked here and
# applied by this script instead. The upstream tree stays pristine and
# upgradable.
#
# Idempotent: safe to re-run. Existing files are backed up once, to *.orig.
#
#   ./apply-config.sh --dry-run     show what would change, touch nothing
#   sudo ./apply-config.sh          apply
#
# Run AFTER `make modules_install install` (INSTALL.md step 4), because
# /etc/ethercat.conf does not exist until then.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY=0
[[ "${1:-}" == "--dry-run" || "${1:-}" == "-n" ]] && DRY=1

# shellcheck disable=SC1091
source "$here/site-ethercat.env"

: "${MASTER0_DEVICE:?set MASTER0_DEVICE in site-ethercat.env}"
: "${DEVICE_MODULES:?set DEVICE_MODULES in site-ethercat.env}"
ECMC_GROUP="${ECMC_GROUP:-ethercat}"
ETHERLAB="${ETHERLAB:-/opt/etherlab}"

say()  { printf '  %s\n' "$*"; }
hdr()  { printf '\n== %s ==\n' "$*"; }
run()  { if [[ $DRY -eq 1 ]]; then printf '  would: %s\n' "$*"; else eval "$@"; fi; }

if [[ $DRY -eq 0 && $EUID -ne 0 ]]; then
  echo "ERROR: writing to /etc needs root. Use: sudo $0   (or --dry-run)" >&2
  exit 1
fi

# --- 1. /etc/ethercat.conf --------------------------------------------------
# Edited in place rather than replaced: the file is installed from the master's
# own template, and a future master version may add variables we do not know
# about. Rewriting it wholesale would silently drop them.
hdr "/etc/ethercat.conf"
CONF=/etc/ethercat.conf
if [[ ! -f $CONF ]]; then
  echo "  ERROR: $CONF missing -- run 'make modules_install install' first." >&2
  exit 1
fi
[[ -f $CONF.orig ]] || run "cp -p '$CONF' '$CONF.orig'"

set_var() {           # set_var NAME VALUE
  local n="$1" v="$2"
  if grep -qE "^[[:space:]]*${n}=" "$CONF"; then
    if [[ $DRY -eq 1 ]]; then
      local cur; cur="$(grep -E "^[[:space:]]*${n}=" "$CONF" | head -1)"
      [[ "$cur" == "${n}=\"${v}\"" ]] && say "unchanged  ${n}=\"${v}\"" \
                                      || say "change     ${cur}  ->  ${n}=\"${v}\""
    else
      sed -i -E "s|^[[:space:]]*${n}=.*|${n}=\"${v}\"|" "$CONF"
      say "set        ${n}=\"${v}\""
    fi
  else
    run "printf '\n%s=\"%s\"\n' '$n' '$v' >> '$CONF'"
    say "appended   ${n}=\"${v}\""
  fi
}
set_var MASTER0_DEVICE   "$MASTER0_DEVICE"
set_var DEVICE_MODULES   "$DEVICE_MODULES"
set_var UPDOWN_INTERFACES "${UPDOWN_INTERFACES:-}"
[[ -n "${MASTER0_BACKUP:-}" ]] && set_var MASTER0_BACKUP "$MASTER0_BACKUP"

# --- 2. systemd drop-in -----------------------------------------------------
# Which drop-in depends on the driver: generic needs the network up first,
# native must run before the network tools see the NIC disappear.
hdr "systemd ordering drop-in"
if [[ "$DEVICE_MODULES" == *generic* ]]; then src=50-dependencies-generic.conf
else                                          src=50-dependencies-native.conf; fi
say "DEVICE_MODULES=\"$DEVICE_MODULES\"  ->  $src"
run "mkdir -p /etc/systemd/system/ethercat.service.d"
run "install -m 0644 '$here/$src' /etc/systemd/system/ethercat.service.d/50-dependencies.conf"
run "systemctl daemon-reload"

# --- 3. device permissions --------------------------------------------------
hdr "device permissions"
if getent group "$ECMC_GROUP" >/dev/null 2>&1; then say "group '$ECMC_GROUP' exists"
else run "groupadd -f '$ECMC_GROUP'"; say "created group '$ECMC_GROUP'"; fi
run "install -m 0644 '$here/99-EtherCAT.rules' /etc/udev/rules.d/99-EtherCAT.rules"
run "udevadm control --reload-rules"
# Adding a user to this group grants write access to the bus -- ethercat
# download, sii_write and foe_write all go through the same device node. That
# is a privilege decision, so it stays explicit rather than happening here.
# But an empty group is a guaranteed dead end (Permission denied on
# /dev/EtherCAT0), so say so loudly rather than as a footnote.
if [[ -z "$(getent group "$ECMC_GROUP" | cut -d: -f4)" ]]; then
  say "WARNING: group '$ECMC_GROUP' has no members -- nothing can open /dev/EtherCAT0"
  say "         fix:   sudo usermod -aG $ECMC_GROUP \$USER   then log out and in"
  say "         check: id | grep $ECMC_GROUP"
else
  say "group members: $(getent group "$ECMC_GROUP" | cut -d: -f4)"
fi

# --- 4. linker path ---------------------------------------------------------
hdr "linker path"
run "install -m 0644 '$here/ld-etherlab.conf' /etc/ld.so.conf.d/ethercat.conf"
run "ldconfig"

# --- 5. realtime limits -----------------------------------------------------
hdr "realtime limits"
run "install -m 0644 '$here/99-ecmc-realtime.conf' /etc/security/limits.d/99-ecmc-realtime.conf"

hdr "done"
if [[ $DRY -eq 1 ]]; then
  say "dry run -- nothing was written."
else
  say "systemctl restart ethercat   # then: $ETHERLAB/bin/ethercat master"
fi
