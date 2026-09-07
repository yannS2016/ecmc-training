# Phase 02 — Temperature DAQ IOC

> ### ⚠ This phase needs a terminal the training crate does not have
>
> The current crate is **EK1101 + EL5042 + EL7062-0000** — no analog input
> terminal, so there is nothing to read a PT100 with and **this IOC will not
> start against it**. `addSlave.cmd` will fail the identity check for a terminal
> that is not on the bus, which is the behaviour phase 01 §5 describes.
>
> The material is kept complete and correct for when an **EL3202-0010** (or
> EL3204 / EL3214 / EL3314) is added. Until then, read it rather than run it:
> every concept here — the five-step startup, PDO vs SDO, PV naming, how a record
> binds to EtherCAT data — carries over unchanged to phase 03, which *does* run
> on this crate.
>
> If you add a terminal, the only edits needed are `TEMP_POS` and `TEMP_HW`.

**Needs:** phase 00 complete, `crate.md` from phase 01, and a PT100 input terminal
on the bus (reference: EL3202-0010) — **not present on the current crate**.

**Produces:** a running IOC publishing two PT100 channels in °C.

**Why DAQ before motion.** Every concept here — declaring slaves, PDO vs SDO,
applying the process image, going active, how records bind to EtherCAT data — is
identical in the motion IOC. A temperature reading is just a much safer place to
make your first mistakes than a motor.

---

## 1. Run it

```bash
cd 02-daq-ioc
./st.cmd                          # reference crate positions
./st.cmd -m TEMP_POS=5            # your crate, from crate.md
```

Then:

```bash
caget TRAIN-DAQ:m0s003-AI01       # channel 1, degrees C
caget TRAIN-DAQ:m0s003-AI02       # channel 2
camonitor TRAIN-DAQ:m0s003-AI01   # warm the sensor and watch it track
```

If those names surprise you, §4 explains where every part comes from.

---

## 2. The shape of an ecmc startup script

Every ecmc IOC — DAQ or motion, two slaves or two hundred — has these five steps
in this order. `st.cmd` is commented section by section against them.

| Step | What it does | Reversible? |
|---|---|---|
| 1. **Declare slaves** | `addSlave.cmd` per terminal, in bus order | yes, until step 3 |
| 2. **Configure slaves** | SDO writes: sensor types, wiring, filters | yes, until step 3 |
| 3. **Apply** | `applyConfig.cmd` builds the process image | **no** |
| 4. **Diagnostics** | error tolerances, printouts | — |
| 5. **Go active** | `setAppMode.cmd` starts the realtime thread | — |

**Nothing may be added to the bus after step 3.** The process image is a fixed
memory layout computed once; that is what makes the cyclic exchange fast.

---

## 3. `MODE=DAQ`

`startup.cmd` takes a `MODE` macro. Passing `DAQ` instead of the default `FULL`:

- creates no axis objects and no motor record controller
- sets the EPICS record update rate to `EC_RATE` (1 kHz here) instead of the fixed
  10 ms used in `FULL` mode

That second point is the practical reason to use it: in `FULL` mode ecmc
deliberately throttles record updates to 100 Hz so that motion — which is what the
realtime thread is for — is not competing with database processing. With no
motion, that throttle is pure loss.

`NO_MR` is a third mode: motion without the motor record. Phase 03 mentions it.

---

## 4. Where the PV names come from

Nothing about `TRAIN-DAQ:m0s003-AI01` is arbitrary.

```
TRAIN-DAQ:      m0      s003        -        AI      01
└ IOC name      └master └slave pos  └sep     └key    └channel
```

- `startup.cmd` sets `SM_PREFIX = ${IOC}:` → `ECMC_PREFIX = "TRAIN-DAQ:"`.
- `addSlave.cmd` calls the naming script named by `ECMC_P_SCRIPT`, default
  `mXsXXX` (`naming/ecmcmXsXXX.cmd`), which builds:

  ```
  ECMC_P = ${ECMC_PREFIX}m${master}s${slave%03d}-
  ```

- The substitution file `db/Beckhoff_3XXX/ecmcEL3202-0010.substitutions` then
  instantiates `ecmc_analogInput-chX.template` once per channel with `KEY=AI`,
  producing `${ECMC_P}AI01` and `${ECMC_P}AI02`.

**This is why bus position appears in the PV name** — and why re-seating a
terminal renames its PVs. Other naming conventions ship in `naming/`
(`ClassicNaming`, `ESSnaming`); select one with `NAMING=` on `startup.cmd`. Choose
deliberately at the start of a project: changing it later renames every PV.

### How a record reaches EtherCAT data

From `ecmc_analogInput-chX.template`:

```
field(DTYP, "asynInt32")
field(INP,  "@asyn(${PORT},0,1)T_SMP_MS=1000/TYPE=asynInt32/ec0.s3.analogInput01?")
field(SCAN, "I/O Intr")
field(LINR, "SLOPE")
field(ESLO, "0.01")
field(TSE,  "-2")
```

- `ec0.s3.analogInput01` — master 0, slave 3, PDO entry `analogInput01`. The entry
  name comes from the hardware script's `Cfg.EcAddEntryComplete(...)` call. This
  same string works in PLC expressions (phase 04).
- `SCAN="I/O Intr"` — ecmc pushes the value; the record is not polled.
- `LINR=SLOPE`, `ESLO=0.01` — `VAL = RVAL × 0.01`. The EL3202**-0010** is the
  high-precision variant: 0.01 °C per digit. The plain EL3202 is 0.1 °C, and its
  substitution file sets `ESLO` accordingly. **Using the wrong `HW_DESC` gives you
  readings off by 10× with no error anywhere** — which is why phase 01 insisted on
  matching product codes.
- `TSE=-2` — timestamp from device support, i.e. the EtherCAT timestamp rather
  than when the record happened to process.

---

## 5. PDO vs SDO, concretely

The single most important distinction in EtherCAT configuration.

| | SDO | PDO |
|---|---|---|
| When | acyclic, at startup | every cycle |
| Here | "channel 1 is a PT100, two-wire, 0.1 Ω line resistance" | "channel 1 reads 2143" |
| In `st.cmd` | step 2, the sensor scripts | step 1, from the hardware script |
| ecmc call | `Cfg.EcAddSdo(...)` | `Cfg.EcAddEntryComplete(...)` |
| Change at runtime? | possible, unusual | that *is* the runtime |

Read `ecmcEL32XX-Sensor-chX_S+S_RegelTechnik_HTF50_PT100.cmd` in full — it is the
clearest worked SDO example in ecmccfg. Highlights:

```
0x80n0:19 = 0     RTD element: 0=Pt100, 2=Pt1000, 8=raw ohms, ...
0x80n0:1A = 0     connection: 0=two wire, 1=three wire, 2=four wire
0x80n0:1B = 3     supply line resistance, units of 1/32 ohm
```

That last one is real physics, and the script shows its working:

> Cable 1.5 m, 0.25 mm², copper 0.0175 Ω·mm²/m → R = 0.0175 × 1.5 / 0.25 = 0.1 Ω
> → 0.1 / (1/32) = 3

**Two-wire PT100 measures the cable as well as the sensor.** 0.1 Ω is roughly
0.26 °C of error at 0 °C. If your wiring differs, this number is wrong and your
readings carry a constant offset. Exercise 3 makes you fix it.

---

## 6. Verifying

```bash
ethercat slaves                       # every slave should now read OP
caget TRAIN-DAQ:m0s003-AI01           # plausible room temperature
caget TRAIN-DAQ:m0s003-AI01.RVAL      # raw counts; VAL = RVAL x 0.01
ecmcReport 3                          # in the IOC shell: full object tree
```

Sanity checks that catch real errors:

- **~20 °C at room temperature.** Reading ~2 °C means `ESLO` is 10× off — wrong
  terminal variant. Reading a huge negative number usually means an open sensor.
- **Warm the sensor by hand**; it should rise within a second or two.
- **Slaves in OP, not SAFEOP.** SAFEOP after `iocInit` means a process image
  mismatch.

---

## Exercises

1. **Move the terminal.** Physically re-seat the EL3202 at a different bus
   position. Restart with the old `TEMP_POS`. Read the error carefully — this is
   the identity check from phase 01 doing its job. Then fix `crate.md` and
   `st.cmd`, and note that the PVs have been renamed.
2. **Deliberate mismatch.** Set `TEMP_HW=EL3202` (not `-0010`). Predict what
   happens *before* running. Does it fail at declaration, at apply, or produce
   silently wrong data? Explain why.
3. **Fix the line compensation.** Measure your actual sensor cable, compute the
   resistance, convert to 1/32 Ω units, and write your own channel script based on
   the S+S one. How many °C were you out?
4. **Three-wire.** Change `0x80n0:1A` to 1 and rerun. What changes in the reading,
   and why does three-wire wiring make line compensation unnecessary?
5. **Alarm limits.** The template exposes `HIGH`/`HIHI`/`LOW`/`LOLO` and their
   severities through substitution macros. Load the substitutions with limits set
   so the channel goes MAJOR above 40 °C. Verify with `caget -a`.
6. **Add a second terminal.** Put another analog terminal from your crate into the
   IOC. You will need its `HW_DESC` and its own configuration scripts — this is
   phase 01's mapping skill applied.

### Expected outcomes

- Two PT100 channels reading correct temperature, tracking a warm hand.
- You can explain every field in the `ai` record's `INP` link.
- You can state which of your settings are SDO and which are PDO, and why.
- You can predict the effect of a wrong `HW_DESC` before running it.

---

## Next

[`../03-motion-ioc/`](../03-motion-ioc/) — the same five steps, plus an axis.
