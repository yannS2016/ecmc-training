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
# Touches only the ecmc MODULE (devEcmcSup/, configure/CONFIG_SITE) -- never
# ecmcExampleTop, the example IOC bundled inside this checkout. This course
# builds its own IOC (ecmcTrainingApp) against the module; ecmcExampleTop is
# upstream's demo app and stays untouched.
#
# SITE-SPECIFIC to PCDS: the CONFIG_SITE edit (step 3) hardcodes $PSPKG_ROOT
# module paths. Elsewhere, use it as a template and adjust the paths, or skip
# it and set the same variables in configure/CONFIG_SITE.local instead.
#
# Supersedes the earlier patches/*.patch + apply-patches.sh approach for
# ecmc -- that mechanism kept failing on hunks that assumed an exact prior
# state. This script starts every run from the pristine v11.0.8 tag, so
# there is no prior-state assumption to get out of sync.
#
# Every replacement below has been tested end-to-end against the exact
# pristine v11.0.8 content, run twice in a row to confirm idempotence.
#
# Run ON THE HOST where $ECMC_SRC is checked out:
#
#   export ECMC_SRC=/cds/group/pcds/epics/R7.0.3.1-2.0/modules/ecmc/R11.0.8
#   bash 00-bootstrap/make-demo-branch.sh
#
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  echo "ERROR: do not run this as root -- it creates root-owned files a normal" >&2
  echo "       user then cannot clean up or overwrite. Only install-deps.sh needs sudo." >&2
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
  | grep -v -E '^\?\? configure/RELEASE\.local$' || true)"
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
replace_once devEcmcSup/Makefile 01-old.txt 01-new.txt "1/4 arch filter (devEcmcSup)"

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
replace_once devEcmcSup/motor/ecmcMotorRecordAxis.cpp 02a-old.txt 02a-new.txt "2a/4 motorLimitRO guard, syncMotorSoftLimits"

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
replace_once devEcmcSup/motor/ecmcMotorRecordAxis.cpp 02b-old.txt 02b-new.txt "2b/4 motorLimitRO guard, readBackSoftLimits"

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
replace_once configure/CONFIG_SITE 03-old.txt 03-new.txt "3/4 site module paths (configure/CONFIG_SITE)"

# ---------------------------------------------------------------------------
# 4. RELEASE.local -- belt and suspenders, not committed.
#
# CONFIG_SITE already wins over the `?=` default in devEcmcSup/Makefile, so
# this is not load-bearing today. But configure/RELEASE ships its own
# `ETHERLAB = $(SUPPORT)/etherlab` default, and RELEASE.local overrides
# RELEASE unconditionally -- if inclusion order ever changes (a base
# upgrade, a Makefile refactor), this is what keeps the build pointed at
# the right place. Left untracked, by the .gitignore convention already in
# this checkout for *.local files.
#
# ecmcExampleTop is untouched: this course builds against the ecmc MODULE
# (its RELEASE/CONFIG_SITE, libecmc, its dbd) from ecmcTrainingApp, not the
# example IOC shipped inside ecmc's own source tree.
# ---------------------------------------------------------------------------
f="configure/RELEASE.local"
if [[ ! -f "$f" ]]; then
  cat > "$f" <<'EOF'
ETHERLAB = $(PSPKG_ROOT)/etherlab
RUCKIG = $(PSPKG_ROOT)/ruckig/R0.19.4
EOF
  echo "    [4/4] wrote $f (untracked)"
else
  echo "    [4/4] $f already exists -- left alone. Its content:"
  sed 's/^/         /' "$f"
fi

# ---------------------------------------------------------------------------
# Commit (RELEASE.local is untracked by convention -- not added)
# ---------------------------------------------------------------------------
git add devEcmcSup/Makefile \
        devEcmcSup/motor/ecmcMotorRecordAxis.cpp \
        configure/CONFIG_SITE
git status --short
git commit -q -m 'demo: PCDS build fixes for the ecmc module

- devEcmcSup/Makefile: recognise rhel* as native Linux (T_A here is
  rhel9-x86_64, not linux-x86_64)
- ecmcMotorRecordAxis.cpp: guard motorHighLimitROString -- these members
  do not exist in upstream epics-modules/motor at any release; the
  controller file already carries the same code under this exact guard
- configure/CONFIG_SITE: point ETHERLAB/RUCKIG/ECMCCFG/ECMCCOMP/EXPRTK at
  this sites $PSPKG_ROOT tree

ecmcExampleTop (the example IOC shipped inside this checkout) is left
alone -- this course builds against the ecmc module from ecmcTrainingApp,
not the bundled example.

RELEASE.local (untracked, machine-local) backs up ETHERLAB/RUCKIG for
CONFIG_SITE, in case build inclusion order ever changes.'

echo
echo "== done. On branch: $(git branch --show-current)"
echo "== next:"
echo "     cd $ECMC_SRC && make clean && make"
