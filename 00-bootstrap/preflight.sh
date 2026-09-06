#!/usr/bin/env bash
#
# preflight.sh -- verify this host can build and run the ecmc training IOCs.
#
# Run this FIRST, before anything else in the course.  Every check below maps
# to something ecmc genuinely needs at build or run time, and the reasoning is
# part of the course material: if you understand why each check is here, you
# understand what an ecmc IOC actually depends on.
#
#   FAIL  blocks the course       -- fix before continuing
#   WARN  degrades but proceeds   -- you can still work, with limits
#
# Exit status: 0 if no FAIL, 1 otherwise.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"

n_fail=0
n_warn=0

pass() { printf '  [ PASS ]  %s\n' "$1"; }
warn() { printf '  [ WARN ]  %s\n' "$1"; n_warn=$((n_warn+1)); }
fail() { printf '  [ FAIL ]  %s\n' "$1"; n_fail=$((n_fail+1)); }
why()  { printf '            %s\n' "$1"; }
hdr()  { printf '\n== %s ==\n' "$1"; }

# --- site.conf --------------------------------------------------------------
hdr "site configuration"
if [[ ! -f "$repo/site.conf" ]]; then
  fail "site.conf not found"
  why  "cp $repo/site.conf.example $repo/site.conf and edit it."
  echo
  echo "Cannot continue without site.conf."
  exit 1
fi
# shellcheck disable=SC1091
source "$repo/site.conf"
pass "site.conf loaded"

# --- EPICS base -------------------------------------------------------------
hdr "EPICS base"
if [[ -d "${EPICS_BASE:-}" ]]; then
  pass "EPICS_BASE = $EPICS_BASE"
else
  fail "EPICS_BASE '${EPICS_BASE:-<unset>}' does not exist"
  why  "Set it to the base version directory, e.g. /epics/base/7.0.7"
fi

if [[ -z "${EPICS_HOST_ARCH:-}" ]]; then
  if [[ -x "${EPICS_BASE:-}/startup/EpicsHostArch" ]]; then
    EPICS_HOST_ARCH="$("${EPICS_BASE}/startup/EpicsHostArch")"
  elif [[ -f "${EPICS_BASE:-}/startup/EpicsHostArch.pl" ]]; then
    EPICS_HOST_ARCH="$(perl "${EPICS_BASE}/startup/EpicsHostArch.pl" 2>/dev/null)"
  fi
fi
if [[ -n "${EPICS_HOST_ARCH:-}" ]]; then
  pass "EPICS_HOST_ARCH = $EPICS_HOST_ARCH"
else
  fail "could not determine EPICS_HOST_ARCH"
  why  "Set it explicitly in site.conf."
fi

base_ver_file="${EPICS_BASE:-}/configure/CONFIG_BASE_VERSION"
if [[ -f "$base_ver_file" ]]; then
  bv="$(awk -F= '
    /^EPICS_VERSION[ \t]*=/      { gsub(/[ \t]/,"",$2); v=$2 }
    /^EPICS_REVISION[ \t]*=/     { gsub(/[ \t]/,"",$2); r=$2 }
    /^EPICS_MODIFICATION[ \t]*=/ { gsub(/[ \t]/,"",$2); m=$2 }
    END { print v "." r "." m }' "$base_ver_file")"
  pass "EPICS base version $bv"
  case "$bv" in
    3.14.*|3.15.*)
      warn "ecmc targets EPICS 7; base $bv may not build"
      ;;
  esac
else
  warn "could not read base version from $base_ver_file"
fi

if [[ -x "${EPICS_BASE:-}/bin/${EPICS_HOST_ARCH:-none}/softIoc" ]]; then
  pass "base is built for $EPICS_HOST_ARCH"
else
  fail "no softIoc binary for ${EPICS_HOST_ARCH:-<unknown>} -- is base built?"
  why  "Expected ${EPICS_BASE:-}/bin/${EPICS_HOST_ARCH:-}/softIoc"
fi

# --- support modules --------------------------------------------------------
hdr "support modules"
mods="${EPICS_MODULES:-}"

check_module() {
  local name="$1" path="$2" lib="$3"
  if [[ ! -d "$path" ]]; then
    fail "$name not found at $path"
    return
  fi
  if [[ -n "$lib" ]]; then
    if ! ls "$path"/lib/"${EPICS_HOST_ARCH:-}"/lib"$lib".* >/dev/null 2>&1; then
      fail "$name present but not built for ${EPICS_HOST_ARCH:-<unknown>} (no lib$lib)"
      why  "Build it before building the training IOC."
      return
    fi
  fi
  pass "$name at $path"
}

check_module asyn  "$mods/asyn"  asyn
check_module motor "$mods/motor" motor
check_module ecmc  "$mods/ecmc"  ecmc

# Report which release each checkout sits on.  Both projects tag their releases
# as a matched pair -- ecmc "v11.0.8" and ecmccfg "11.0.8" (note: ecmccfg dropped
# the "v" prefix at 10.x).  This course is written for that pair; see
# ../VERSIONS.md.
report_checkout_version() {
  local name="$1" path="$2" want="$3"
  local desc sha date
  if ! command -v git >/dev/null 2>&1; then
    return
  fi
  if ! sha="$(git -C "$path" rev-parse --short HEAD 2>/dev/null)"; then
    warn "$name at $path is not a git checkout -- cannot record a version"
    return
  fi
  date="$(git -C "$path" log -1 --format=%cs 2>/dev/null)"
  desc="$(git -C "$path" describe --tags 2>/dev/null || true)"

  if [[ -z "$desc" ]]; then
    warn "$name at $sha ($date) -- no tag reachable"
    why  "Fetch tags: git -C $path fetch <upstream> --tags"
  elif [[ "$desc" == "$want" ]]; then
    pass "$name $desc ($date)"
  else
    warn "$name is at '$desc' ($date); this course targets '$want'"
    why  "See ../VERSIONS.md for how to check out the matched pair."
  fi

  if [[ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]]; then
    warn "$name checkout has uncommitted changes -- version is not reproducible"
  fi
}

# ecmc source checkout: headers, templates and the cpp_logic examples
if [[ -d "${ECMC_SRC:-}" ]]; then
  pass "ecmc source at $ECMC_SRC"
  report_checkout_version "ecmc" "$ECMC_SRC" "v11.0.8"
  if [[ -d "$ECMC_SRC/devEcmcSup/logic/db" ]]; then
    pass "cpp_logic templates present (needed in phase 04)"
  else
    warn "no devEcmcSup/logic/db -- this ecmc predates cpp_logic (11.0.7+)"
    why  "Phase 04 cpp_logic exercises will not be available."
  fi
else
  fail "ECMC_SRC '${ECMC_SRC:-<unset>}' does not exist"
fi

# ecmccfg source checkout: staged at runtime, but we compile ECATtimestamp from it
if [[ -f "${ECMCCFG_SRC:-}/startup.cmd" ]]; then
  pass "ecmccfg source at $ECMCCFG_SRC"
  report_checkout_version "ecmccfg" "$ECMCCFG_SRC" "11.0.8"
  # Phases 03/04 need an ecmccfg contemporary with ecmc 11.x. These scripts do
  # not exist in the v8.0.0 era.  Search the tree rather than assuming a
  # directory: at 11.0.8 the YAML loaders live in scripts/jinja2/, not scripts/.
  for need in loadYamlAxis.cmd loadYamlPlc.cmd loadCppLogic.cmd; do
    if [[ -z "$(find "$ECMCCFG_SRC" -name "$need" -not -path '*/.git/*' -print -quit 2>/dev/null)" ]]; then
      warn "ecmccfg has no $need -- checkout predates ecmc 11.x"
      why  "Phases 03/04 need it. Check out tag 11.0.8; see ../VERSIONS.md"
    fi
  done
  if [[ -f "$ECMCCFG_SRC/src/ECATtimestamp.cpp" ]]; then
    pass "ecmccfg ECATtimestamp source present (compiled into the IOC)"
  else
    warn "ecmccfg has no src/ECATtimestamp.cpp"
    why  "Remove it from ecmcTrainingIocApp/src/Makefile or the build will fail."
  fi
else
  fail "ECMCCFG_SRC '${ECMCCFG_SRC:-<unset>}' is not an ecmccfg checkout"
  why  "Expected to find startup.cmd there."
fi

# ruckig: jerk-limited trajectories, built out-of-tree with cmake
if [[ -d "$mods/ruckig" ]]; then
  if ls "$mods"/ruckig/build/libruckig.* >/dev/null 2>&1; then
    pass "ruckig at $mods/ruckig"
  else
    fail "ruckig present but libruckig not built in $mods/ruckig/build"
    why  "cd $mods/ruckig && cmake -B build && cmake --build build"
  fi
else
  fail "ruckig not found at $mods/ruckig"
  why  "ecmc links it for jerk-limited (S-curve) trajectory generation."
fi

# --- EtherCAT ---------------------------------------------------------------
hdr "EtherCAT (Etherlab master)"
el="${ETHERLAB:-/opt/etherlab}"

if [[ -f "$el/include/ecrt.h" ]]; then
  pass "etherlab headers at $el/include"
else
  fail "no $el/include/ecrt.h"
  why  "ecmc compiles against the Etherlab realtime interface."
  why  "Install it: 00-bootstrap/INSTALL-ethercat-master.md"
fi

if ls "$el"/lib/libethercat.* >/dev/null 2>&1; then
  pass "libethercat at $el/lib"
else
  fail "no libethercat in $el/lib"
  why  "Built by 'configure --enable-userlib' -- INSTALL-ethercat-master.md step 3."
fi

ec_tool="$el/bin/ethercat"
if [[ ! -x "$ec_tool" ]]; then
  ec_tool="$(command -v ethercat 2>/dev/null || true)"
fi
if [[ -n "$ec_tool" && -x "$ec_tool" ]]; then
  pass "ethercat CLI at $ec_tool"
  if "$ec_tool" master >/dev/null 2>&1; then
    pass "EtherCAT master responds"
    nslaves="$("$ec_tool" slaves 2>/dev/null | grep -c . || true)"
    if [[ "${nslaves:-0}" -gt 0 ]]; then
      pass "$nslaves slave(s) on the bus"
    else
      warn "master up but no slaves detected -- check cabling and power"
      why  "Phases 02 and 03 need real slaves; phase 00 does not."
    fi
  else
    warn "EtherCAT master not responding"
    why  "Check: systemctl status ethercat   /   lsmod | grep ec_"
    why  "A kernel update invalidates the module -- INSTALL-ethercat-master.md sec 12."
    why  "You can still run master-less with MASTER_ID=-1."
  fi
else
  warn "ethercat CLI not found"
  why  "Needed for phase 01 (bus discovery)."
  why  "Built by 'configure --enable-tool' -- INSTALL-ethercat-master.md step 3."
fi

# --- realtime ---------------------------------------------------------------
hdr "realtime"
kern="$(uname -r)"
if [[ -f /sys/kernel/realtime ]] || [[ "$kern" == *rt* ]]; then
  pass "realtime kernel ($kern)"
else
  warn "no PREEMPT_RT kernel detected ($kern)"
  why  "ecmc will run, but cycle jitter will be visible at 1 kHz."
  why  "Acceptable for training; not for a production motion system."
fi

# --- python (optional: YAML axis/PLC configuration) -------------------------
# NOTHING HERE IS A BUILD DEPENDENCY.  ecmc, ecmccfg and the training IOC all
# build with no Python at all.
#
# Python is a RUNTIME dependency of one configuration style.  ecmccfg offers two
# ways to configure an axis, and phase 03 teaches both:
#
#   classic .ax  -- pure iocsh epicsEnvSet. No Python, no network. Always works.
#   YAML         -- loadYamlAxis.cmd / loadYamlPlc.cmd shell out during st.cmd to
#                   scripts/jinja2/pythonVenv.sh, which on first run creates a
#                   venv and pip-installs pyyaml, jinja2-cli, yamllint, Cerberus.
#                   That happens at IOC STARTUP and wants the network once.
#
# So everything below is a WARN, never a FAIL: without Python you lose the YAML
# half of phase 03 and nothing else.
hdr "python (optional -- YAML axis config only)"

py_ver="$(python3 -c 'import sys; print(".".join(map(str,sys.version_info[:3])))' 2>/dev/null || true)"
if [[ -n "$py_ver" ]]; then
  pass "python3 $py_ver"

  if python3 -c 'import venv' 2>/dev/null; then
    pass "python3 venv module present"
  else
    warn "python3 has no venv module"
    why  "dnf install python3-devel  (Rocky 9 splits it out)"
  fi

  # If the modules are already importable, no network is needed at IOC start.
  missing_py=""
  for m in yaml jinja2 cerberus; do
    python3 -c "import $m" 2>/dev/null || missing_py="$missing_py $m"
  done
  if [[ -z "$missing_py" ]]; then
    pass "python modules present system-wide: yaml, jinja2, cerberus"
  else
    warn "python modules not installed system-wide:$missing_py"
    why  "ecmccfg will build a venv and pip-install them at IOC startup,"
    why  "which needs NETWORK ACCESS the first time an IOC with YAML config runs."
    why  "On an isolated control network, pre-install instead:"
    why  "  pip3 install --user wheel pyyaml jinja2-cli yamllint Cerberus"
  fi
elif command -v python3 >/dev/null 2>&1; then
  warn "python3 is on PATH but does not run"
  why  "You lose the YAML half of phase 03; the classic .ax half is unaffected."
else
  warn "python3 not found"
  why  "You lose the YAML half of phase 03; the classic .ax half is unaffected."
  why  "Not needed to build anything."
fi

# --- toolchain --------------------------------------------------------------
hdr "toolchain"
if command -v g++ >/dev/null 2>&1; then
  gv="$(g++ -dumpversion)"
  if echo 'int main(){return 0;}' | g++ -std=c++17 -x c++ - -o /dev/null 2>/dev/null; then
    pass "g++ $gv supports -std=c++17"
  else
    fail "g++ $gv cannot compile -std=c++17 (ecmc requires it)"
  fi
  rm -f a.out
else
  fail "g++ not found"
fi

if command -v make >/dev/null 2>&1; then
  pass "make present"
else
  fail "make not found"
fi

if command -v perl >/dev/null 2>&1; then
  pass "perl present (the EPICS build needs it)"
else
  fail "perl not found"
fi

# --- summary ----------------------------------------------------------------
hdr "summary"
if [[ $n_fail -eq 0 && $n_warn -eq 0 ]]; then
  echo "  All checks passed. Continue with 00-bootstrap/bootstrap.sh"
elif [[ $n_fail -eq 0 ]]; then
  echo "  $n_warn warning(s), no blockers. Continue with 00-bootstrap/bootstrap.sh"
  echo "  Re-read the WARN lines: they tell you which exercises will be limited."
else
  echo "  $n_fail blocker(s), $n_warn warning(s). Fix the FAIL lines above first."
fi
echo

if [[ $n_fail -gt 0 ]]; then
  exit 1
fi
exit 0
