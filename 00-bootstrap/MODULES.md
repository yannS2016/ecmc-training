# The module stack — what ecmc is built from, and how it is configured

Companion to [`../ethercatmaster/BUILD.md`](../ethercatmaster/BUILD.md) (kernel/fieldbus side). This file covers the
**EPICS side**: every module the training IOC links, why ecmc needs it, how to build
it, and every configuration decision made in this course with the reason behind it.

Read this before `bootstrap.sh`. If you understand this page you can debug the
build; if you skip it, a link error will be a mystery.

---

## 1. The dependency graph

```
                    ecmcTrainingIoc  (the IOC binary you run)
                            |
        +----------+--------+--------+-----------+
        |          |                 |           |
      ecmc       asyn             motor      exprtkSupport
        |          |                 |           |
        |          +--------+--------+           |
        |                   |                    |
        |              EPICS base <--------------+
        |
        +-- libethercat   (Etherlab, /opt/etherlab -- NOT an EPICS module)
        +-- libruckig     (cmake project        -- NOT an EPICS module)

    ecmccfg   -- never linked. Pure iocsh scripts + db templates, staged at runtime.
```

Two things surprise people:

- **`ecmccfg` is not built into the IOC.** It is ~900 shell/iocsh scripts and ~450
  database templates, consumed at runtime. Only one C++ file from it is compiled
  (`ECATtimestamp.cpp`, §9).
- **Two dependencies are not EPICS modules at all.** `libethercat` and `libruckig`
  are ordinary shared libraries pulled in with `-L`/`-l`/`-rpath` from the
  application Makefile, bypassing the EPICS module mechanism entirely.

---

## 2. A word on what "module" means in EPICS

This trips up people coming from other build systems, and it shapes `site.conf`.

An EPICS support module **is its own source tree**. You do not build it in one
place and install it to a prefix. `make` populates `bin/`, `lib/`, `dbd/`, `db/`
and `include/` *inside the checkout*, because `configure/CONFIG` sets
`INSTALL_LOCATION = $(TOP)`.

So `/epics/modules/7.0.7/ecmc` is not an install target — it is where the ecmc
**source tree lives**, already built.

Consequence for `site.conf`: in a normal layout `ECMC_SRC` and
`$EPICS_MODULES/ecmc` are **the same directory**. They are separate variables only
because you *may* keep sources elsewhere. If you do, `$EPICS_MODULES/ecmc` must
still be the built tree — `preflight.sh` checks the two independently and will
tell you if they disagree.

**Two trees, not one.** Source dependencies that are not EPICS modules live
somewhere else entirely:

| | Variable | Site value | Holds |
|---|---|---|---|
| EPICS modules | `EPICS_MODULES` | `/epics/modules/<base-ver>` | asyn, motor, ecmc, ecmccfg, ecmccomp |
| Source dependencies | `DEPS_DIR` | `/cds/group/pcds/pkg_mgr` | ruckig, as `<package>/R<version>` |

`build-deps.sh` populates the second; `bootstrap.sh` writes the resulting path
into `RELEASE.local` so the IOC build finds it. Keeping them apart matters
because the two trees have different rules: an EPICS module is a built source
tree addressed through `configure/RELEASE`, while a package here is whatever its
own build system produces.

---

## 3. EPICS base

**What it is.** The IOC core: records, database engine, Channel Access / pvAccess,
`iocsh`.

**Version.** ecmc targets EPICS 7. `preflight.sh` warns on 3.14/3.15.

**OS dependencies.** Run `00-bootstrap/install-deps.sh` before building
anything. It installs the compiler, Perl, readline, libtirpc, cmake and python3,
then verifies each by exercising it rather than trusting `dnf`. Two Rocky 9
traps it exists to catch:

- RHEL 8/9 split the Perl core into many small packages, so a minimal install
  has the interpreter but not `FindBin`, which the base build assumes. The
  failure (`Can't locate FindBin.pm in @INC`) appears partway through the build
  and reads like a broken checkout.
- glibc 2.32 removed SunRPC. `asyn`'s VXI-11 driver is `rpcgen`-generated and
  needs `libtirpc`, whose headers live under `/usr/include/tirpc/`, not the old
  `/usr/include/rpc/`. So installing the package is sometimes not enough; the
  build may also need `-I/usr/include/tirpc`.

**Configuration.** None specific to this course. We only read
`configure/CONFIG_BASE_VERSION` to report the version, and
`startup/EpicsHostArch` to determine `EPICS_HOST_ARCH`.

Note base builds shared libraries by default on Linux (`SHARED_LIBRARIES=YES`,
`STATIC_BUILD=NO`). That matters in §12.

---

## 4. asyn

**What it is.** The generic device-support layer: asyn ports, parameter libraries,
`asynPortDriver`.

**Why ecmc needs it.** ecmc *is* an `asynPortDriver`. Every ecmc value visible from
EPICS — axis positions, EtherCAT entries, PLC variables, diagnostics — is an asyn
parameter on a port created by `ecmcAsynPortDriverConfigure()`. Records bind to it
with `INP/OUT` fields like `@asyn(MC_CPU1,0,1)ax1.actpos`.

**Build.**

```bash
cd $EPICS_MODULES/asyn
echo "EPICS_BASE = $EPICS_BASE" > configure/RELEASE.local
make -j$(nproc)
```

asyn can optionally pull in seq, ipac, and hardware buses. None are needed here;
leave them commented in `configure/RELEASE`.

**Provides to the IOC.** `asyn.dbd`, `libasyn`.

---

## 5. motor

**What it is.** EPICS `motorRecord` and the model-3 driver framework.

**Why ecmc needs it.** ecmc ships its own model-3 driver, `ecmcMotorRecord`, which
subclasses motor's `asynMotorController`/`asynMotorAxis`. `initAll.cmd` calls
`ecmcMotorRecordCreateController(...)`, and that gives each axis a standard
`motorRecord` — so `caput TRAIN:Axis1.VAL 10` moves a motor through exactly the
same interface as any other EPICS motor.

This is one of ecmc's genuine strengths and is why phase 03 spends time on it:
ecmc axes are not a bespoke interface, they are motor records.

**Build.**

```bash
cd $EPICS_MODULES/motor
cat > configure/RELEASE.local <<EOF
EPICS_BASE = $EPICS_BASE
ASYN = $EPICS_MODULES/asyn
EOF
make -j$(nproc)
```

In modern `motor` (R7+) the vendor drivers are separate repositories. You need only
the core. If your checkout still bundles `motorXxx` subdirectories and one fails to
build, comment it out of `configure/RELEASE` — ecmc needs none of them.

**Provides to the IOC.** `motorSupport.dbd`, `libmotor`.

> ### ecmc 11.0.x does not compile against upstream motor
>
> ecmc uses `motorLowLimitRO_` and `motorHighLimitRO_`, which exist only in an
> ESS/PSI motor fork — **not in any released `epics-modules/motor`**, including
> `R7-4` and `master`. Unpatched, the build fails with six
> `no member named 'motorLowLimitRO_'` errors.
>
> No motor version fixes this, and no ecmc 11.x version avoids it. The course
> ships a one-hunk patch adding the `#ifdef motorHighLimitROString` guard that
> ecmc's own controller file already documents:
>
> ```bash
> ./00-bootstrap/apply-patches.sh
> ```
>
> `bootstrap.sh` runs it automatically and `preflight.sh` fails loudly if it is
> missing. Full diagnosis, and what behaviour you lose on upstream motor, in
> [`../patches/README.md`](../patches/README.md).

---

## 6. exprtkSupport

**What it is.** A thin EPICS wrapper around
[exprtk](https://www.partow.net/programming/exprtk/), a header-only C++ expression
parser.

**Why ecmc needs it.** This *is* the ecmc PLC language. When you write

```
ec0.s1.binaryOutput01 := ax1.enc.actpos > 10;
```

in a `.plc` file, exprtk compiles and evaluates it every PLC cycle. Understanding
this explains the language's shape — and its limits, which phase 99 discusses: it
is an expression evaluator, not IEC 61131-3.

**Build.** *No separate build.* `exprtkSupport` lives inside the ecmc source tree
and is built by ecmc's own top-level `Makefile`
(`DIRS += $(wildcard *Support)`).

**A subtlety worth knowing.** `configure/RELEASE` sets
`EXPRTK = $(ECMC)/exprtkSupport`, but that directory has **no `lib/`** — it is built
into ecmc's `lib/$(EPICS_HOST_ARCH)/`. The linker finds `libexprtkSupport` through
the `-L` that the `ECMC` entry contributes, not the `EXPRTK` one. So `EXPRTK`
exists mainly to satisfy `CHECK_RELEASE` and header lookups. Upstream's
`ecmcExampleTop` does exactly the same; we mirror it rather than inventing a
cleaner-looking variant that would diverge from every ecmc example you will read.

---

## 7. ruckig

**What it is.** A C++ library for jerk-limited (S-curve) online trajectory
generation. **Not an EPICS module** — a plain CMake project.

**Why ecmc needs it.** `ECMC_TRAJ_TYPE=1` selects ruckig instead of the built-in
trapezoidal generator, giving motion that is continuous in acceleration. Phase 03
compares the two directly.

**Build.** Use the dependency tool rather than doing it by hand, so the version
is pinned and recorded:

```bash
./00-bootstrap/build-deps.sh ruckig
```

It reads `00-bootstrap/deps.conf`, checks out the pinned tag, builds, and writes
the resolved commit to `deps.lock`. The equivalent by hand:

```bash
cd $DEPS_DIR/ruckig/R0.19.4
cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON
cmake --build build -j$(nproc)
```

`BUILD_SHARED_LIBS=ON` is required: the rpath below only helps a shared library.

**Why the build directory matters.** The application Makefile hard-codes it:

```make
USR_LDFLAGS += -L$(RUCKIG)/build -lruckig
USR_LDFLAGS += -Wl,-rpath,'$(RUCKIG)/build'
```

The `-rpath` means the IOC finds `libruckig.so` at runtime **from the build tree**.
Move or delete `$(RUCKIG)/build` and a previously working IOC stops starting. This
is upstream's convention, kept for consistency; if you later package ruckig
properly, update the rpath to match.

`preflight.sh` checks for `$DEPS_DIR/ruckig/<version>/build/libruckig.*` specifically, not just the
directory, because the directory existing proves nothing.

---

## 8. Etherlab EtherCAT master

Covered fully in [`../ethercatmaster/BUILD.md`](../ethercatmaster/BUILD.md) and
[`../ethercatmaster/INSTALL.md`](../ethercatmaster/INSTALL.md). From
the EPICS side, only two things matter:

```make
USR_INCLUDES += -I$(ETHERLAB)/include        # ecrt.h -- the realtime API
USR_LDFLAGS  += -L$(ETHERLAB)/lib -lethercat
USR_LDFLAGS  += -Wl,-rpath=$(ETHERLAB)/lib
```

**The trap** (found while writing the EtherCAT docs): ecmc's own
`configure/RELEASE` sets `ETHERLAB = $(SUPPORT)/etherlab`, which defeats the
`ETHERLAB ?= /opt/etherlab` default in `devEcmcSup/Makefile` — the `?=` never
fires because the variable is already set. So `ETHERLAB` must be stated
explicitly. `bootstrap.sh` writes it into `RELEASE.local` from `site.conf` for
exactly this reason.

Verify the result rather than trusting it:

```bash
ldd .../bin/$EPICS_HOST_ARCH/ecmcTrainingIoc | grep ethercat
# must resolve to /opt/etherlab/lib/libethercat.so*
```

---

## 9. ecmc

**What it is.** The module this course is about: EtherCAT master integration, axis
control, the PLC engine, data storage, plugins, and the `ecmcMotorRecord` driver.

**Build.**

```bash
cd $EPICS_MODULES/ecmc
cat > configure/RELEASE.local <<EOF
EPICS_BASE = $EPICS_BASE
ASYN      = $EPICS_MODULES/asyn
MOTOR     = $EPICS_MODULES/motor
RUCKIG    = $DEPS_DIR/ruckig/<version>
ETHERLAB  = /opt/etherlab
EOF
make -j$(nproc)
```

Requires a C++17 compiler. Submodules must be initialised
(`git submodule update --init`) — exprtk arrives that way.

**Provides to the IOC.** `ecmcController.dbd` (registrar
`ecmcAsynPortDriverRegister` → all the `ecmcXxx` iocsh commands),
`ecmcMotorRecordSupport.dbd` (registrar `ecmcMotorRecordControllerRegister` →
`ecmcMotorRecordCreateController`), `libecmc`, `libexprtkSupport`, and the
`cpp_logic` templates in `devEcmcSup/logic/db/` used in phase 04.

---

## 10. ecmccfg

**What it is.** The configuration framework: hardware descriptions for ~26 vendors,
axis/PLC loaders, database templates, naming conventions.

**It is not built.** Except one file — `src/ECATtimestamp.cpp`, an aSub routine
that converts EtherCAT distributed-clock time (epoch 2000-01-01) into an EPICS
timestamp. The templates that timestamp EtherCAT data need it, so we compile it
into the IOC (§11). A `require`-based site gets it from the loaded ecmccfg library
instead.

**It must be flattened before use.** ecmccfg addresses its own files by bare
filename, so the source tree layout does not work. `stage-ecmccfg.sh` reproduces
the flattening that PSI/ESS module builders do at install time. Full explanation
in `VERIFY.md`; this is the single most common source of confusion in the course.

**Version.** Pinned to tag `11.0.8`, matching `ecmc v11.0.8`. See `../VERSIONS.md`.

---

## 11. The training IOC application

`ecmcTrainingApp/` is a standard EPICS application, deliberately kept close to
upstream's `ecmc/ecmcExampleTop/` so you can diff them.

### `RELEASE` vs `CONFIG_SITE` — and where ecmc gets this wrong

EPICS separates two kinds of path, and the separation is not cosmetic:

| | `configure/RELEASE` | `configure/CONFIG_SITE` |
|---|---|---|
| Holds | EPICS support modules | everything else: external libraries, tools, build options |
| Validated by | `convertRelease.pl`, and `CHECK_RELEASE` | nothing — checked at point of use |
| Exported to | `envPaths`, readable by the IOC | build only |
| Requires | a module tree: `configure/`, `lib/`, `dbd/`, `db/` | nothing in particular |

**ecmc's own `configure/RELEASE` does not respect this.** It declares:

```make
EXPRTK   = $(TOP)/exprtkSupport
RUCKIG   = $(SUPPORT)/ruckig
ETHERLAB = $(SUPPORT)/etherlab
ECMCCFG  = $(SUPPORT)/ecmccfg
ECMCCOMP = $(SUPPORT)/ecmccomp
```

alongside `ASYN` and `MOTOR`. Only the latter two are EPICS modules. `ruckig` is a
CMake project, `etherlab` an autotools install prefix, and `ecmccfg`/`ecmccomp`
are script-and-template trees with no `configure/` directory at all. Putting them
in `RELEASE` asks `CHECK_RELEASE` to validate things that were never modules and
exports them into `envPaths` where nothing reads them.

This course's application splits them properly:

- **`RELEASE`** → `ASYN`, `MOTOR`, `ECMC`, `EPICS_BASE`
- **`CONFIG_SITE`** → `ETHERLAB`, `RUCKIG`, `ECMCCFG`

`bootstrap.sh` generates `RELEASE.local` and `CONFIG_SITE.local` from `site.conf`;
both are gitignored. `CONFIG` includes `RELEASE` first and `CONFIG_SITE` second,
so `CONFIG_SITE` may reference variables set in `RELEASE`.

There is no `EXPRTK` entry at all, because our Makefile never references it. We
link `libexprtkSupport`, which ecmc builds into its own
`lib/$(EPICS_HOST_ARCH)`, so the `-L` arrives via `ECMC`.

**`RELEASE` is still where dependency resolution happens** — at build time, by the
standard EPICS mechanism. A `require`-based site resolves dependencies at
*runtime* from a `.dep` file instead; that difference is the whole of
`../appendix-require.md`.

`CHECK_RELEASE = YES` is deliberate: a typo in a module path fails the build
immediately instead of surfacing as a confusing link error later. It does not
check `CONFIG_SITE` paths — `preflight.sh` covers those before you build.

### `ecmcTrainingIocApp/src/Makefile`

Every line has a reason:

| Entry | Why |
|---|---|
| `USR_CXXFLAGS += -std=c++17` | ecmc requires it |
| `USR_LDFLAGS_Linux += -Wl,--no-as-needed` | the IOC never *calls* into libecmc directly — it is reached only through iocsh-registered commands, so the linker would otherwise drop it |
| `ecmcTrainingIoc_DBD += ecmcController.dbd` | registers `ecmcAsynPortDriverConfigure`, `ecmcConfigOrDie`, `ecmcEpicsEnvSetCalc`, `ecmcFileExist`, … |
| `ecmcTrainingIoc_DBD += ecmcMotorRecordSupport.dbd` | registers `ecmcMotorRecordCreateController` |
| `ecmcTrainingIoc_DBD += asyn.dbd`, `motorSupport.dbd` | device/record support for the above |
| `ecmcTrainingIoc_DBD += ECATtimestamp.dbd` | the aSub routine from ecmccfg |
| `ecmcTrainingIoc_DBD += requireStub.dbd` | our `require` command (§12) |
| `ecmcTrainingIoc_LIBS += asyn ecmc motor exprtkSupport` | link order handled by EPICS |
| `SRC_DIRS += $(ECMCCFG)/src` | lets us compile `ECATtimestamp.cpp` from the ecmccfg checkout without copying it |
| `USR_DBDFLAGS += -I $(ECMCCFG)/dbd` | so `ECATtimestamp.dbd` is found |

Note `$(ECMCCFG)` here points at the **source checkout**, not the staged install.
The staged directory has no `src/`. Getting these two confused is the most likely
build failure.

---

## 12. `requireStub.cpp` — the one piece of novel code

Upstream ecmccfg scripts open with `require ecmccfg <version>`, an iocsh command
from the PSI/ESS `require` module, which we are not using
(`../appendix-require.md` explains why at length).

Exactly **one** `require` call exists in the whole ecmccfg startup path
(`startup.cmd:58`, `require ecmc "${ECMC_VER}"`). Everything else `require` would
provide is plain environment variables.

So we register our own `require` command. It **verifies rather than no-ops**:
`<module>_DIR` must be set and must be a real directory, otherwise the IOC exits
with an explanatory message. A silent no-op would let a mistyped path sail past
and resurface later as a baffling "file not found" from a nested script.

Failure is `exit(EXIT_FAILURE)`, matching ecmc's own convention for unrecoverable
configuration errors (see `ecmcConfigOrDie()` and `ecmcFileExist()`).

The payoff: **ecmccfg is never patched.** It stays byte-for-byte upstream and
therefore upgradable.

---

## 13. The runtime contract — `ecmcPaths.cmd`

Generated by `bootstrap.sh`, sourced as the first line of every `st.cmd`. It
supplies what `require` would have set:

```
epicsEnvSet("ecmccfg_DIR",           "<stage>/")     # trailing slash MANDATORY
epicsEnvSet("ecmccfg_DB",            "<stage>/db")
epicsEnvSet("ecmc_DIR",              "<ecmc module>")
epicsEnvSet("EPICS_DB_INCLUDE_PATH", "<stage>/db:<ecmc>/devEcmcSup/logic/db:<motor>/db:<asyn>/db:<base>/db")
```

- **The trailing slash is not cosmetic.** ecmccfg builds paths by direct
  concatenation: `${ecmccfg_DIR}addSlave.cmd`. Without it you get
  `.../stageaddSlave.cmd`.
- **`EPICS_DB_INCLUDE_PATH` exists because templates are loaded by bare filename**
  — `dbLoadRecords("ecmcEcPrevSlave.db")`. Every directory holding one must be
  listed. The `devEcmcSup/logic/db` entry is what makes phase 04's `cpp_logic`
  templates resolvable.

---

## 14. What `bootstrap.sh` does, in order

1. Reads `site.conf`, resolves `EPICS_HOST_ARCH`.
2. Writes `ecmcTrainingApp/configure/RELEASE.local` — build-time dependencies.
3. Runs `stage-ecmccfg.sh` — runtime scripts and templates.
4. Runs `make` in the application.
5. Writes `iocBoot/ecmcTrainingIoc/ecmcPaths.cmd` — the runtime contract.

Everything it writes is gitignored and regenerable. The repository stays portable;
your host paths stay yours.

---

## 15. Verifying the result

```bash
./00-bootstrap/preflight.sh          # must exit 0
./00-bootstrap/bootstrap.sh
ldd 00-bootstrap/ecmcTrainingApp/bin/$EPICS_HOST_ARCH/ecmcTrainingIoc \
  | grep -E 'ethercat|ruckig'        # both must resolve
cd 00-bootstrap/ecmcTrainingApp/iocBoot/ecmcTrainingIoc && ./st.cmd
```

Expected output and a troubleshooting table are in `VERIFY.md`.

---

## Next

`../01-discovery/` — map the EtherCAT crate, and learn to translate upstream
ecmccfg examples into this setup.
