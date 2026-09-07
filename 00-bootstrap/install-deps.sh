#!/usr/bin/env bash
#
# install-deps.sh -- OS packages needed to build EPICS base and the ecmc stack
#                    on Rocky/RHEL 9.
#
# Run before building anything. Complements ethercatmaster/INSTALL.md section 1,
# which installs the kernel-side toolchain for the EtherCAT master; this file
# covers the EPICS side. Running both is fine, they overlap harmlessly.
#
# Every package here is justified in the comments. If you are installing on a
# machine with a strict package policy, that is the list to argue from.
#
# Needs sudo. Idempotent: safe to re-run.

set -uo pipefail

n_fail=0
pass() { printf '  [ PASS ]  %s\n' "$1"; }
fail() { printf '  [ FAIL ]  %s\n' "$1"; n_fail=$((n_fail+1)); }
hdr()  { printf '\n== %s ==\n' "$1"; }

if [[ ! -f /etc/redhat-release ]]; then
  echo "WARNING: this script targets Rocky/RHEL 9. Adapt the package names."
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
hdr "installing packages"

# Compiler and build tools.
#   ecmc requires C++17. Rocky 9 ships gcc 11, which is fine.
PKGS="gcc gcc-c++ make git"

# Perl. THE Rocky 9 TRAP.
#   The EPICS base build is driven by Perl scripts (convertRelease.pl,
#   makeMakefile.pl, dbdToMenuH.pl and others). RHEL 8 and 9 split the Perl
#   core into many small packages, so a minimal install has the interpreter but
#   NOT modules the build assumes are always present. The failure looks like
#
#       Can't locate FindBin.pm in @INC
#
#   partway through the build, which reads like a broken checkout rather than a
#   missing package.
#
#   Installing the "perl" metapackage pulls in the full core and avoids playing
#   whack-a-mole with individual modules. The named ones below are the ones most
#   often still missing afterwards.
PKGS="$PKGS perl perl-devel perl-FindBin perl-lib perl-Data-Dumper perl-Test-Simple"

# readline: iocsh command history and line editing.
#   Base builds without it, but you get an IOC shell with no history and no
#   arrow keys, which is miserable for the whole course.
PKGS="$PKGS readline-devel ncurses-devel"

# libtirpc: provides <rpc/rpc.h>.
#   glibc 2.32 removed its built-in SunRPC implementation, so anything still
#   using ONC RPC now links libtirpc instead. In this stack that is asyn's
#   VXI-11 driver (drvVxi11), which is generated with rpcgen and builds by
#   default. Without this the asyn build fails on a missing rpc/rpc.h, well
#   after EPICS base has built cleanly.
#
#   Nothing in ecmc or ecmccfg uses RPC directly. If you would rather not carry
#   the dependency, asyn can be built with its VXI-11 support disabled instead.
PKGS="$PKGS libtirpc-devel"

# cmake: ruckig is a plain CMake project, not an EPICS module.
PKGS="$PKGS cmake"

# python3 + venv: only needed for the YAML axis configuration path, which shells
# out to Python at IOC startup (see 03-motion-ioc/README.md section 7).
# python3-devel is what provides the venv module on Rocky 9.
PKGS="$PKGS python3 python3-pip python3-devel"

echo "  dnf install: $PKGS"
# shellcheck disable=SC2086
sudo dnf install -y $PKGS

# Some -devel packages live in the CRB repository on Rocky 9. If any of the
# above were "No match", enable it and re-run:
#     sudo dnf config-manager --set-enabled crb
# On RHEL proper the repo is called codeready-builder-for-rhel-9-*-rpms.

# ---------------------------------------------------------------------------
# Verify
#
# dnf reporting success is not proof the build will work. These checks exercise
# the things the EPICS build actually does.
# ---------------------------------------------------------------------------
hdr "verifying toolchain"

if command -v gcc >/dev/null && command -v g++ >/dev/null; then
  pass "gcc/g++ $(gcc -dumpversion)"
else
  fail "gcc or g++ missing"
fi

if echo 'int main(){return 0;}' | g++ -std=c++17 -x c++ - -o /dev/null 2>/dev/null; then
  pass "g++ compiles -std=c++17 (required by ecmc)"
else
  fail "g++ cannot compile -std=c++17"
fi
rm -f a.out

command -v make >/dev/null && pass "make" || fail "make missing"
command -v git  >/dev/null && pass "git"  || fail "git missing"

hdr "verifying perl modules the EPICS build uses"

# Actually load each module rather than trusting the package list. This is what
# catches the RHEL 9 core-split problem.
for m in FindBin lib Getopt::Long File::Basename File::Copy File::Compare \
         File::Path File::Spec Cwd Data::Dumper Sys::Hostname; do
  if perl -M"$m" -e1 2>/dev/null; then
    pass "perl $m"
  else
    fail "perl $m -- try: sudo dnf install perl"
  fi
done

# Only needed for "make runtests" in base. Not fatal.
if perl -MTest::Simple -e1 2>/dev/null; then
  pass "perl Test::Simple (base self-tests)"
else
  echo "  [ note ]  perl Test::Simple missing; 'make runtests' in base will not run"
fi

hdr "verifying libraries"

if [[ -f /usr/include/readline/readline.h ]]; then
  pass "readline headers (iocsh history and line editing)"
else
  fail "readline-devel missing -- iocsh will have no command history"
fi

# libtirpc installs its headers under a subdirectory, not as /usr/include/rpc,
# so builds that expect the old glibc location need -I/usr/include/tirpc.
if [[ -f /usr/include/tirpc/rpc/rpc.h ]]; then
  pass "libtirpc headers (asyn vxi11)"
  if pkg-config --exists libtirpc 2>/dev/null; then
    pass "pkg-config finds libtirpc: $(pkg-config --cflags libtirpc)"
  else
    echo "  [ note ]  pkg-config cannot find libtirpc; if the asyn build fails on"
    echo "            rpc/rpc.h, add -I/usr/include/tirpc to its CFLAGS."
  fi
else
  fail "libtirpc-devel missing -- asyn's vxi11 driver will fail on rpc/rpc.h"
fi

if command -v cmake >/dev/null; then
  pass "cmake $(cmake --version | head -1 | awk '{print $3}')"
else
  fail "cmake missing -- needed to build ruckig"
fi

hdr "verifying python (YAML axis config only)"

if python3 -c 'import sys' 2>/dev/null; then
  pass "python3 $(python3 -c 'import sys; print(".".join(map(str,sys.version_info[:3])))')"
  if python3 -c 'import venv' 2>/dev/null; then
    pass "python3 venv module"
  else
    fail "python3 venv missing -- sudo dnf install python3-devel"
  fi
else
  echo "  [ note ]  python3 not working; you lose YAML axis config, nothing else"
fi

# Pre-installing these means the IOC does not need network access at startup to
# build a venv. See 03-motion-ioc/README.md section 7.
missing_py=""
for m in yaml jinja2 cerberus; do
  python3 -c "import $m" 2>/dev/null || missing_py="$missing_py $m"
done
if [[ -z "$missing_py" ]]; then
  pass "python modules present:  yaml jinja2 cerberus"
else
  echo "  [ note ]  python modules missing:$missing_py"
  echo "            ecmccfg will pip-install them into a venv at IOC startup,"
  echo "            which needs network access the first time. To avoid that:"
  echo "              pip3 install --user wheel pyyaml jinja2-cli yamllint Cerberus"
fi

# ---------------------------------------------------------------------------
hdr "summary"
if [[ $n_fail -eq 0 ]]; then
  echo "  Dependencies OK. Next: build EPICS base, then the modules in the"
  echo "  order given in 00-bootstrap/MODULES.md."
else
  echo "  $n_fail problem(s) above. Fix before building EPICS base."
fi
echo

exit $(( n_fail > 0 ? 1 : 0 ))
