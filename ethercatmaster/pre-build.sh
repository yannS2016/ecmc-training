#!/usr/bin/env bash
#
# pre-build.sh -- verify this host can build the IgH EtherCAT master.
#
# Run this BEFORE ./configure. Every check maps to something the build or the
# runtime genuinely needs, and each failure quotes the BUILD.md section that
# explains why it matters.
#
#   FAIL  blocks the build      -- fix before continuing
#   WARN  degrades but proceeds -- usually means "generic driver only"
#
# Exit status: 0 if no FAIL, 1 otherwise.
#
#   ./pre-build.sh                          # auto-detect the ethercat checkout
#   ./pre-build.sh /path/to/ethercat        # or say where it is
#   EC_SRC=/path/to/ethercat ./pre-build.sh

set -uo pipefail

n_fail=0
n_warn=0
pass() { printf '  [ PASS ]  %s\n' "$1"; }
warn() { printf '  [ WARN ]  %s\n' "$1"; n_warn=$((n_warn+1)); }
fail() { printf '  [ FAIL ]  %s\n' "$1"; n_fail=$((n_fail+1)); }
skip() { printf '  [ ---- ]  %s\n' "$1"; }
why()  { printf '            %s\n' "$1"; }
hdr()  { printf '\n== %s ==\n' "$1"; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# host
# ---------------------------------------------------------------------------
hdr "host"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  pass "distro: ${PRETTY_NAME:-unknown}"
  case "${ID:-}:${VERSION_ID:-}" in
    rocky:8*|rhel:8*|almalinux:8*|centos:8*)
      warn "RHEL 8 ships kernel 4.18; no native EtherCAT driver exists for it"
      why  "Generic driver only. See BUILD.md section 6."
      ;;
  esac
else
  warn "no /etc/os-release -- is this a Linux host?"
fi

KREL="$(uname -r)"
LV="$(printf '%s' "$KREL" | grep -oE '^[0-9]+\.[0-9]+')"
pass "kernel: $KREL"
if [[ -n "$LV" ]]; then
  pass "native drivers will be matched on: $LV"
  why  "configure keeps only the first two components (BUILD.md section 4b)."
else
  fail "cannot parse a version from '$KREL'"
fi

# ---------------------------------------------------------------------------
# kernel build scaffolding
#
# This is kernel-devel: headers, Makefile, Kbuild, .config, Module.symvers.
# It is NOT the kernel source tree -- the .c files are not needed to build an
# out-of-tree module, only to diff drivers (BUILD.md section 5).
# ---------------------------------------------------------------------------
hdr "kernel-devel"
KDIR="/usr/src/kernels/$KREL"
[[ -r "$KDIR/Makefile" ]] || KDIR="/lib/modules/$KREL/build"

if [[ -r "$KDIR/Makefile" ]]; then
  pass "kernel build tree: $KDIR"
  krel_file="$KDIR/include/config/kernel.release"
  if [[ -r "$krel_file" ]]; then
    got="$(cat "$krel_file" 2>/dev/null)"
    if [[ "$got" == "$KREL" ]]; then
      pass "kernel.release matches the running kernel"
    else
      fail "kernel.release says '$got' but you are running '$KREL'"
      why  "Building against a mismatched tree produces a module that modprobe"
      why  "rejects with 'Invalid module format'. BUILD.md section 2."
    fi
  else
    warn "no $krel_file -- cannot confirm the tree matches the running kernel"
  fi
else
  fail "no kernel build tree for $KREL"
  why  "You need kernel-devel -- headers and build scaffolding, NOT the full"
  why  "kernel source tree. Install the version matching the running kernel:"
  why  "    sudo dnf install -y kernel-devel-\$(uname -r) elfutils-libelf-devel"
  why  "If dnf reports no match, the running kernel is older than the repos"
  why  "(superseded kernels are rotated out of AppStream). Then either:"
  why  "    sudo dnf install -y kernel kernel-devel && sudo reboot"
  why  "or fetch the exact version from the Rocky vault. BUILD.md section 8."
fi

# ---------------------------------------------------------------------------
# toolchain
# ---------------------------------------------------------------------------
hdr "toolchain"
for t in gcc make perl; do
  if command -v "$t" >/dev/null 2>&1; then pass "$t present"
  else fail "$t not found"; fi
done
for t in autoconf automake libtool; do
  if command -v "$t" >/dev/null 2>&1; then
    pass "$t present"
  else
    fail "$t not found"
    why  "./bootstrap generates the configure script; it is not in the repo."
  fi
done
if command -v pkg-config >/dev/null 2>&1; then
  pass "pkg-config present"
else
  warn "pkg-config not found"
  why  "configure queries it for systemdsystemunitdir; without it the"
  why  "ethercat.service unit is silently not installed."
fi
if [[ -r /usr/include/libelf.h ]]; then
  pass "libelf headers present (modpost links against them)"
else
  warn "libelf headers not found"
  why  "sudo dnf install -y elfutils-libelf-devel"
fi

# ---------------------------------------------------------------------------
# secure boot
# ---------------------------------------------------------------------------
hdr "secure boot"
if command -v mokutil >/dev/null 2>&1; then
  if mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    warn "Secure Boot is ENABLED"
    why  "Unsigned out-of-tree modules will not load. Enrol a MOK, or accept"
    why  "the boot-integrity trade of turning it off. BUILD.md section 8."
  else
    pass "Secure Boot not enabled"
  fi
else
  pass "mokutil absent (legacy BIOS -- not a concern)"
fi

# ---------------------------------------------------------------------------
# the ethercat checkout
#
# Resolution order: argument, $EC_SRC, then the usual places -- including the
# sibling layout this course uses (<parent>/ethercat next to <parent>/training).
# ---------------------------------------------------------------------------
hdr "ethercat checkout"
[[ -n "${1:-}" ]] && EC_SRC="$1"
if [[ -z "${EC_SRC:-}" ]]; then
  for c in "$here/../../ethercat" ./ethercat ../ethercat \
           "$HOME/src/ethercat" /usr/local/src/ethercat /opt/src/ethercat; do
    if [[ -d "$c/devices" ]]; then EC_SRC="$(cd "$c" && pwd)"; break; fi
  done
fi
EC_SRC="${EC_SRC:-}"

have_src=0
if [[ -n "$EC_SRC" && -d "$EC_SRC/devices" ]]; then
  have_src=1
  pass "checkout: $EC_SRC"
  if desc="$(git -C "$EC_SRC" describe --tags 2>/dev/null)"; then
    if [[ "$desc" == "1.6.12" ]]; then
      pass "on tag 1.6.12"
    else
      warn "at '$desc', not tag 1.6.12"
      why  "INSTALL.md step 2 pins it: git checkout -b build-1.6.12 1.6.12"
    fi
    if [[ -n "$(git -C "$EC_SRC" status --porcelain 2>/dev/null)" ]]; then
      warn "checkout has local modifications -- provenance is not verifiable"
    fi
  else
    warn "not a git checkout -- cannot confirm the version"
  fi
else
  fail "no ethercat checkout found${EC_SRC:+ at '$EC_SRC'}"
  why  "Clone it, or pass the path as an argument / set EC_SRC:"
  why  "    git clone https://gitlab.com/etherlab.org/ethercat.git ~/src/ethercat"
  why  ""
  why  "Driver availability is SKIPPED below rather than reported as"
  why  "'NOT available' -- a missing tree is not an unsupported kernel."
fi

# ---------------------------------------------------------------------------
# native driver availability
#
# Each test mirrors that driver's own check in configure.ac. Note the two file
# layouts: e1000e/igb/igc and modern r8169 live in per-driver subdirectories,
# while pre-4.4 r8169 sits as flat files in devices/.
# ---------------------------------------------------------------------------
if [[ $have_src -eq 1 && -n "$LV" ]]; then
  hdr "native driver availability for kernel $LV"
  D="$EC_SRC/devices"
  chk() {   # chk <driver> <test expression>
    if eval "$2"; then
      pass "$1 -- --enable-$1 will pass configure"
    else
      warn "$1 not available for $LV"
    fi
  }
  chk e1000e "ls $D/e1000e/netdev-$LV-*.c >/dev/null 2>&1"
  chk igb    "test -f $D/igb/igb_main-$LV-orig.c"
  chk igc    "test -f $D/igc/igc_main-$LV-orig.c"
  # Two globs in one `ls` would fail whenever EITHER is absent, so test both
  # r8169 layouts separately.
  chk r8169  "ls $D/r8169-$LV-*.c >/dev/null 2>&1 || ls $D/r8169/r8169_main-$LV-*.c >/dev/null 2>&1"
  pass "generic -- always available, works with any NIC"
  why  "Passing configure is a filename match, not proof the driver compiles"
  why  "against a RHEL kernel carrying backports. BUILD.md sections 4c and 5."
else
  hdr "native driver availability"
  skip "skipped -- no checkout to inspect"
fi

# ---------------------------------------------------------------------------
# network interfaces
# ---------------------------------------------------------------------------
hdr "network interfaces"
if [[ -d /sys/class/net ]]; then
  candidates=0
  for i in /sys/class/net/*; do
    n="$(basename "$i")"
    [[ "$n" == "lo" ]] && continue
    drv="$(basename "$(readlink -f "$i/device/driver" 2>/dev/null)" 2>/dev/null)"
    [[ -z "$drv" || "$drv" == "." || "$drv" == "/" ]] && drv="none"
    mac="$(cat "$i/address" 2>/dev/null)"
    ip4=""
    if command -v ip >/dev/null 2>&1; then
      ip4="$(ip -4 -br addr show dev "$n" 2>/dev/null | awk '{print $3}')"
    fi
    if [[ -z "$ip4" ]]; then
      pass "$n  driver=$drv  mac=$mac  -- no IP, EtherCAT candidate"
      candidates=$((candidates+1))
    else
      skip "$n  driver=$drv  mac=$mac  ip=$ip4  -- in use, do not touch"
    fi
  done
  if [[ $candidates -eq 0 ]]; then
    warn "every interface has an IP -- no obvious dedicated NIC"
    why  "EtherCAT needs a whole card. Never share the management interface."
  elif [[ $candidates -gt 1 ]]; then
    why  "More than one candidate: pick by MAC in config/site-ethercat.env."
  fi
else
  warn "no /sys/class/net -- is this a Linux host?"
fi

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
hdr "summary"
if [[ $n_fail -eq 0 && $n_warn -eq 0 ]]; then
  echo "  All checks passed. Continue with INSTALL.md step 2."
elif [[ $n_fail -eq 0 ]]; then
  echo "  $n_warn warning(s), no blockers. Continue with INSTALL.md step 2."
  echo "  Re-read the WARN lines: they usually mean 'generic driver only'."
else
  echo "  $n_fail blocker(s), $n_warn warning(s). Fix the FAIL lines first."
fi
echo

if [[ $n_fail -gt 0 ]]; then
  exit 1
fi
exit 0
