# Patches

The course treats the upstream `ecmc` / `ecmccfg` / `ecmccomp` checkouts as
read-only. These patches are the exception, applied by
`../00-bootstrap/apply-patches.sh`.

Naming: `<NNNN>-<target>-<description>.patch`, where `<target>` selects the
checkout — `ecmc` → `$ECMC_SRC`, `ecmccfg` → `$ECMCCFG_SRC`, and so on.

```bash
./00-bootstrap/apply-patches.sh            # apply what is missing
./00-bootstrap/apply-patches.sh --check    # report status, change nothing
./00-bootstrap/apply-patches.sh --reverse  # restore the pristine checkout
```

Re-running is safe — an already-applied patch is detected and skipped.

**`0003` and `0005` are skipped by the script** (`SKIP_PATCHES` in `apply-patches.sh`) and applied by
hand instead, as one combined edit — see the `0005` section below for why and for the exact steps.
Both touch the same `_LIBS` block in `ecmcExampleTop/ecmcIocApp/src/Makefile`; the manual steps do both
at once, so running `0003` afterward finds its expected "before" text already changed and fails.

---

## 0001-ecmc-guard-motorLimitRO.patch

**Without this, ecmc 11.0.8 does not compile.**

```
ecmcMotorRecordAxis.cpp:720: error: 'class ecmcMotorRecordController' has no
  member named 'motorLowLimitRO_'; did you mean 'motorLowLimit_'?
```

Six errors, all `motorLowLimitRO_` / `motorHighLimitRO_`, in
`devEcmcSup/motor/ecmcMotorRecordAxis.cpp`.

### Why it happens

Those are members of `asynMotorController`, and they **do not exist in upstream
`epics-modules/motor`** — verified absent from `R7-4` (current release) and from
`master`. They belong to an ESS/PSI motor fork that also defines the
`motorHighLimitROString` macro. That fork is not publicly reachable.

Neither upgrading nor downgrading helps:

- Every upstream motor release lacks the symbols, so a newer motor changes nothing.
- Every ecmc tag from `v11.0.0` through `v11.0.8` uses them, and so does
  `v11.0.9_RC1`. Dropping to 10.x would lose `cpp_logic`, which phase 04 needs.

### The fix, confirmed by EthercatMC

`devEcmcSup/motor/ecmcMotorRecordController.cpp` carries the same code commented
out, and the commented block preserves the guard it was written with:

```c
////#ifdef motorHighLimitROString          line 494
//#else  // ifdef motorHighLimitROString   line 534
//#endif // ifdef motorHighLimitROString   line 539
```

So the intended pattern is a compile-time guard on `motorHighLimitROString`. The
six uses in the *axis* file were simply never given it. The most recent commit
touching them is `6400ea57`, *"WIP softlimit sync motor and ecmc"* (2025-07-04),
still carrying its WIP label.

This patch adds that guard. Where the forked motor is present the macro is
defined, the code compiles as before, and behaviour is unchanged.

**EthercatMC confirms this is the intended pattern rather than something we
invented.** It is the TwinCAT-ADS driver from the same lineage, already used at
PCDS, and it does exactly the same thing — `EthercatMCApp/src/EthercatMCAxis.cpp:292`:

```c
#ifdef motorHighLimitROString
  setDoubleParam(pC_->motorHighLimitRO_, fValueHigh / scaleFactor);
  setDoubleParam(pC_->motorLowLimitRO_,  fValueLow  / scaleFactor);
#endif
```

Those three lines are the *only* place in EthercatMC's entire `src/` tree that
touches a motor-record limit field, and EthercatMC ships no motor patch of its
own. It compiles on this site's motor precisely because it is guarded; ecmc
failed only because it is not.

### What you lose on upstream motor

**Nothing that worked before.** The guarded-out code was writing into parameters
that do not exist on this motor, so it was never reaching the motor record
anyway. An earlier version of this file claimed startup seeding still worked;
that was wrong, and the reason is worth stating because it is easy to assume
otherwise:

> Upstream `motor` has **no driver→record path for limit values at all**.
> `devMotorAsyn.c` registers an interrupt only for `motorStatus`, and
> `update_values()` touches only `rmp`, `rep`, `msta`, `rvel`. A driver calling
> `setDoubleParam(motorLowLimit_, …)` updates the driver's own parameter cache
> and stops there.

So what the RO parameters offer is an **optional convenience** — mirroring ecmc's
soft limits into `.DHLM` / `.DLLM` — available only to sites running the forked
motor. It is not expected behaviour, and its absence is not a defect.
`.DLLM`/`.DHLM` are user-settable motor record fields; the user or autosave sets
them and motorRecord enforces them.

Unaffected by this patch, and working normally:

- **Hard limit switches.** `LLS`/`HLS` in `MSTA` come from
  `motorStatusLowLimit_` / `motorStatusHighLimit_`, carried in the `MotorStatus`
  struct that `devMotorAsyn.c` *does* subscribe to. ecmc sets them every poll at
  `ecmcMotorRecordAxis.cpp:1980-1985`.
- **ecmc's own soft limits.** Enforced in the realtime cycle, and visible on the
  `-CfgDLLM` / `-CfgDHLM` PVs in both directions.
- **motorRecord's soft limits.** `.DLLM`/`.DHLM` enforced before a move is
  issued, with `LVIO` on violation.

The one consequence to be aware of is that those last two are **independent** on
this motor — changing one does not change the other. See
[`../03-motion-ioc/README.md`](../03-motion-ioc/README.md) §9.

### Upstream

Worth reporting at <https://github.com/epics-modules/ecmc/issues>: v11.0.8 does
not compile against `epics-modules/motor` at any released version, because these
six uses lack the guard that the same directory's controller file documents.

---

## 0002-ecmc-arch-filter-rhel.patch

**Without this, `-lethercat` cannot be found — and the message is misleading.**

```
/usr/bin/ld: cannot find -lethercat
```

with the flags

```
-L /usr/lib/etherlab -lethercat -Wl,-rpath=/usr/lib/etherlab
```

### Why it happens

`devEcmcSup/Makefile:26` decides where the EtherCAT user library lives:

```make
ifneq ($(filter linux-%,$(T_A)),)
```

That assumes every native Linux build uses the stock EPICS host architecture
name. EPICS has never required that. PCDS builds as `rhel9-x86_64`, the filter
misses, and the build silently takes the `else` branch — the Yocto
cross-compile path — where `$(SDKTARGETSYSROOT)` is unset and
`-L $(SDKTARGETSYSROOT)/usr/lib/etherlab` collapses to `-L /usr/lib/etherlab`.

**The space after `-L` is how you identify it.** The native branch writes
`-L$(ETHERLAB)/lib` with no space, so that literal can only have come from the
cross-compile branch.

Two things this is *not*, both of which look plausible and waste time:

- **Not the `ETHERLAB` value.** The `else` branch never references `ETHERLAB`.
  It can be perfectly correct and you still get `-L /usr/lib/etherlab`.
- **Not a missing library.** `/opt/etherlab/lib/libethercat.so` was present
  and correct throughout.

Nothing warns, because a cross-compile with no sysroot configured is
indistinguishable from a correct one until the linker runs.

### Why `rhel%` and not `rhel-%`

The arch is `rhel9-x86_64`, so `%` must absorb `9-x86_64`. `linux-%` keeps its
dash because that name really does have one; `rhel-%` would match nothing.

Add `rocky%`, `centos%` or whatever your site uses. Testing
`ifeq ($(SDKTARGETSYSROOT),)` instead would be more robust — the `else`
branch's own comment says its premise is a Yocto SDK build, and that is exactly
when the variable is set — but enumerating prefixes is the smaller change and
does not alter behaviour for existing Yocto users.

### Both copies

`ecmcExampleTop/ecmcIocApp/src/Makefile` carries the same block verbatim. Patch
one and the module builds, then the example IOC fails identically. This patch
does both.

---

## 0003-ecmc-libs-link-order.patch

**Only bites when `STATIC_BUILD=YES`, but the ordering is wrong either way.**

```
libecmc.a(ecmcAsynPortDriver.o): undefined reference to
  `asynPortDriver::asynPortDriver(char const*, int, int, int, int, int, int, int)'
... and `typeinfo for asynPortDriver'
```

### Why it happens

`ecmcExampleTop/ecmcIocApp/src/Makefile` lists `asyn` before `ecmc`, and EPICS
emits `_LIBS` in the order given:

```
-lasyn -lecmc -lmotor -lexprtkSupport
```

A static archive contributes only the symbols already demanded by something to
its left. `libecmc.a` needs `asynPortDriver`, but `libasyn.a` was scanned
before anything wanted it, contributed nothing, and was discarded.

Note the error is *undefined references*, not `cannot find -lasyn`. The linker
found the library and looked at it too early. Those two failures need opposite
fixes, so the distinction is worth reading carefully.

### Why nobody has hit it before

Shared libraries record their dependencies in `DT_NEEDED`, so the runtime
loader repairs bad ordering and it never surfaces. Only a site linking IOC
executables statically sees it. PCDS does:

```
$EPICS_BASE/configure/CONFIG_SITE:173  SHARED_LIBRARIES=YES
$EPICS_BASE/configure/CONFIG_SITE:177  STATIC_BUILD=YES
```

`SHARED_LIBRARIES=YES` is why `libecmc.so` builds fine — only the executable
link is static.

Worth reporting upstream. Dependents belong before dependencies regardless of
how any particular site links.

### If you are linking statically, this patch is not sufficient

The full link line also carries `-lethercat` and `-lruckig` **ahead of**
`-lecmc`, because they come from `USR_LDFLAGS` in `devEcmcSup/Makefile`, which
EPICS emits before the `_LIBS`-generated flags. Fixing `_LIBS` gets you past
asyn and straight into undefined `ecrt_*` and ruckig symbols.

Properly fixing that means moving them to `ecmcIoc_SYS_LIBS`, which EPICS emits
last — an upstream change to how ecmc attaches its libraries, correct for both
the shared library and the static executable. That is not carried here.

**On a training or lab host, link dynamically instead:**

```make
# ecmcExampleTop/configure/CONFIG_SITE.local
STATIC_BUILD = NO
```

The application's `CONFIG_SITE` is read after base's, so this overrides
site-wide config without touching it. And ecmc emits
`-Wl,-rpath=$(ETHERLAB)/lib` — an rpath is a dynamic-loader construct that does
nothing in a static link, so the module is written expecting dynamic linking.
Three separate build failures came from fighting that. Porting ecmc to static
linking is real work and a separate project from getting an axis moving.

---

## 0004-ecmc-site-module-paths.patch

**Site-specific. Skip it unless your site lays modules out the way PCDS does.**

Points `ETHERLAB`, `RUCKIG`, `ECMCCFG`, `ECMCCOMP` and `EXPRTK` at
`$PSPKG_ROOT` instead of ecmc's `$(SUPPORT)/...` defaults.

The trap worth knowing even if you skip the patch: `devEcmcSup/Makefile` has
`ETHERLAB ?= /opt/etherlab`, which looks like a safety net and is not. `?=`
assigns only when a variable is unset, and `configure/RELEASE` sets `ETHERLAB`
before that line is read, so the fallback never fires. The build searches
`<ecmc>/../etherlab/lib` — the source checkout, where the built library is in
`lib/.libs/` — and fails as though the library were missing.

The example IOC is a separate EPICS application with its own `configure/` and
inherits none of this, which is how the omission was found.

`$(PSPKG_ROOT)` is an environment variable so the paths are parameterised, but
the version directories are not, and must be updated on a version bump. They
also appear in [`../sites/pcds.conf`](../sites/pcds.conf) — keep the two in
step.

The patch header records the alternative: both files `-include
$(TOP)/configure/CONFIG_SITE.local`, so the same five lines in an untracked
file work without modifying anything tracked. Pick one. Doing both means two
places to forget.

---

## Checking the patches themselves

```bash
./patches/validate.sh                    # is each patch a well-formed diff?
./00-bootstrap/apply-patches.sh --check  # does each one apply to this checkout?
```

Two different questions. The first is about the patch files; the second about
the checkout they target.

`validate.sh` exists because two invisible defects both surface as the same
unhelpful `does not apply`, and both cost real time to chase:

- **A blank context line written as a genuinely empty line.** Unified diff
  requires a leading space on *every* line of a hunk body — blank ones
  included. `diff -u` emits `" \n"`; a hand-written hunk naturally gets `"\n"`.
  Nothing renders the difference.
- **Hunk header counts that disagree with the body.** `@@ -44,7 +44,11 @@` when
  the body actually has 9 and 13 lines.

`git apply` reports both as a context mismatch, which reads like a version
problem. It is not — `git apply` matches file content and never looks at a tag.

**Generate hunks with `diff -u`, not by hand.** Reconstruct the file region
before and after, diff the two, and splice the result in. Every defect above
came from typing a hunk out and counting its lines by eye.

---

## 0005-ecmc-thirdparty-link-order.patch

**Skipped by `apply-patches.sh` — apply by hand.** It kept failing `--check` against
intermediate states of this checkout as it was being developed against a real
build, so for now it is documented here and applied manually rather than
automated. The diagnosis below is accurate; only the delivery mechanism isn't
automated yet.

```bash
sed -i 's/filter linux-%,/filter linux-% rhel%,/' \
  "$ECMC_SRC"/devEcmcSup/Makefile \
  "$ECMC_SRC"/ecmcExampleTop/ecmcIocApp/src/Makefile

sed -i '/^USR_LDFLAGS.*+= -lethercat$/d' \
  "$ECMC_SRC"/ecmcExampleTop/ecmcIocApp/src/Makefile
sed -i 's/^USR_LDFLAGS += -L\$(RUCKIG)\/build -lruckig$/USR_LDFLAGS += -L$(RUCKIG)\/build/' \
  "$ECMC_SRC"/ecmcExampleTop/ecmcIocApp/src/Makefile
```

Then edit `ecmcIoc_LIBS` in `ecmcExampleTop/ecmcIocApp/src/Makefile` by hand — change

```make
ecmcIoc_LIBS += asyn
ecmcIoc_LIBS += ecmc
ecmcIoc_LIBS += motor
ecmcIoc_LIBS += exprtkSupport
```

to

```make
ecmcIoc_LIBS += ecmc
ecmcIoc_LIBS += motor
ecmcIoc_LIBS += exprtkSupport
ecmcIoc_LIBS += asyn

ecmcIoc_SYS_LIBS += ethercat
ecmcIoc_SYS_LIBS += ruckig
```

Verify before building:

```bash
sed -n '10,60p' "$ECMC_SRC"/ecmcExampleTop/ecmcIocApp/src/Makefile
```

Check for: `rhel%` in the filter, no `-lethercat`/`-lruckig` left in `USR_LDFLAGS`,
`_LIBS` ending in `asyn`, then the two `_SYS_LIBS` lines.

**The other half of `0003`. Same defect, different mechanism.**

```
libecmc.a(ecmcEc.o): undefined reference to `ecrt_release_master'
libecmc.a(ecmcTrajectoryS.o): undefined reference to
  `ruckig::PositionSecondOrderStep1::get_profile(...)'
```

117 undefined references on this host, in exactly two families — `ecrt_*` and
`ruckig::`.

### Why `0003` could not fix it

`0003` reordered `ecmcIoc_LIBS`. These two libraries never go through `_LIBS`:
they are added by `USR_LDFLAGS` in `ecmcExampleTop/ecmcIocApp/src/Makefile`,
which EPICS emits *before* the object files:

```
g++ -o ecmcIoc -Wl,-Bstatic ... -lethercat ... -lruckig ...
    ecmcIoc*.o -lecmc -lmotor -lexprtkSupport -lasyn ... -Wl,-Bdynamic ...
```

### Why `ecmcIoc_LIBS` is the wrong destination too

The first attempt at this patch moved the two `-l` flags into `ecmcIoc_LIBS`,
next to `asyn`/`motor`/`exprtkSupport`. That fails differently:

```
make: *** No rule to make target '../../../lib/rhel9-x86_64/libethercat.a', needed by 'ecmcIoc'.
```

`ecmcIoc_LIBS` tells EPICS "this is an EPICS-module library," and it searches
for it under *this application's own* `lib/<T_A>/` tree — where `libecmc.a`
lives and `libethercat.a`/`libruckig.a` never will, because they are external
archives found through `-L`, not modules this application builds.

`ecmcIoc_SYS_LIBS` is the correct list for exactly that case: a library that
already supplies its own `-L`. EPICS simply emits `-l<name>` with no search,
placed after `-Wl,-Bdynamic` — still after `-lecmc`, which is what resolves the
undefined references. The `-L` and `-Wl,-rpath` flags stay in `USR_LDFLAGS`,
untouched: only `-l` position matters to archive resolution.

### Two details the file dictates

- **The RUCKIG block sits outside the arch conditional.** That is why
  `-lruckig` reached the link line even before `0002` fixed the filter, when the
  entire ETHERLAB block was being skipped. It needs its own hunk.
- **Both branches of the conditional add `-lethercat`.** Patching only the
  native branch leaves a Yocto cross-build broken in a different way.

### Ordering

`apply-patches.sh` applies patches in numeric order to one working tree, so this
patch's context is the file with `0002` and `0003` already applied. That is not
incidental — `0003` rewrote the `_LIBS` block this one appends after.

### Verify

```bash
ldd bin/rhel9-x86_64/ecmcIoc | grep -E 'ethercat|ruckig'
```

Two lines, each resolving to the real `.so` through the rpath already on the
link line. `libethercat.a`/`libruckig.a` are never involved for these two —
only `-lecmc`, `-lmotor` etc. are static.
