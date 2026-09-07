# Phase 03 — Motion IOC

**Needs:** phase 00 complete, `crate.md` from phase 01, a stepper terminal
(reference: EL7041-0052) with a motor, and digital inputs for limit switches.

**Produces:** an axis you can jog, position and home through a standard EPICS
`motorRecord`.

> ### Before you power anything
>
> This phase moves a motor. Stage 1 has **no position feedback, no limit
> switches and no software limits** — nothing stops the axis but you.
>
> - Run stage 1 on a motor that is **free to spin**, decoupled from a stage if at
>   all possible.
> - Know where your e-stop or power cut is before you type `caput`.
> - Set `I_RUN_MA` from your **motor's datasheet**. The default (900 mA) is for
>   the reference motor and will overheat a smaller one.
> - Work through the stages in order. Each adds one protection; skipping to
>   stage 3 without understanding 1 and 2 means you cannot debug it.

---

## 1. The stages

Same axis, built up in three steps. Each is a runnable IOC.

| | Config | Adds | Protection |
|---|---|---|---|
| 1 | `cfg/01-openloop.ax` | motion at all | none |
| 2 | `cfg/02-closedloop.ax` | PID, following error, soft limits, S-curve | detects a stall or jam |
| 3 | `cfg/03-homing.ax` | limit switches, homing | absolute position, end-of-travel |
| — | `cfg/axis1.yaml` | stage 3 in YAML | same axis, other syntax |

```bash
cd 03-motion-ioc
./st.cmd                                                    # stage 1
./st.cmd -m AXIS_CFG=./cfg/02-closedloop.ax
./st.cmd -m AXIS_CFG=./cfg/03-homing.ax
./st.cmd -m AXIS_CFG=./cfg/axis1.yaml,AXIS_FMT=yaml

./st.cmd -m DRV_POS=6,DIN_POS=2                             # your crate
```

Stages 2 and 3 are **delta files** — they `< ./cfg/01-openloop.ax` and override
only what changes. Read them as diffs; the diff is the lesson.

---

## 2. What changed from phase 02

The bus half is identical: declare slaves, configure over SDO, apply, go active.
Three differences:

- **`MODE=FULL`** instead of `DAQ`. Creates axis objects and the motor record
  controller. `configureAxis.cmd` explicitly aborts in DAQ mode.
- **Record update pinned to 10 ms**, not `EC_RATE`. Deliberate: the realtime
  thread runs motion at 1 kHz, and database processing must not compete with it.
- **A new step 4**, creating the axis.

---

## 3. What an axis config actually is

`cfg/01-openloop.ax` is **plain iocsh** — every line an `epicsEnvSet`. There is no
parser and no schema. `configureAxis.cmd` sources the file, then `addAxis.cmd`
reads those ~89 `ECMC_*` variables and turns them into `Cfg.*` calls.

Consequences worth internalising:

- **A typo'd variable name is silently ignored** and the parameter takes its
  default. `ECMC_CNTRL_KP` set, `ECMC_CTRL_KP` misspelled — no error, no gain,
  and an axis that tracks badly for reasons you cannot see.
- Anything valid in iocsh is valid here: macros, `$(VAR=default)`, and including
  another file with `<`.
- Variables persist after the file is sourced, which is why `configureAxis.cmd`
  runs `ecmc_axis_unset.cmd` afterwards. Configure two axes without that and the
  second inherits everything the first set but the second did not.

That last point is the strongest argument for the YAML form (§8), which validates
against a schema and rejects unknown keys.

---

## 4. The five things every axis needs

Strip away the 89 parameters and an axis is:

**1. An encoder** — where am I? Even "open loop" needs one: the motor record must
have a readback. Stage 1 uses the EL7041's internal microstep counter, which
counts *commanded* steps. **It will report a perfect position straight through a
stall**, because it is counting what was asked for, not what happened. That is
precisely why stage 2 exists.

Scaling is a ratio, deliberately not a float:

```
ECMC_ENC_SCALE_NUM   = 1        # 1 mm ...
ECMC_ENC_SCALE_DENOM = 12800    # ... per 12800 counts
```

12800 = 200 full steps/rev × 64 microsteps, with a 1 mm/rev leadscrew. **Compute
this for your hardware** — everything downstream is in these units.

**2. A drive** — how do I move? For a stepper, a velocity setpoint plus an enable
bit. `ECMC_DRV_SCALE_NUM/DENOM` maps engineering units onto the raw setpoint:
`10.0 / 32768.0` means full-scale 32768 corresponds to 10 mm/s.

**3. A trajectory generator** — where should I be *now*? Given a target, it emits
a position setpoint each cycle. `ECMC_TRAJ_TYPE`: 0 = trapezoidal, 1 = ruckig
jerk-limited.

**4. A controller** — close the loop:

```
velocity_out = KFF * traj_velocity + PID(setpoint_pos - actual_pos)
```

`KFF=1.0` does most of the work; the PID corrects what feed-forward misses.

**5. Monitoring** — is anything wrong? Following error, at-target, maximum
velocity, limit switches, soft limits. Each can interlock the axis.

---

## 5. Driving it

```bash
caput  TRAIN-MOTION:Axis1.CNEN 1        # enable the drive
caput  TRAIN-MOTION:Axis1.JOGF 1        # jog forward; JOGR reverse; 0 stops
caput  TRAIN-MOTION:Axis1.VAL  10       # move to 10 mm
caget  TRAIN-MOTION:Axis1.RBV           # readback
caput  TRAIN-MOTION:Axis1.STOP 1        # stop
caput  TRAIN-MOTION:Axis1.HOMF 1        # home (stage 3)
```

These are **standard motor record fields**. Nothing here is ecmc-specific — any
EPICS motion client, OPI or scan tool works with an ecmc axis unchanged. That is
one of ecmc's strongest cards, and worth weighing in phase 99: a TwinCAT axis
needs a gateway layer to reach EPICS at all.

ecmc-side detail lives on separate PVs under `ECMC_R` (`Axis1-`):

```bash
caget TRAIN-MOTION:Axis1-ErrId          # ecmc error code, 0 = OK
caget TRAIN-MOTION:Axis1-PosAct         # ecmc's own position
caget TRAIN-MOTION:Axis1-CntrlErr       # following error
```

When the motor record says `PROBLEM` and you need to know *why*, look here.

---

## 6. Homing

An incremental encoder knows only relative movement. Homing establishes an
absolute reference by driving to a physical feature and declaring a position.

`ECMC_HOME_PROC` selects the sequence; the full list is the `ECMC_SEQ_HOME_*`
enum in `ecmc/devEcmcSup/main/ecmcDefinitions.h`. The useful ones:

| | Sequence | Use when |
|---|---|---|
| 1 / 2 | low / high limit | limit switches only — stage 3 default |
| 3 / 4 | limit → home switch | you have a home switch; more repeatable |
| 5 / 6 | limit → home → home | second slow pass; best switch repeatability |
| 7 / 8 | to home switch | no limits involved |
| 11 / 12 | limit → encoder index | highest repeatability; needs an index pulse |
| 15 | set position | no motion — "you are here" |
| 21 / 22 | limit → single-turn absolute | absolute encoder within one turn |
| 26 | external trigger | homing on an external signal |

Two velocities matter: `HOME_VEL_TO` seeks the reference fast, `HOME_VEL_FRM`
leaves it slowly and latches the exact edge. **Repeatability is set by the slow
one** — if homing scatters, halve it before changing anything else.

A limit switch is a *safety* device: its trip point is repeatable to maybe a few
tenths of a millimetre. If you need better, home to an index pulse (11/12).

---

## 7. Trajectory: trapezoidal vs jerk-limited

`ECMC_TRAJ_TYPE=0` gives a trapezoidal velocity profile: acceleration steps
instantly from 0 to full. Infinite jerk excites every resonance in the mechanics
— audible knock, ringing at the end of a move, visible overshoot.

`ECMC_TRAJ_TYPE=1` uses **ruckig** to ramp acceleration over `ECMC_JERK`
(EGU/s³). Moves take marginally longer and settle far faster.

Exercise 4 makes you measure the difference rather than take it on trust.

---

## 8. The same axis in YAML

`cfg/axis1.yaml` is stage 3, re-expressed. Run it with `AXIS_FMT=yaml`.

**What it gives you:** structure (`controller.Kp` instead of `ECMC_CNTRL_KP`),
lists (`drive.error` instead of `ALARM_0/1/2`), jinja2 templating
(`{{ var.drv }}`), and — the real win — **schema validation**. Unknown keys are
*rejected*, so the silent-typo failure of §3 cannot happen.

**What it costs.** This is not pure iocsh. `loadYamlAxis.cmd` shells out during
`st.cmd`:

```
system ". ${ECMC_CONFIG_ROOT}pythonVenv.sh -d ${ECMC_TMP_DIR}; python ... axisYamlJinja2.py ..."
```

and `pythonVenv.sh`, on first run, creates a venv and `pip install`s `pyyaml`,
`jinja2-cli`, `yamllint` and `Cerberus`. **Your IOC wants network access to
start.** On an isolated control network, pre-install those packages system-wide;
`preflight.sh` checks and tells you which are missing.

**Two schemas, and they disagree.** The authority at runtime is
`ecmccfg/scripts/jinja2/ecmcYamlSchema.py`. The VS Code ecmcPLC extension ships
its own JSON schema (matching `**/ax*.yaml`) which is not identical — it rejects
a top-level `homing:` section that the runtime accepts. `axis1.yaml` nests
`homing:` under `encoder:`, which **both** accept and which is the more correct
form anyway: ecmc 11.x supports multiple encoders per axis, so homing belongs to
the encoder it references.

**Which to use?** Know both. `.ax` is what you will meet in most deployed systems
and in most upstream examples; YAML is where ecmccfg is going, and its validation
genuinely prevents a class of bug. Neither is going away.

---

## 9. When it will not move

In rough order of likelihood:

| Symptom | Cause |
|---|---|
| Won't move either direction, no error | limit switches read "at limit" — polarity, or nothing wired. Check `caget $(IOC):m0s001-BI01` |
| `CNEN` goes 1 then back to 0 | drive not reporting ready — check `ECMC_EC_DRV_STATUS` bit index |
| Moves then trips instantly | following error too tight, or encoder scaling/sign wrong |
| Moves the wrong way | negate `ECMC_ENC_SCALE_NUM` |
| Moves 10× too far | scaling denominator — microstepping is not what you assumed |
| Position drifts every move | open loop and losing steps: lower velocity/acceleration or raise current |
| Homing scatters | `HOME_VEL_FRM` too fast |

Always start at `Axis1-ErrId`. `ecmcReport 3` in the IOC shell dumps the whole
object tree with each object's state.

---

## Exercises

1. **Scale it properly.** Compute `ENC_SCALE_NUM/DENOM` for *your* motor,
   microstepping and mechanics. Command 10 mm and measure with a dial gauge or
   ruler. Iterate until it is right — everything downstream depends on this.
2. **Provoke a stall.** Stage 1, and gently stop the shaft by hand. Watch `RBV`:
   it keeps counting. Now stage 2 with following-error monitoring on — it trips.
   Explain in one sentence what changed.
3. **Tune the loop.** From `KP=0`, raise until the axis tracks crisply, then
   until it buzzes; back off ~30%. Add `KI` until steady-state error at rest
   disappears. Record what each did.
4. **Trapezoidal vs ruckig.** Run the same 20 mm move with `TRAJ_TYPE=0` and
   `=1`. Compare settle time and listen. `-m TRAJ_TYPE=0` overrides it.
5. **Break the limits deliberately.** Swap `LOWLIM` and `HIGHLIM` in stage 3.
   Predict the behaviour before running. Why is this failure mode dangerous, and
   what would catch it in commissioning?
6. **Home two ways.** Home with `HOME_PROC=1`, note the position. Repeat ten
   times and record the spread. Halve `HOME_VEL_FRM` and repeat. Quantify it.
7. **Both dialects.** Run `03-homing.ax` and `axis1.yaml` and confirm the axis
   behaves identically. Then introduce the same typo in each — misspell a
   controller gain. Which one tells you?

### Expected outcomes

- An axis that jogs, positions to a measured target, and homes repeatably.
- You can name the five parts of an axis and what each contributes.
- You can compute encoder and drive scaling from mechanics.
- You can pick a homing sequence for given hardware and justify it.
- You can read either config dialect and state the trade-off between them.

---

## Next

[`../04-advanced/`](../04-advanced/) — the PLC engine, virtual axes and axis
groups, data storage, plugins, and `cpp_logic`.
