#!/usr/bin/env bash
#
# make-demo-branch.sh -- apply the PCDS build fixes directly to a `demo`
# branch in $ECMC_SRC (the ecmc EPICS module checkout, NOT the EtherCAT
# master -- see ../ethercatmaster/ for that). Self-contained: no patch
# files, no `git apply`, no external files to copy over. Every edit is a
# plain substring replace, verified to occur exactly once before touching
# the file; on a mismatch it stops and tells you what to paste back,
# rather than guessing.
#
# SITE-SPECIFIC to PCDS: the CONFIG_SITE edits (steps 3-4) hardcode
# $PSPKG_ROOT module paths. Elsewhere, use those two steps as a template
# and adjust the paths, or skip them and set the same variables in
# configure/CONFIG_SITE.local instead.
#
# Supersedes the earlier patches/*.patch + apply-patches.sh approach for
# ecmc/ecmcExampleTop -- that mechanism kept failing on hunks that assumed
# an exact prior state. This script starts every run from the pristine
# v11.0.8 tag, so there is no prior-state assumption to get out of sync.
#
# Every replacement below has been tested end-to-end against the exact
# pristine v11.0.8 content, run twice in a row to confirm idempotence.
#
# Run ON THE HOST where $ECMC_SRC is checked out:
#
#   export ECMC_SRC=/cds/group/pcds/epics/R7.0.3.1-2.0/modules/ecmc/R11.0.8
#   bash 00-bootstrap/make-demo-branch.sh [--site=<name>]
#
# --site selects which sites/<name>/{ecmc.local,ecmcexample.local} step 6
# copies in. Defaults to the SITE environment variable, or "pcds" if that is
# also unset -- so a plain run with no argument still does the right thing
# for this course's primary site.
#
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  echo "ERROR: do not run this as root -- it creates root-owned files a normal" >&2
  echo "       user then cannot clean up or overwrite. Only install-deps.sh needs sudo." >&2
  exit 1
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"

SITE="${SITE:-pcds}"
case "${1:-}" in
  --site=*) SITE="${1#--site=}" ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac
if [[ ! -d "$repo/sites/$SITE" ]]; then
  echo "ERROR: no such site: $repo/sites/$SITE" >&2
  echo "       available: $(cd "$repo/sites" && echo */ | tr -d /)" >&2
  exit 1
fi

: "${ECMC_SRC:?export ECMC_SRC first}"
cd "$ECMC_SRC"

echo "== working in: $ECMC_SRC"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# The replace helper: pure substring operations, no regex, no shell-escaping
# hazards for the $ and @ characters that fill every Makefile here.
# ---------------------------------------------------------------------------
cat > "$WORK/replace_once.pl" <<'PERLEOF'
#!/usr/bin/env perl
use strict; use warnings;
my ($file, $oldfile, $newfile, $label) = @ARGV;
local $/;
open(my $F, "<", $file) or die "FATAL [$label]: cannot open $file: $!\n";
my $c = <$F>; close $F;
open(my $O, "<", $oldfile) or die; my $old = <$O>; close $O;
open(my $N, "<", $newfile) or die; my $new = <$N>; close $N;

my $count = 0; my $pos = 0;
while (1) {
  my $i = index($c, $old, $pos);
  last if $i < 0;
  $count++; $pos = $i + 1;
}
if ($count == 0) {
  print STDERR "FATAL [$label]: anchor text not found in $file\n";
  print STDERR "       The file does not match what this script expects.\n";
  exit 1;
}
if ($count > 1) {
  print STDERR "FATAL [$label]: anchor text found $count times in $file (expected 1)\n";
  exit 1;
}
my $i = index($c, $old);
substr($c, $i, length($old), $new);
open(my $W, ">", $file) or die "FATAL [$label]: cannot write $file: $!\n";
print $W $c; close $W;
print "    [$label] ok: $file\n";
PERLEOF

replace_once() {
  perl "$WORK/replace_once.pl" "$1" "$WORK/$2" "$WORK/$3" "$4"
}

# ---------------------------------------------------------------------------
# 0. Start clean, from the known tag, on a fresh 'demo' branch.
# ---------------------------------------------------------------------------
git fetch --tags 2>/dev/null || true
if ! git rev-parse v11.0.8 >/dev/null 2>&1; then
  echo "FATAL: tag v11.0.8 not found locally and could not be fetched." >&2
  echo "       git fetch <remote> --tags, then re-run." >&2
  exit 1
fi
dirty="$(git status --porcelain \
  | grep -v -E '^\?\? (ecmcExampleTop/)?configure/RELEASE\.local$' || true)"
if [[ -n "$dirty" ]]; then
  echo "FATAL: working tree is not clean. Refusing to discard uncommitted work." >&2
  echo "$dirty" >&2
  echo "       git stash -u, or git diff > backup.diff, then re-run." >&2
  exit 1
fi
git checkout -q v11.0.8   # detach first -- can't delete the branch you're standing on
git branch -D demo 2>/dev/null || true
git checkout -b demo v11.0.8
echo "== demo branch created from v11.0.8"

# ---------------------------------------------------------------------------
# 1. devEcmcSup/Makefile -- recognise rhel-* as native Linux
# ---------------------------------------------------------------------------
cat > "$WORK/01-old.txt" <<'EOF'
ifneq ($(filter linux-%,$(T_A)),)
EOF
cat > "$WORK/01-new.txt" <<'EOF'
ifneq ($(filter linux-% rhel%,$(T_A)),)
EOF
replace_once devEcmcSup/Makefile 01-old.txt 01-new.txt "1/6 arch filter (devEcmcSup)"

# ---------------------------------------------------------------------------
# 2a/2b. ecmcMotorRecordAxis.cpp -- guard motorHighLimitROString
#
# These asynMotorController members do not exist in upstream epics-modules/
# motor at any release; they belong to a PSI/ESS fork. Without the guard,
# ecmc 11.0.8 does not compile against upstream motor at all. The controller
# file (ecmcMotorRecordController.cpp) already carries the same code
# commented out with this exact guard -- this brings the axis file in line
# with the pattern the module already uses elsewhere.
# ---------------------------------------------------------------------------
cat > "$WORK/02a-old.txt" <<'EOF'
  if((enabledBwd == 0 && enabledFwd == 0) || (fValueBwd == 0 && fValueFwd == 0)) {
    asynMotorAxis::setDoubleParam(pC_->motorLowLimitRO_,  0);
    asynMotorAxis::setDoubleParam(pC_->motorHighLimitRO_, 0);
    if (force) {
      asynMotorAxis::setDoubleParam(pC_->motorLowLimit_,  0);
      asynMotorAxis::setDoubleParam(pC_->motorHighLimit_, 0);
    }
  } else {
    asynMotorAxis::setDoubleParam(pC_->motorLowLimitRO_,  fValueBwd);
    asynMotorAxis::setDoubleParam(pC_->motorHighLimitRO_, fValueFwd);
    if (force) {
      asynMotorAxis::setDoubleParam(pC_->motorLowLimit_,  fValueBwd);
      asynMotorAxis::setDoubleParam(pC_->motorHighLimit_, fValueFwd);
EOF
cat > "$WORK/02a-new.txt" <<'EOF'
  if((enabledBwd == 0 && enabledFwd == 0) || (fValueBwd == 0 && fValueFwd == 0)) {
#ifdef motorHighLimitROString
    asynMotorAxis::setDoubleParam(pC_->motorLowLimitRO_,  0);
    asynMotorAxis::setDoubleParam(pC_->motorHighLimitRO_, 0);
#endif // ifdef motorHighLimitROString
    if (force) {
      asynMotorAxis::setDoubleParam(pC_->motorLowLimit_,  0);
      asynMotorAxis::setDoubleParam(pC_->motorHighLimit_, 0);
    }
  } else {
#ifdef motorHighLimitROString
    asynMotorAxis::setDoubleParam(pC_->motorLowLimitRO_,  fValueBwd);
    asynMotorAxis::setDoubleParam(pC_->motorHighLimitRO_, fValueFwd);
#endif // ifdef motorHighLimitROString
    if (force) {
      asynMotorAxis::setDoubleParam(pC_->motorLowLimit_,  fValueBwd);
      asynMotorAxis::setDoubleParam(pC_->motorHighLimit_, fValueFwd);
EOF
replace_once devEcmcSup/motor/ecmcMotorRecordAxis.cpp 02a-old.txt 02a-new.txt "2a/6 motorLimitRO guard, syncMotorSoftLimits"

cat > "$WORK/02b-old.txt" <<'EOF'
  if(updateMotor) {
    pC_->setDoubleParam(axisNo_, pC_->motorLowLimitRO_, fValueBwd);
    pC_->setDoubleParam(axisNo_, pC_->motorHighLimitRO_, fValueFwd);
  }
EOF
cat > "$WORK/02b-new.txt" <<'EOF'
#ifdef motorHighLimitROString
  if(updateMotor) {
    pC_->setDoubleParam(axisNo_, pC_->motorLowLimitRO_, fValueBwd);
    pC_->setDoubleParam(axisNo_, pC_->motorHighLimitRO_, fValueFwd);
  }
#else // ifdef motorHighLimitROString
  (void)updateMotor;
#endif // ifdef motorHighLimitROString
EOF
replace_once devEcmcSup/motor/ecmcMotorRecordAxis.cpp 02b-old.txt 02b-new.txt "2b/6 motorLimitRO guard, readBackSoftLimits"

# ---------------------------------------------------------------------------
# 3. configure/CONFIG_SITE -- site module paths (module itself)
# ---------------------------------------------------------------------------
cat > "$WORK/03-old.txt" <<'EOF'
USR_CXXFLAGS += -DUSE_TYPED_RSET
EOF
cat > "$WORK/03-new.txt" <<'EOF'
USR_CXXFLAGS += -DUSE_TYPED_RSET

EXPRTK = $(TOP)/exprtkSupport
RUCKIG = $(PSPKG_ROOT)/ruckig/R0.19.4
ETHERLAB = $(PSPKG_ROOT)/etherlab
ECMCCFG = $(PSPKG_ROOT)/ecmccfg/R11.0.8
ECMCCOMP = $(PSPKG_ROOT)/ecmccomp/R0.2.16
EOF
replace_once configure/CONFIG_SITE 03-old.txt 03-new.txt "3/6 site module paths (configure/CONFIG_SITE)"

# ---------------------------------------------------------------------------
# 4. ecmcExampleTop/configure/CONFIG_SITE -- same paths, example app
# ---------------------------------------------------------------------------
cat > "$WORK/04-old.txt" <<'EOF'
#HOST_OPT = NO
#CROSS_OPT = NO
EOF
cat > "$WORK/04-new.txt" <<'EOF'
#HOST_OPT = NO
#CROSS_OPT = NO

EXPRTK = $(TOP)/exprtkSupport
RUCKIG = $(PSPKG_ROOT)/ruckig/R0.19.4
ETHERLAB = $(PSPKG_ROOT)/etherlab
ECMCCFG = $(PSPKG_ROOT)/ecmccfg/R11.0.8
ECMCCOMP = $(PSPKG_ROOT)/ecmccomp/R0.2.16
EOF
replace_once ecmcExampleTop/configure/CONFIG_SITE 04-old.txt 04-new.txt "4/6 site module paths (ecmcExampleTop/configure/CONFIG_SITE)"

# ---------------------------------------------------------------------------
# 5a. ecmcExampleTop/ecmcIocApp/src/Makefile -- arch filter, drop the
#     static -lethercat/-lruckig flags from USR_LDFLAGS (both branches;
#     the RUCKIG block sits outside the conditional).
# ---------------------------------------------------------------------------
cat > "$WORK/05a-old.txt" <<'EOF'
ifneq ($(filter linux-%,$(T_A)),)
ETHERLAB ?= /opt/etherlab
USR_INCLUDES += -I$(ETHERLAB)/include
USR_CFLAGS += -fPIC
USR_LDFLAGS += -L$(ETHERLAB)/lib
USR_LDFLAGS += -lethercat
USR_LDFLAGS += -Wl,-rpath=$(ETHERLAB)/lib
else
USR_INCLUDES += -I$(SDKTARGETSYSROOT)/usr/include/etherlab
USR_CFLAGS   += -fPIC
USR_LDFLAGS  += -L$(SDKTARGETSYSROOT)/usr/lib/etherlab
USR_LDFLAGS  += -lethercat
USR_LDFLAGS  += -Wl,-rpath=$(SDKTARGETSYSROOT)/usr/lib/etherlab
endif

USR_INCLUDES += -I$(RUCKIG)/include/ruckig
USR_LDFLAGS += -L$(RUCKIG)/build -lruckig
USR_LDFLAGS += -Wl,-rpath,'$(RUCKIG)/build'
EOF
cat > "$WORK/05a-new.txt" <<'EOF'
ifneq ($(filter linux-% rhel%,$(T_A)),)
ETHERLAB ?= /opt/etherlab
USR_INCLUDES += -I$(ETHERLAB)/include
USR_CFLAGS += -fPIC
USR_LDFLAGS += -L$(ETHERLAB)/lib
USR_LDFLAGS += -Wl,-rpath=$(ETHERLAB)/lib
else
USR_INCLUDES += -I$(SDKTARGETSYSROOT)/usr/include/etherlab
USR_CFLAGS   += -fPIC
USR_LDFLAGS  += -L$(SDKTARGETSYSROOT)/usr/lib/etherlab
USR_LDFLAGS  += -Wl,-rpath=$(SDKTARGETSYSROOT)/usr/lib/etherlab
endif

USR_INCLUDES += -I$(RUCKIG)/include/ruckig
USR_LDFLAGS += -L$(RUCKIG)/build
USR_LDFLAGS += -Wl,-rpath,'$(RUCKIG)/build'
EOF
replace_once ecmcExampleTop/ecmcIocApp/src/Makefile 05a-old.txt 05a-new.txt "5a/6 arch filter + drop static -l (ecmcExampleTop)"

# ---------------------------------------------------------------------------
# 5b. Same file -- reorder _LIBS (dependents before dependencies: ecmc and
#     motor both need asyn, so asyn goes last) and move ethercat/ruckig to
#     _SYS_LIBS. Not _LIBS: that tells EPICS to search this application's
#     own lib/<T_A>/ tree for an EPICS-module library, where libecmc.a
#     lives and libethercat.a/libruckig.a never will.
# ---------------------------------------------------------------------------
cat > "$WORK/05b-old.txt" <<'EOF'
ecmcIoc_LIBS += asyn
ecmcIoc_LIBS += ecmc
ecmcIoc_LIBS += motor
ecmcIoc_LIBS += exprtkSupport
EOF
cat > "$WORK/05b-new.txt" <<'EOF'
ecmcIoc_LIBS += ecmc
ecmcIoc_LIBS += motor
ecmcIoc_LIBS += exprtkSupport
ecmcIoc_LIBS += asyn

# ethercat and ruckig are NOT ecmcIoc_LIBS: that tells EPICS to search for an
# EPICS-module library under this application's own lib/<T_A>/ tree, which is
# where libecmc.a lives and libethercat.a/libruckig.a never will (they are
# external archives, found through the -L already set above). SYS_LIBS just
# emits -l<name> with no search, placed after -Wl,-Bdynamic -- still after
# -lecmc, which is what resolves the ecrt_*/ruckig:: symbols it needs.
ecmcIoc_SYS_LIBS += ethercat
ecmcIoc_SYS_LIBS += ruckig
EOF
replace_once ecmcExampleTop/ecmcIocApp/src/Makefile 05b-old.txt 05b-new.txt "5b/6 _LIBS order + _SYS_LIBS (ecmcExampleTop)"

# ---------------------------------------------------------------------------
# 6. RELEASE.local -- one per app (ecmc itself, and ecmcExampleTop), created
#    only if missing. Not committed.
#
# Copied verbatim from ../sites/$SITE/, which carries the REAL RELEASE
# convention for that site (PCDS's confirmed from an actual build log): a
# shared RELEASE_SITE file supplies EPICS_SITE_TOP / BASE_MODULE_VERSION /
# EPICS_MODULES via -include, and ASYN/MOTOR are built from
# $(EPICS_MODULES). This replaces an earlier attempt that generated a raw
# `SUPPORT = ...` override here, based on the upstream epics-modules/ecmc
# git tag content rather than what PCDS actually runs -- that guess does not
# match this site's real convention. A different site with a different
# RELEASE convention gets its own sites/<name>/{ecmc.local,ecmcexample.local}
# and --site=<name> selects it (see the header comment).
#
# The two files differ only in that ecmcexample's carries the extra
# "ECMC = $(TOP)/.." block: ecmcExampleTop is an embedded TOP one level
# under $ECMC_SRC, so it must point ECMC back at its parent explicitly.
# ---------------------------------------------------------------------------
for pair in ".:ecmc.local" "ecmcExampleTop:ecmcexample.local"; do
  d="${pair%%:*}"; src="${pair##*:}"
  f="$d/configure/RELEASE.local"
  if [[ ! -f "$f" ]]; then
    cp "$repo/sites/$SITE/$src" "$f"
    echo "    [6/6] wrote $f from sites/$SITE/$src (untracked)"
  else
    echo "    [6/6] $f already exists -- left alone. Its content:"
    sed 's/^/         /' "$f"
  fi
done

# ---------------------------------------------------------------------------
# Commit (RELEASE.local files are untracked by convention -- not added)
# ---------------------------------------------------------------------------
git add devEcmcSup/Makefile \
        devEcmcSup/motor/ecmcMotorRecordAxis.cpp \
        configure/CONFIG_SITE \
        ecmcExampleTop/configure/CONFIG_SITE \
        ecmcExampleTop/ecmcIocApp/src/Makefile
git status --short
git commit -q -m 'demo: PCDS build fixes for ecmc + ecmcExampleTop

- devEcmcSup/Makefile, ecmcExampleTop Makefile: recognise rhel* as native
  Linux (T_A here is rhel9-x86_64, not linux-x86_64)
- ecmcMotorRecordAxis.cpp: guard motorHighLimitROString -- these members
  do not exist in upstream epics-modules/motor at any release; the
  controller file already carries the same code under this exact guard
- configure/CONFIG_SITE (both apps): point ETHERLAB/RUCKIG/ECMCCFG/
  ECMCCOMP/EXPRTK at this sites $PSPKG_ROOT tree
- ecmcExampleTop Makefile: ethercat/ruckig moved to SYS_LIBS so they link
  after libecmc.a under STATIC_BUILD=YES; _LIBS order corrected so asyn
  (a dependency of ecmc and motor) comes last, not first

RELEASE.local (untracked, machine-local, created if missing) is copied
from ../sites/$SITE/*.local -- the real site RELEASE_SITE convention,
so checkRelease does not conflict with downstream apps built against
this versioned module tree.'

echo
echo "== done. On branch: $(git branch --show-current)"
echo "== next:"
echo "     cd $ECMC_SRC && make clean && make"
echo "     cd $ECMC_SRC/ecmcExampleTop && make clean && make"
