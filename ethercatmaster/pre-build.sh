#!/usr/bin/env bash
#
# pre-build.sh -- verify this host can build the IgH EtherCAT master,
#                 and optionally apply the compatibility patches it needs.
#
# Run this BEFORE ./configure. Every check maps to something the build or the
# runtime genuinely needs, and each failure quotes the BUILD.md section that
# explains why it matters.
#
#   FAIL  blocks the build      -- fix before continuing
#   WARN  degrades but proceeds -- read it; see the summary for what each means
#
# Exit status: 0 if no FAIL, 1 otherwise.
#
#   ./pre-build.sh                       # check only, change nothing
#   ./pre-build.sh --apply               # also apply any missing required patch
#   ./pre-build.sh /path/to/ethercat     # say where the checkout is
#   ./pre-build.sh --patches /some/dir   # only if this script was copied away
#                                        # from its own patches/ directory
#   EC_SRC=/path/to/ethercat ./pre-build.sh
#   E1000E_KERNEL=6.12 ./pre-build.sh    # probe a non-default --with-e1000e-kernel
#
# Without --apply this script is strictly read-only. With it, the only thing it
# writes is `git apply` of a patch from patches/ into the ethercat checkout,
# and only when the running kernel actually requires that patch.
#
set -uo pipefail

APPLY=0
ARG_SRC=""
PATCHES=""

usage() {
  sed -n "2,25p" "${BASH_SOURCE[0]}" | sed "s/^#//; s/^ //"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)        APPLY=1; shift ;;
    --patches)      PATCHES="${2:-}"; shift 2 ;;
    --patches=*)    PATCHES="${1#*=}"; shift ;;
    -h|--help)      usage 0 ;;
    -*)             echo "unknown option: $1" >&2; usage 1 ;;
    *)              ARG_SRC="$1"; shift ;;
  esac
done


n_fail=0
n_warn=0
pass() { printf '  [ PASS ]  %s\n' "$1"; }
warn() { printf '  [ WARN ]  %s\n' "$1"; n_warn=$((n_warn+1)); }
fail() { printf '  [ FAIL ]  %s\n' "$1"; n_fail=$((n_fail+1)); }
skip() { printf '  [ ---- ]  %s\n' "$1"; }
why()  { printf '            %s\n' "$1"; }
hdr()  { printf '\n== %s ==\n' "$1"; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The patch set ships beside this script, so it is found without being told.
# --patches exists only for the case where this script has been copied away
# from the repository it belongs to.
PATCHES="${PATCHES:-$here/patches}"

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
[[ -n "$ARG_SRC" ]] && EC_SRC="$ARG_SRC"
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
    # The compatibility patches deliberately modify the checkout, so a dirty
    # tree is expected. Whether each patch is APPLIED is answered properly by
    # the backport probes below, against the kernel that actually matters; all
    # this looks for is edits nobody accounted for. See patches/README.md.
    unexpected="$(git -C "$EC_SRC" status --porcelain 2>/dev/null \
                  | awk '{print $NF}' \
                  | grep -vxE 'master/cdev\.c|master/module\.c' || true)"
    if [[ -n "$unexpected" ]]; then
      warn "checkout modified outside the compatibility patches:"
      while read -r f; do [[ -n "$f" ]] && why "  $f"; done <<< "$unexpected"
      why  "Only master/cdev.c and master/module.c are accounted for. Anything"
      why  "else is an undocumented local edit."
    else
      pass "no unaccounted-for local edits"
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
  # E1000E_KERNEL overrides which devices/e1000e/netdev-<ver>-*.c snapshot to
  # test for, e.g. E1000E_KERNEL=6.12 ./pre-build.sh -- matching
  # --with-e1000e-kernel=<ver> at configure time. Defaults to the running
  # kernel's own $LV, same as configure.ac does when the flag is omitted.
  #
  # This is a FILENAME MATCH, same as configure.ac itself, and proves nothing
  # about whether the code compiles. That caveat matters MORE here than for
  # the default case: no file in devices/e1000e/, at ANY shipped version, has
  # a single LINUX_VERSION_CODE guard (verified across the full 3.2-6.12
  # range). So picking a non-default version is not "the guarded branch of
  # this driver" -- it swaps in a wholesale different, equally unguarded
  # driver snapshot (every module: netdev, ethtool, mac, hw, nvm, phy, ptp...)
  # forked from a different point in mainline. A pass here is not a signal
  # that override will compile against this kernel; only `make` can tell you
  # that. See BUILD.md section 5 and INSTALL.md section 9.
  E1000E_KERNEL="${E1000E_KERNEL:-$LV}"
  if [[ "$E1000E_KERNEL" != "$LV" ]]; then
    why  "E1000E_KERNEL=$E1000E_KERNEL overrides the running kernel ($LV)."
    why  "A pass below is a filename match only -- see BUILD.md section 5."
  fi
  chk e1000e "ls $D/e1000e/netdev-$E1000E_KERNEL-*.c >/dev/null 2>&1"
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
# RHEL backport probes
#
# The two known build failures on el9 are LINUX_VERSION_CODE guards that pick
# the wrong branch because Red Hat backported a newer API into a kernel still
# numbered 5.14 (BUILD.md section 5). Both are visible in the headers before
# anything is compiled, so look.
# ---------------------------------------------------------------------------
#
# Two independent questions, and answering only the first is what let a
# reverted patch reach `make`:
#
#   needed?   read the KERNEL headers -- has Red Hat backported the newer API?
#   applied?  read the CHECKOUT -- does the guard carry a RHEL_RELEASE_CODE test?
#
# needed && !applied is a hard blocker: the build WILL fail, and knowing that
# now costs a second instead of a full compile.
#
probe() {   # probe <n> <needed 0|1> <source file> <symptom>
  local n="$1" needed="$2" src="$3" symptom="$4" applied=0 pfile=""
  if [[ $have_src -eq 1 && -r "$EC_SRC/$src" ]]; then
    grep -q 'RHEL_RELEASE_CODE' "$EC_SRC/$src" && applied=1
  else
    applied=-1
  fi

  # Required but missing. With --apply, fix it here rather than reporting a
  # problem and letting the operator walk into the compile anyway.
  if [[ $needed -eq 1 && $applied -eq 0 && $APPLY -eq 1 ]]; then
    pfile="$(ls "$PATCHES/$n"-*.patch 2>/dev/null | head -1)"
    if [[ -z "$pfile" ]]; then
      fail "patch $n required, not applied, and not found in $PATCHES"
      why  "Pass --patches <dir> if the patch set lives elsewhere."
      return
    fi
    if git -C "$EC_SRC" apply --check "$pfile" 2>/dev/null \
       && git -C "$EC_SRC" apply "$pfile"; then
      pass "patch $n applied just now ($(basename "$pfile"))"
      return
    fi
    fail "patch $n required but does not apply cleanly"
    why  "$(basename "$pfile") conflicts with this checkout."
    why  "Check the tag: it is written for 1.6.12."
    return
  fi

  if [[ $needed -eq 1 && $applied -eq 1 ]]; then
    pass "patch $n needed and applied ($src)"
  elif [[ $needed -eq 1 && $applied -eq 0 ]]; then
    fail "patch $n IS REQUIRED but NOT applied -- $src"
    why  "$symptom"
    why  "Fix it: re-run with --apply"
    why  "    $0 --apply"
  elif [[ $needed -eq 1 ]]; then
    warn "patch $n is required by this kernel; no checkout to verify it against"
  elif [[ $applied -eq 1 ]]; then
    warn "patch $n applied but this kernel does not need it ($src)"
    why  "Harmless -- the added guard simply never fires. Worth knowing if you"
    why  "are moving this checkout between kernels."
  else
    pass "patch $n not needed on this kernel"
  fi
}

hdr "RHEL backport probes -- needed here, and actually applied?"
if [[ -r "$KDIR/Makefile" ]]; then
  mm="$KDIR/include/linux/mm.h"
  if [[ ! -r "$mm" ]]; then
    skip "cannot read $mm -- apply patch 0001 and let the compiler decide"
  else
    grep -q 'vm_flags_set' "$mm" && n1=1 || n1=0
    probe 0001 "$n1" master/cdev.c \
      "master/cdev.c:233 assigns to a const vm_flags on this kernel."
  fi

  cls="$KDIR/include/linux/device/class.h"
  [[ -r "$cls" ]] || cls="$KDIR/include/linux/device.h"
  if [[ ! -r "$cls" ]]; then
    skip "no class_create() declaration found -- let the compiler decide"
  else
    grep -qE 'class_create\(const char \*' "$cls" && n2=1 || n2=0
    probe 0002 "$n2" master/module.c \
      "master/module.c:115 passes THIS_MODULE where a name is expected."
  fi
else
  skip "skipped -- no kernel build tree to inspect"
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
  echo "  All checks passed. Continue with INSTALL.md step 3 (configure)."
elif [[ $n_fail -eq 0 ]]; then
  echo "  $n_warn warning(s), no blockers. Continue with INSTALL.md step 3."
  echo "  Read each WARN -- they mean different things:"
  echo "    driver availability  -> that driver is unavailable; 'generic' still works"
  echo "    patch applied/unneeded -> harmless; the guard never fires on this kernel"
  echo "    checkout modified    -> something outside the patches was edited by hand"
else
  echo "  $n_fail blocker(s), $n_warn warning(s). Fix the FAIL lines first."
  if [[ $APPLY -eq 0 ]]; then
    echo "  If they are missing patches, this script can apply them:"
    echo "      $0 --apply"
  fi
fi
echo

if [[ $n_fail -gt 0 ]]; then
  exit 1
fi
exit 0
