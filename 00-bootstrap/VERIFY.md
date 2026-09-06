# Phase 0 — Verify the bootstrap

This is the **go/no-go gate** for the whole course. Nothing in phases 01–04 is
meaningful until this passes. It deliberately needs **no EtherCAT hardware**, so
you can clear it before the crate is even cabled.

## Run it

```bash
cd training
cp site.conf.example site.conf     # edit to match this host
./00-bootstrap/preflight.sh        # must exit 0
./00-bootstrap/bootstrap.sh        # generates paths, stages ecmccfg, builds the IOC
cd 00-bootstrap/ecmcTrainingApp/iocBoot/ecmcTrainingIoc
./st.cmd
```

## What success looks like

Four things must appear, in this order.

**1. The `require` stub confirms the module contract.** Twice — once for
`ecmccfg` from `st.cmd`, once for `ecmc` from inside `startup.cmd`:

```
require: ecmccfg staged-local (requested) -> /.../stage/ecmccfg/ [linked at build time]
require: ecmc 11.0.8 (requested) -> /epics/modules/7.0.7/ecmc [linked at build time]
```

If you see these, the env contract that replaces `require` is correct.

**2. ecmc initialises master-less.** `MASTER_ID=-1` means no EtherCAT master is
opened. You should see the asyn port created and no master errors.

**3. `iocInit` completes** with `iocRun: All initialization complete`.

**4. `ecmcReport 1` prints an object tree.** Short — there is no hardware — but
present. That proves ecmc is linked, initialised and introspectable.

Then check from another shell:

```bash
caget TRAIN-BOOTSTRAP:ecmc-Error       # any ecmc PV; should return, not time out
```

## Troubleshooting

Failures here are almost always one of five things.

| Symptom | Cause | Fix |
|---|---|---|
| `require: "ecmccfg_DIR" is not set` | `ecmcPaths.cmd` missing or not sourced | Re-run `bootstrap.sh`; check `< ecmcPaths.cmd` is the first line of `st.cmd` |
| `require: ecmccfg_DIR=... is not a directory` | pointed at the source checkout, not the staged install | Run `stage-ecmccfg.sh`. ecmccfg **cannot** be used from its source tree — see below |
| `File "addSlave.cmd" does not exist` | staging incomplete, or missing trailing slash on `ecmccfg_DIR` | `ecmccfg_DIR` must end in `/` — ecmccfg concatenates directly |
| `Can't find file "ecmcGeneral.db"` | `EPICS_DB_INCLUDE_PATH` wrong | Re-run `bootstrap.sh`; templates are loaded by bare filename |
| Link error on `ECATtimestamp` | `ECMCCFG` in `RELEASE.local` not pointing at the ecmccfg **source** | It is the source checkout, not the stage dir |

### Why ecmccfg cannot run from its source tree

The single most common confusion in this course. ecmccfg addresses its own
files by **bare filename**:

```
${ecmccfg_DIR}addSlave.cmd          # actually at scripts/addSlave.cmd
${ecmccfg_DIR}ecmcEL3202-0010.cmd   # actually at hardware/Beckhoff_3XXX/EL/...
dbLoadRecords("ecmcEcPrevSlave.db") # actually at db/core/...
```

At PSI/ESS the module builder flattens the tree at install time, and
`ecmccfg_DIR` points at the flattened result. `stage-ecmccfg.sh` reproduces
exactly that, following the `SCRIPTS`/`TEMPLATES` lists in `ecmccfg/GNUmakefile`.

This has **nothing to do with skipping `require`** — a require-based site needs
the same flattening, it just gets it for free.

Current ecmccfg stages to roughly **810 scripts and 329 templates** with no
basename collisions. `stage-ecmccfg.sh` asserts that: if a future ecmccfg
introduces two same-named files in different directories, staging fails loudly
rather than letting one silently shadow the other.

## Once this passes

You have a working ecmc IOC with no hardware. Two useful things follow:

- **Phase 01** can start immediately (bus discovery needs the `ethercat` CLI, not the IOC).
- The master-less mode you just used stays useful all course: it is how you test
  PLC logic and `cpp_logic` modules without touching the crate.
