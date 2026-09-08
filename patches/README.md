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

### The fix, which ecmc itself documents

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

### What you lose on upstream motor

Small but real, and worth knowing before you debug something that is working as
designed:

- **`syncMotorSoftLimits()`** — the `if (force)` branch still writes the ordinary
  `motorLowLimit_` / `motorHighLimit_`, so the motor record's `DLLM` / `DHLM` are
  still **seeded at startup**. Only the continuous non-forced publication is lost.
- **`readBackSoftLimits()`** — the `if (updateMotor)` block becomes a no-op. The
  ecmc-side parameters above it are set unconditionally, so ecmc's own
  **`-CfgDLLM` / `-CfgDHLM` PVs still track correctly**.

Net: motor-record soft limits are seeded at startup but do not follow ecmc
soft-limit changes made at runtime. **The limits themselves are still enforced
inside ecmc** — this only concerns mirroring them into the motor record.

### Upstream

Worth reporting at <https://github.com/epics-modules/ecmc/issues>: v11.0.8 does
not compile against `epics-modules/motor` at any released version, because these
six uses lack the guard that the same directory's controller file documents.
