# Phase 03 — Motion IOC

**Needs:** phase 00 complete, `crate.md` from phase 01, and the training crate:

| Pos | Terminal | Role |
|---|---|---|
| 0 | EK1101 | coupler |
| 1 | EL5042 | BiSS-C absolute encoder interface |
| 2 | EL7062-0000 | 2ch stepper output stage, 48 V 3 A (ch1 used) |

Plus a **fourth repository**: `ecmccomp` (§2). Phase 03 cannot be configured
without it.

**Produces:** an axis you can jog, position and drive through a standard EPICS
`motorRecord`, closed on an absolute linear scale.

> ### Before you power anything
>
> - `I_MAX_MA` / `I_STDBY_MA` come from **your motor's datasheet**. The defaults
>   are the PSI lab motor's and will overheat a smaller one.
> - **This crate has no digital input terminal.** Unless you wire limit switches
>   to the EL7062's own inputs *and* enable them in the config, nothing stops the
>   axis at end of travel but you. Know where the power cut is.
> - Run stage 1 decoupled if you can.
> - All scalings below assume a **1 mm/rev** stage. Yours is probably different;
>   exercise 1 fixes that before you trust any number.

---

## 1. The stages

```bash
cd 03-motion-ioc
./st.cmd                       # stage 1: open loop, drive's own step counter
./st.cmd -m STAGE=2            # stage 2: closed loop on the BiSS-C scale
./st.cmd -m DRV_POS=2,ENC_POS=1        # if your positions differ
```

| | Config | Feedback | Protection |
|---|---|---|---|
| 1 | `cfg/01-openloop.yaml` | EL7062 microstep counter | none — counts commands, not reality |
| 2 | `cfg/02-closedloop.yaml` + `cfg/enc-openloop.yaml` | BiSS-C absolute scale | following error, soft limits |

---

## 2. `ecmccomp` — the fourth repository

ecmccfg ships 302 motor configuration files. **None of them is for the EL7062.**
That hardware's configuration lives in a separate module, `ecmccomp`, reached
through a wrapper:

```
ecmccfg/scripts/applyComponent.cmd
  -> require ecmccomp
  -> ${ecmccomp_DIR}applyComponent.cmd
  -> the file for COMP=<name>
```

The wrapper's own docstring says *"Only for use if the ecmccomp module is
accessible (at PSI)"*, which reads as though it were internal. It is not — the
repository is public:

```bash
git clone https://github.com/paulscherrerinstitute/ecmccomp
# then set ECMCCOMP_SRC in site.conf and re-run bootstrap.sh
```

Like ecmccfg, it is addressed by bare filename and must be flattened;
`00-bootstrap/stage-ecmccomp.sh` does that, and `preflight.sh` warns when it is
missing.

**Worth noticing as a pattern.** Configuring one stepper terminal requires four
coordinated repositories — ecmc, ecmccfg, ecmccomp, and the EtherCAT master —
with version compatibility that no tool checks for you. That is a real property
of this ecosystem and belongs in the phase 99 assessment.

The three components this phase applies:

| `COMP=` | Sets |
|---|---|
| `Motor-Generic-2Phase-Stepper` | coil current, nominal voltage, coil L and R |
| `Drive-Generic-Ctrl-Params` | current and velocity loop gains inside the drive |
| `Generic-Ch-Not-Used` | declares channel 2 unused |

That last one is not optional. ecmc verifies that every drive channel linked to
motion received SDO settings and **refuses to start** otherwise, so an unused
channel must be declared explicitly.

---

## 3. CSP, not CSV — and why you have no choice

A stepper terminal can normally be driven two ways:

- **CSV** (cyclic synchronous velocity) — ecmc sends a velocity each cycle and
  closes the position loop itself.
- **CSP** (cyclic synchronous position) — ecmc sends a position each cycle and
  the drive closes its own loop.

For the EL7062 this is decided for you. From the upstream best-practice README:

> The EL7062 has a firmware bug when running in CSV mode: at each disable the
> open-loop counter jumps to closest full turn. Therefore, EL7062 must run in
> **CSP** mode. Beckhoff has confirmed the bug and it will be fixed, but earliest
> sometime in 2026.

Hence `HW_DESC=EL7062_CSP` and, in the axis config:

```yaml
axis:
  mode: CSP
drive:
  type: 1                                    # DS402, not stepper type 0
  setpoint: ec0.s$(DRV_SID).positionSetpoint01   # position, not velocity
```

**The lesson beyond this terminal:** the `HW_DESC` you need is not always the
part number on the label. Firmware quirks, revisions and operating modes all
change which ecmccfg description applies. Phase 01's identity check tells you the
terminal is what you declared — it cannot tell you the declaration is *right*.

---

## 4. Two encoders, and why

Stage 2 configures two, and this is the part most worth understanding.

| | Measures | Frame | Role |
|---|---|---|---|
| Encoder 1 — BiSS-C | the **load** | absolute, from the scale | primary: what ecmc controls to and the motor record reads |
| Encoder 2 — step counter | the **motor** | incremental, from power-on | `useAsCSPDrvEnc`: the frame the drive's own loop closes in |

In CSP the drive runs a position loop against its internal counter, while ecmc
issues setpoints in the scale's coordinates. Those are different coordinate
systems. Unless ecmc knows about both, the two disagree and the axis will not
settle.

Two settings tie them together, both in `cfg/enc-openloop.yaml`:

```yaml
useAsCSPDrvEnc: 1              # this is the encoder the drive closes on
homing:
  refToEncIDAtStartup: 1       # seed it from encoder 1 at startup, no motion
```

Load order matters: `loadYamlAxis.cmd` first (creating the axis and encoder 1),
then `loadYamlEnc.cmd` to attach encoder 2.

---

## 5. Absolute encoders make homing almost disappear

Phase 03 originally spent a section on homing sequences. With a BiSS-C **absolute**
scale, most of that evaporates: position is known at power-on, with no reference
move ever.

What replaces homing is one number:

```yaml
absOffset: -15626.058          # maps raw scale reading -> your machine coordinates
```

You measure it once — move to a known physical position, read the raw value,
compute the difference — and the axis knows where it is at every power-on
forever after. Exercise 3 derives yours.

The homing sequence table still matters for incremental systems, and phase 04
returns to it. The full list is the `ECMC_SEQ_HOME_*` enum in
`ecmc/devEcmcSup/main/ecmcDefinitions.h`; the useful ones are 1/2 (limit),
3/4 (limit → home switch), 11/12 (limit → encoder index, the most repeatable),
15 (set position, no motion) and 21/22 (single-turn absolute).

Stage 1 uses type 15 — "you are here" — because an open-loop counter has no
reference to find.

---

## 6. The five things every axis needs

**1. An encoder** — where am I? Stage 1 uses the drive's microstep counter, which
counts *commanded* steps. **It will report a perfect position straight through a
stall.** That is exactly why stage 2 exists.

Scaling is a ratio, deliberately not a float:

```yaml
numerator: 1          # 1 mm ...
denominator: 4096     # ... per 4096 BiSS-C counts
```

The step counter and the drive use `1 / 1048576` (microsteps per mm). **All three
must describe the same physical unit** or the loop fights itself.

**2. A drive** — how do I move? In CSP, a position setpoint plus a control word.

**3. A trajectory generator** — where should I be *now*? `type: 1` is ruckig
jerk-limited; `0` is trapezoidal.

**4. A controller** — closes ecmc's loop on following error. In stage 1 the gains
are zero on purpose: feedback *is* the setpoint, so there is nothing to correct.
Stage 2 makes it real.

**5. Monitoring** — following error, at-target, velocity, limits, soft limits.

---

## 7. Why both configs are YAML

Phase 03 was originally going to teach `.ax` and YAML side by side. This hardware
settled the question:

**`useAsCSPDrvEnc` and `refToEncIDAtStartup` have no `.ax` equivalent.** They are
not among the ~89 `ECMC_*` variables that `addAxis.cmd` consumes. The classic
dialect *cannot express this configuration at all* — and it is not exotic, it is
what a mainstream Beckhoff stepper terminal requires.

So:

- **`.ax`** — pure iocsh `epicsEnvSet`, no dependencies. What most deployed
  systems still run, and what you will meet in most upstream examples. Learn to
  read it. Its flaw: no schema, so a **misspelled variable is silently ignored**
  and the parameter takes its default, producing an axis that behaves oddly for
  reasons nothing reports.
- **YAML** — structured, schema-validated (unknown keys are rejected), templated
  with jinja2, and the only dialect that reaches newer features. Its cost:
  `loadYamlAxis.cmd` shells out to Python during `st.cmd` via `pythonVenv.sh`,
  which on first run creates a venv and `pip install`s four packages — **your IOC
  wants network access to start**. Pre-install them on an isolated network;
  `preflight.sh` checks.

There are also **two YAML schemas that disagree**: the runtime authority is
`ecmccfg/scripts/jinja2/ecmcYamlSchema.py`; the VS Code ecmcPLC extension ships
its own, which rejects a top-level `homing:` that the runtime accepts. Nest
`homing:` under `encoder:` and both are happy — which is the more correct form
anyway now that an axis can have several encoders.

---

## 8. Driving it

```bash
caput  TRAIN-MOTION:M1.CNEN 1        # enable
caput  TRAIN-MOTION:M1.JOGF 1        # jog forward; JOGR reverse; 0 stops
caput  TRAIN-MOTION:M1.VAL  10       # move to 10 mm
caget  TRAIN-MOTION:M1.RBV           # readback
caput  TRAIN-MOTION:M1.STOP 1
```

Standard **motor record** fields — nothing ecmc-specific. Any EPICS motion
client, OPI or scan tool drives an ecmc axis unchanged. Worth weighing in phase
99: a TwinCAT axis needs a gateway layer to reach EPICS at all.

ecmc-side detail sits on its own PVs:

```bash
caget TRAIN-MOTION:M1-ErrId          # ecmc error code, 0 = OK
caget TRAIN-MOTION:M1-PosAct
caget TRAIN-MOTION:M1-CntrlErr       # following error
```

With `ENG_MODE=1` you also get the commissioning panels, including the EL7062
**auto-tune** — run it, and it hands you the `MACROS` string to paste into the
`Drive-Generic-Ctrl-Params` line in `st.cmd`.

### Wiring limit switches

This crate has no digital input terminal, but the EL7062 has two inputs per
channel. To use them, change the `input:` block from `ONE.0` to:

```yaml
input:
  limit:
    forward: ec0.s$(DRV_SID).binaryInputs01.0
    backward: ec0.s$(DRV_SID).binaryInputs01.1
```

**Verify polarity by hand before moving.** ecmc reads these as "1 = OK, not at
limit", and switches are normally wired closed so a broken wire reads as "at
limit". If the axis refuses to move in both directions, that is what happened.

---

## 9. Limits: three things with similar names

Easy to conflate, and they behave differently.

| | What it is | Who sets it | Who enforces it |
|---|---|---|---|
| `LLS` / `HLS` in `MSTA` | hard limit **switch state** | the drive, from the wired input | reported to the record; motorRecord refuses to keep driving into an active switch |
| `.DLLM` / `.DHLM` (dial), `.LLM` / `.HLM` (user) | soft limit **values** | **you**, or autosave | motorRecord, before it issues a move (sets `LVIO`) |
| ecmc `softlimits:` | soft limit **values** | axis YAML, or `-CfgDLLM` / `-CfgDHLM` | ecmc, inside the realtime cycle |

`LLS`/`HLS` are driver-driven and work normally — ecmc sets
`motorStatusLowLimit_` / `motorStatusHighLimit_` from the drive's status word
every poll, exactly as the TwinCAT-ADS driver EthercatMC does.

The two **soft** limit layers are the ones to be careful about.

### They are independent on this motor

`.DLLM`/`.DHLM` are ordinary user-settable motor record fields. ecmc *can*
mirror its own soft limits into them, but only when built against a motor that
provides `motorLowLimitRO_` / `motorHighLimitRO_` and `motorFlagsRwSoftLimits`.
Those exist in an ESS/PSI motor fork, not in any released
`epics-modules/motor`, so on this site the two layers **do not talk to each
other in either direction**.

That is not a fault. It is defence in depth:

- **motorRecord limits what can be *requested*.** Set `.DLLM`/`.DHLM`, let
  autosave restore them, archive them. This is the operator-facing limit and the
  interface UIs and scripts should use.
- **ecmc limits what can be *executed*.** The YAML `softlimits:` block is
  enforced in the realtime cycle, including for motion commanded from a PLC
  expression that never touches the motor record.

**The trap:** changing one does not change the other. Set both, keep them
consistent, and when someone reports "I raised the limit and it still stops",
check which layer stopped it. `-CfgDHLM-RB` shows ecmc's current value;
`.DHLM` shows the record's.

A reasonable convention is to make ecmc's limits equal to, or slightly wider
than, the record's — so the record is what an operator normally meets, and ecmc
is the backstop for anything that bypasses it.

The full diagnosis of why the mirroring is unavailable, and the compile fix it
made necessary, is in the header comment of
[`../00-bootstrap/make-demo-branch.sh`](../00-bootstrap/make-demo-branch.sh).

---

## 10. When it will not move

| Symptom | Cause |
|---|---|
| IOC won't start, SDO complaint about ch2 | missing `Generic-Ch-Not-Used` for channel 2 |
| IOC won't start, `ecmccomp_DIR` not set | `ECMCCOMP_SRC` missing from `site.conf` (§2) |
| Won't move either direction, no error | limits read "at limit" — polarity, or `ONE.0` not set |
| `CNEN` goes 1 then 0 | drive not ready — check status word bits |
| Position jumps on disable | you are in CSV mode — must be CSP (§3) |
| Axis never settles, hunts | the two encoder frames disagree — check `useAsCSPDrvEnc` and `refToEncIDAtStartup` |
| Moves 256× too far | scaling: microsteps per rev is not what you assumed |
| Position right at power-on but wrong absolute | `absOffset` not derived for your stage (§5) |
| Raised `.DHLM` but the axis still stops short | ecmc's own soft limit stopped it; the two layers are independent (§9). Check `M1-CfgDHLM-RB` |
| Raised `-CfgDHLM` but the move is refused before it starts | motorRecord's `.DHLM` stopped it; `.LVIO` will be 1 (§9) |

Start at `M1-ErrId`; `ecmcReport 3` dumps the object tree.

---

## Exercises

1. **Scale it properly.** Find your stage's mm/rev, the drive's microsteps/rev
   and the scale's counts/mm. Set all three scalings consistently. Command 10 mm,
   measure it. Nothing downstream is trustworthy until this is right.
2. **Auto-tune the drive.** With `ENG_MODE=1`, run the EL7062 auto-tune from the
   expert panel. Paste the result into `DRV_CTRL_MACROS`. What changed?
3. **Derive `absOffset`.** Move to a known physical position, read the raw BiSS-C
   value, compute the offset that maps it to your machine coordinate. Restart and
   confirm the position is correct with no homing move.
4. **Tune the ecmc loop.** Stage 2, from `Kp: 0`. Raise until tracking is crisp,
   then until it buzzes; back off. Add `Ki` until steady-state error disappears.
5. **Provoke a stall.** Stage 1, gently stop the shaft: `RBV` keeps counting.
   Stage 2 with lag monitoring on: it trips. One sentence on what changed.
6. **Trip each limit layer separately.** Set `.DHLM` to 20 and request 25 — the
   move is rejected before it starts and `.LVIO` goes to 1; that is motorRecord.
   Now set `.DHLM` wide open, set ecmc's limit to 20 instead
   (`caput $(M)-CfgDHLM 20`), and command 25 again — this time the move starts
   and ecmc interlocks it. Same apparent symptom, two different mechanisms.
   Which PV told you which one fired?
7. **Break the frames.** In `enc-openloop.yaml`, remove `refToEncIDAtStartup`.
   Predict what happens, then try it. Why does §4 matter?
8. **Read the other dialect.** Open any `.ax` in `ecmccfg/examples/ESS/*/cfg/`.
   Map five of its `ECMC_*` variables onto their YAML equivalents. Then find one
   YAML key with no `ECMC_*` counterpart.

### Expected outcomes

- An axis that jogs and positions to a measured target, closed on the scale.
- Correct absolute position at power-on with no homing move.
- You can explain why this terminal must run CSP, and what breaks otherwise.
- You can explain why two encoders are configured and what ties their frames.
- You can state the trade-off between `.ax` and YAML, with a concrete example of
  something only one can express.

---

## Next

[`../04-advanced/`](../04-advanced/) — the PLC engine, virtual axes and axis
groups, data storage, plugins, and `cpp_logic`.
