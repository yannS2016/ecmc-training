# ecmc Motion Control & DAQ — Training Course

A hands-on course on EtherCAT motion control and data acquisition with
[ecmc](https://github.com/epics-modules/ecmc) and
[ecmccfg](https://github.com/paulscherrerinstitute/ecmccfg), on Rocky 9 with a
real Beckhoff crate.

Two goals:

1. **Operational competence** — stand up a DAQ IOC and a motion IOC from
   scratch, understanding every line you wrote.
2. **Informed judgement** — ecmc is *one* answer to EtherCAT motion control.
   The industry default is Beckhoff TwinCAT. By the end you should be able to
   say where ecmc wins, where it hurts, and why a facility would choose it anyway.

## Prerequisites

- Rocky 9 host, ideally with a PREEMPT_RT kernel
- EPICS base 7.x built, plus `asyn`, `motor`, `ruckig`, `ecmc`
- Etherlab EtherCAT master installed (`/opt/etherlab`) and the `ethercat` CLI
- Source checkouts of `ecmc` and `ecmccfg`
- A Beckhoff EtherCAT crate (phases 02–03; phases 00, 01 and much of 04 do not need one)

Basic EPICS familiarity is assumed: records, PVs, `caget`/`caput`, what an IOC is.
EtherCAT knowledge is **not** assumed.

## Setup

If the EtherCAT master is not installed yet, do that first — `preflight.sh` fails
without it, and it is the one prerequisite that touches the kernel:
[ethercatmaster/BUILD.md](ethercatmaster/BUILD.md)
(compatibility rules and requirements) then
[ethercatmaster/INSTALL.md](ethercatmaster/INSTALL.md)
(the commands).

For motion control specifically, add
[ethercatmaster/REALTIME.md](ethercatmaster/REALTIME.md) — a stock kernel is fine through phase 02, but
coordinated motion needs a bounded worst-case cycle, not just an average one.

```bash
cp site.conf.example site.conf     # edit to match this host — this is the only file you edit
./00-bootstrap/preflight.sh        # must exit 0 before continuing
./00-bootstrap/bootstrap.sh
```

`site.conf` is gitignored. Every script reads it, so it is the single place
where "where things live on this machine" is written down.

## Course structure

| Phase | Topic | Hardware needed |
|---|---|---|
| [00-bootstrap](00-bootstrap/) | Build an ecmc IOC on a bare EPICS tree | none |
| [01-discovery](01-discovery/) | Map the crate; read upstream examples | crate powered |
| [02-daq-ioc](02-daq-ioc/) | Temperature DAQ IOC (PT100 / EL3202) | analog input terminal |
| [03-motion-ioc](03-motion-ioc/) | Motion IOC: encoder, PID, homing, motor record | drive + motor |
| 04-advanced *(planned)* | PLC engine, virtual axes, groups, plugins, `cpp_logic` | partly none |
| 99-assessment *(planned)* | Strengths, limitations, and ecmc vs TwinCAT | none |

Phases are independently useful, but 00 gates everything: it proves the IOC
builds and ecmc starts. Do not skip ahead past a failing
[00-bootstrap/VERIFY.md](00-bootstrap/VERIFY.md).

## Two things that will confuse you early

**1. ecmccfg cannot run from its source tree.** It addresses its own files by
bare filename (`${ecmccfg_DIR}addSlave.cmd`, which actually lives in
`scripts/`), and expects a flattened install. `00-bootstrap/stage-ecmccfg.sh`
builds that. Full explanation in [00-bootstrap/VERIFY.md](00-bootstrap/VERIFY.md).

**2. Upstream examples start with `require ecmccfg` and run via `iocsh.bash`.**
Ours do not — we build IOCs the standard EPICS way. The difference is confined
to the first five lines of any startup script, and translating between them is a
skill taught in phase 01. Rationale in [appendix-require.md](appendix-require.md).

Neither is a defect in this course setup; both are real properties of ecmc that
you should be able to explain by the end.

## Repository layout

```
site.conf.example      copy to site.conf and edit — the only machine-specific file
ethercatmaster/
  BUILD.md             why the EtherCAT master build is kernel-coupled
  INSTALL.md           installing it, command by command
  REALTIME.md          PREEMPT_RT kernel, CPU isolation and latency measurement
00-bootstrap/
  MODULES.md           what each EPICS module is, why ecmc needs it, how it is configured
  preflight.sh         verify the host can build and run ecmc
  bootstrap.sh         generate paths, stage ecmccfg, build the IOC
  stage-ecmccfg.sh     flatten ecmccfg into a usable install
  ecmcTrainingApp/     the IOC application (standard EPICS layout)
    ecmcTrainingIocApp/src/requireStub.cpp    verifying stand-in for `require`
  VERIFY.md            the go/no-go gate
01-discovery/
  README.md            EtherCAT concepts, the ethercat CLI, translating examples
  survey-crate.sh      dump the whole bus to a directory (read-only)
  crate.md             YOUR inventory -- you write this in phase 01
02-daq-ioc/
  README.md            PDO vs SDO, PV naming, record-to-EtherCAT binding
  st.cmd               the temperature IOC
03-motion-ioc/
  README.md            the five parts of an axis, homing, tuning, .ax vs YAML
  st.cmd               the motion IOC (AXIS_CFG selects the stage)
  cfg/01-openloop.ax   stage 1: motion, no protection
  cfg/02-closedloop.ax stage 2: + PID, following error, soft limits
  cfg/03-homing.ax     stage 3: + limit switches, homing
  cfg/axis1.yaml       stage 3 in YAML, for comparison
04-advanced/, 99-assessment/   planned, not yet written
appendix-require.md    what `require` is and why we do not use it
```

The upstream `ecmc` and `ecmccfg` checkouts are **read-only** to this course.
Nothing here patches them, so they stay upgradable.

## Version baseline

Pin both repositories to their **matched `11.0.8` release tags** — not `master`:

| Component | Tag | Commit | Date |
|---|---|---|---|
| `ecmc` | `v11.0.8` | `594ccb5` | 2026-06-16 |
| `ecmccfg` | `11.0.8` | `ca9ea84` | 2026-06-16 |

Released the same day; this is the pair the maintainers assert fits together.
Watch the naming: `ecmc` prefixes `v`, `ecmccfg` dropped the prefix at 10.x.

Older ecmccfg (the v8.0.0 era) lacks YAML axis config, axis groups and
`loadCppLogic.cmd`, which phases 03 and 04 use. `preflight.sh` runs
`git describe` on each checkout and warns when it is not on the expected tag.

How to check the tags out — including for checkouts pointing at personal forks —
is in [VERSIONS.md](VERSIONS.md).
