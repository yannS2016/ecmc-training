# Appendix — `require`, and why this course does not use it

Every ecmc/ecmccfg example you find upstream starts like this:

```bash
iocsh.bash el3202-0010.script
```

```
require ecmccfg master
${SCRIPTEXEC} ${ecmccfg_DIR}startup.cmd, "IOC=$(IOC),ECMC_VER=master"
```

Our IOCs do not. You need to know what that first line is, both to read upstream
material and to make an informed choice at your own facility.

## What `require` is

`require` is an EPICS support module from PSI (`paulscherrerinstitute/require`),
forked by ESS as `e3-require` and used as the foundation of the ESS EPICS
Environment (e3). At runtime it:

1. `dlopen`s a module's shared library,
2. loads its `.dbd`,
3. reads a `.dep` file and recursively loads that module's dependencies,
4. sets `<module>_DIR`, `<module>_DB`, `<module>_VERSION`,
5. optionally runs a module startup snippet.

So `require ecmc 11.0.8` means *"find version 11.0.8 of ecmc in the module pool,
load it, and tell everyone where it lives."* It is a runtime linker with version
pinning — genuinely useful when one host serves many IOCs at different module
versions.

## Why it is not just a packaging step

The tempting assumption is that `require` consumes normal EPICS builds and adds
an install step. It does not. `require`'s build system —
`App/tools/driver.makefile`, or e3's `require.Makefile` — replaces several core
EPICS build conventions:

| | Standard EPICS module | `require` / `driver.makefile` |
|---|---|---|
| Build target | `LIBRARY_IOC` / `PROD_IOC` | `LOADABLE_LIBRARY` (built for `dlopen`) |
| Build count | once, per `configure/RELEASE` | loops over *all* installed EPICS versions × *all* target archs |
| Dependency resolution | `configure/RELEASE`, at build time | `.dep` file, at **runtime** |
| Module version | not a build concept | `LIBVERSION` from git tags via `getVersion.pl`; falls back to `$USER` or `test` |
| Source layout | `App/src/` | flat `$(wildcard *.c *.cc *.cpp ...)` |
| Install paths | `$(INSTALL_LOCATION)/{lib/$(ARCH),dbd,db,include}` | versioned pool, split: `.so` → `${EPICS_MODULES}/${MODULE}/${LIBVERSION}/lib/${T_A}/`, but `dbd`/`db`/`include`/`.dep` → `.../${LIBVERSION}/R${EPICSVERSION}/...` |

Three consequences decided it for us:

1. **`configure/RELEASE` stops being the source of truth.** ecmc's existing
   `configure/RELEASE` — resolving `ASYN`, `MOTOR`, `EXPRTK`, `RUCKIG`,
   `ETHERLAB` — is bypassed. Dependencies move into a runtime `.dep`. This is
   the deepest change and the reason you cannot bolt `require` on with a make target.
2. **Module version becomes a git property.** An untagged checkout installs as
   version `test` or your username.
3. **The version×arch looping exists to serve a shared multi-base pool.** We have
   one EPICS base. We would pay the complexity and get none of the benefit.

This is why e3 is an ecosystem of `e3-<module>` wrapper repositories — one per
module — rather than a flag you pass. Adopting `require` means re-expressing
`asyn`, `motor`, `exprtkSupport`, `ruckig`, `ecmc` and `ecmccfg` in that build
system, and every module you add afterwards, forever.

Two further practical points at the time of writing: e3's installation
documentation targets **CentOS 7** with no Rocky/RHEL 9 guidance, and the ESS
`e3-ecmc` / `e3-ecmccfg` wrappers moved to `gitlab.esss.lu.se/e3/ecat/` in 2020
and lag well behind ecmc 11.0.8.

## What we do instead

| `require` provides | Our equivalent |
|---|---|
| loads module libraries at runtime | linked at build time via `configure/RELEASE.local` |
| sets `<module>_DIR` / `<module>_DB` | `iocBoot/.../ecmcPaths.cmd`, generated from `site.conf` |
| flattened module install for ecmccfg | `00-bootstrap/stage-ecmccfg.sh` |
| the `require` iocsh command itself | `requireStub.cpp` — verifies, does not load |
| runtime version pinning | *(not replaced — this is the real thing we give up)* |

**The flattening is not something we do because we skipped `require`.** ecmccfg
must be flattened either way; a require site just gets it as a side effect of
`driver.makefile`. Read `00-bootstrap/VERIFY.md` for why.

`requireStub.cpp` deliberately **verifies rather than no-ops**: it asserts that
`<module>_DIR` is set and is a real directory, then prints what was requested.
A silent no-op would let a mistyped path surface much later as a baffling "file
not found" from a nested ecmccfg script.

## Translating an upstream example

This is a skill, not a chore — you will do it constantly. Given upstream:

```
require ecmccfg master
$(ECMCCFG_INIT)$(SCRIPTEXEC) ${ecmccfg_DIR}startup.cmd, "IOC=$(IOC),ECMC_VER=master"
```

run as `iocsh.bash foo.script`. To use it here:

1. Add `< ecmcPaths.cmd` as the first line — this supplies `ecmccfg_DIR` etc.
2. Set `epicsEnvSet("SCRIPTEXEC","iocshLoad")` and `epicsEnvSet("ECMCCFG_INIT","")`.
3. Keep the `require ecmccfg ...` line. The stub verifies it. Leaving it in place
   keeps the file diffable against upstream.
4. Replace `ECMC_VER=master` with the version you actually built.
5. Run it as `./st.cmd` (a normal EPICS IOC) instead of `iocsh.bash`.

Everything between those lines — every `addSlave.cmd`, `configureAxis.cmd`,
`Cfg.*` command — is **unchanged**. That is the point: the divergence is
confined to the first five lines of the startup script.

## Honest summary

`require` is good engineering solving a real problem — many IOCs, many module
versions, one host. If your facility already runs e3 or PSI's environment, use
it; ecmc is far smoother there, and this appendix is the workaround you can skip.

If your facility builds EPICS modules the standard way, `require` asks you to
adopt a second, parallel build system to run one framework. That is a legitimate
thing to decline — and the fact that declining it costs a 160-line stub and a
staging script is itself a finding about ecmc, recorded in
[../99-assessment/](../99-assessment/).
