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
