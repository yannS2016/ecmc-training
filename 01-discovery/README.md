# Phase 01 — Discovery: map the crate, read the ecosystem

**Needs:** a powered, cabled EtherCAT crate and a working master (`ethercat master`
responds). No IOC required — this phase is entirely about the bus and the
framework, before any ecmc configuration exists.

**Produces:** `crate.md`, the inventory every later phase imports.

Two skills, and both are prerequisites for everything after:

1. **Read the bus.** EtherCAT is self-describing. Before writing a line of ecmc
   config you can ask the hardware what it is.
2. **Read upstream examples.** Almost all ecmc knowledge lives in
   `ecmccfg/examples/`, written for a `require`-based site. Translating them is a
   five-line mechanical operation, and doing it fluently is the difference between
   having ~100 worked examples available to you and having none.

---

## 1. The five concepts you need

Everything in phases 02–04 assumes these.

**Master and slaves.** One master (our Rocky 9 host) drives a daisy-chain of
slaves. Each slave has a **bus position** — 0, 1, 2… in cable order. ecmc
addresses slaves by that position: `ec0.s3.<entry>` is master 0, slave 3.

> Bus position is **physical order, not identity**. Insert a terminal in the
> middle and everything downstream renumbers, silently invalidating your config.
> This is why §5's identity verification matters.

**Process image.** The master builds one cyclic datagram carrying every mapped
input and output on the bus, exchanged every cycle (1 kHz by default in ecmc).
Slaves read and write their slice as it passes. This is why EtherCAT is fast, and
why the process image must be declared up front.

**PDO — Process Data Object.** The cyclic part. A PDO entry is one value in the
process image: an encoder position, a digital input bit, a temperature reading.
ecmc maps PDO entries and gives each a name you use in configuration and PLC code.

**SDO — Service Data Object.** The acyclic part: a terminal's object dictionary,
read/written outside the cyclic exchange, normally only at startup. This is where
you *configure* a terminal — "channel 1 is a PT100, two-wire, 50 Hz filter".

> **PDO vs SDO is the distinction to get right.** For the temperature terminal in
> phase 02: the *sensor type* is an SDO written once at startup; the *temperature
> value* is a PDO read every cycle. Confusing them is the most common beginner
> error.

**Distributed clocks (DC).** EtherCAT slaves can share a hardware-synchronised
clock, giving jitter far below what the master's software cycle achieves. Needed
for oversampling terminals and tight multi-axis sync; ignorable for phase 02.

---

## 2. Survey the bus

```bash
./01-discovery/survey-crate.sh
```

Read-only; it never changes slave state. It writes `master.txt`, `slaves.txt`,
`slaves-v.txt`, per-slave `pdos`/`sdos`/`info`, and an `identity.txt` summary
table.

Keep the output. When a terminal is swapped in a year and the IOC won't start,
this is the record of what the bus used to be.

### Do it by hand at least once

The script is a convenience; these are the commands worth knowing:

| Command | Answers |
|---|---|
| `ethercat master` | Is the master running? Link up? How many slaves responding? |
| `ethercat slaves` | One line per slave: position, alias, **state**, name |
| `ethercat slaves -v` | Vendor ID, product code, revision, serial, ports, DC |
| `ethercat pdos -p 3` | What cyclic data does slave 3 offer? |
| `ethercat sdos -p 3` | Slave 3's object dictionary — every configurable setting |
| `ethercat upload -p 3 0x8000 0x19` | Read one SDO right now |
| `ethercat xml -p 3` | The slave's own ESI description |

### Reading slave state

`ethercat slaves` shows a state per slave, and the progression matters:

```
INIT  →  PREOP  →  SAFEOP  →  OP
```

- **INIT** — mailbox not yet up
- **PREOP** — SDO access works, no cyclic data
- **SAFEOP** — inputs cyclic, outputs held safe
- **OP** — fully operational

With no IOC running, slaves normally sit in **PREOP**. That is correct and not a
fault. ecmc drives them to **OP** when the IOC goes active (`setAppMode.cmd`).

A slave stuck in SAFEOP once the IOC is running almost always means a process
image mismatch — the master's expectation and the slave's actual mapping disagree.

---

## 3. Map each slave to an ecmccfg hardware script

ecmccfg ships hardware descriptions for ~26 vendors. `addSlave.cmd` resolves
`HW_DESC` by direct filename construction:

```
HW_DESC=EL3202-0010   →   ${ecmccfg_DIR}ecmcEL3202-0010.cmd
```

(`addSlave.cmd` literally does `ecmcFileExist("${ECMC_CONFIG_ROOT}ecmc${HW_DESC}.cmd",1)`.)

Find what exists for a terminal you found on the bus:

```bash
ls $ECMCCFG_SRC/hardware/*/EL/ | grep -i 3202
ls $ECMCCFG_SRC/hardware/                      # vendor directories
grep -rl "EL7041" $ECMCCFG_SRC/hardware/       # everything mentioning a part
```

Remember these live in the **staged** directory at runtime, flat. The `hardware/`
tree structure is a source-organisation detail only.

**If your terminal has no script**, that is normal and not a blocker — you write
one, using an existing script for a similar terminal as the template. Phase 04
covers it. For now, record it in `crate.md` as unsupported.

---

## 4. Write `crate.md`

Create it in this directory from your survey. Every later phase reads it.

This is the **actual training crate**, as reported by `ethercat slaves`:

```markdown
# Crate inventory

Surveyed: 2026-09-07   Master: 0   NIC: eno1

| Pos | Terminal    | HW_DESC     | Used in | Notes |
|-----|-------------|-------------|---------|-------|
| 0   | EK1101      | EK1101      | —       | coupler with ID switch |
| 1   | EL5042      | EL5042      | 03      | 2ch BiSS-C encoder interface |
| 2   | EL7062-0000 | EL7062_CSP  | 03      | 2ch stepper 48 V 3 A; ch1 used, ch2 unused |

## Wiring
- Axis 1 motor: <type>, coil current <n> mA  — from the datasheet, not a guess
- Axis 1 encoder: <RLS/Renishaw/...> BiSS-C absolute, <n> bits, <n> counts/mm
- Limit switches: none wired. The EL7062 has two inputs per channel
  (binaryInputs01.0/.1) if you add them.

## Gaps
- No analog input terminal -> phase 02 cannot run. See 02-daq-ioc/README.md.
- No digital I/O terminal -> no external switch feed.
```

Fill in your own values for the encoder and motor — those numbers drive every
scaling in phase 03.

Note `HW_DESC` for position 2 is **`EL7062_CSP`**, not `EL7062`. That terminal has
a firmware bug in CSV mode and must run in CSP; phase 03 §3 explains. The
`HW_DESC` you choose here is not always just the part number on the label.

The **Product** column, which `survey-crate.sh` puts in `identity.txt`, is what
§5 checks against.

---

## 5. Identity verification, and why the IOC refuses to start

Nearly every ecmccfg hardware script calls `slaveVerify.cmd`, which issues:

```
Cfg.EcSlaveVerify(0, <slaveNum>, <vendorId>, <productId>)
```

The vendor and product IDs come from the hardware script; the actual values come
from the terminal. **Mismatch aborts IOC startup.**

This is deliberate. A motion IOC that silently drives whatever happens to be
plugged in is dangerous — wrong terminal, wrong scaling, wrong axis moving. But
it means a swapped or renumbered terminal stops the IOC dead, which feels harsh
during commissioning. ecmccfg's own manual warns:

> Blindly restarting the IOC, with only partially working EtherCAT hardware, will
> result in an inoperable IOC!

**Exercise.** Compare `identity.txt` against the hardware scripts:

```bash
grep ECMC_EC_PRODUCT_ID $ECMCCFG_SRC/hardware/Beckhoff_3XXX/EL/ecmcEL3202-0010.cmd
# epicsEnvSet("ECMC_EC_PRODUCT_ID" "0x0c823052")
```

It must equal the product code your survey reported for that position. If your
crate has a variant — `EL3202` vs `EL3202-0010` are different product codes — you
have just found the right `HW_DESC` the hard way, before it cost you an hour.

---

## 6. Translating an upstream example

This is the skill that unlocks `ecmccfg/examples/`. Here is a real one,
`examples/test/el3202-0010.script` at 11.0.8, complete:

```
require ecmccfg master

${SCRIPTEXEC} ${ecmccfg_DIR}addSlave.cmd, "SLAVE_ID=9, HW_DESC=EL3202-0010"
${SCRIPTEXEC} ${ecmccfg_DIR}ecmcEL32XX-Sensor-PT100-common.cmd
epicsEnvSet("ECMC_EC_SDO_INDEX", "0x8000")
${SCRIPTEXEC} ${ecmccfg_DIR}ecmcEL3202-0010-Sensor-chX_S+S_RegelTechnik_HTF50_PT100.cmd
```

Upstream runs it as `iocsh.bash el3202-0010.script`. To run it here:

| Upstream | Here | Why |
|---|---|---|
| *(implicit — `iocsh.bash` sets it up)* | `< ecmcPaths.cmd` as line 1 | supplies `ecmccfg_DIR`, `ecmc_DIR`, `EPICS_DB_INCLUDE_PATH` |
| *(implicit)* | `epicsEnvSet("SCRIPTEXEC","iocshLoad")` | ecmccfg dispatches nested scripts through this |
| *(implicit)* | `epicsEnvSet("ECMCCFG_INIT","")` | we call `startup.cmd` ourselves |
| `require ecmccfg master` | **keep it** | our stub verifies `ecmccfg_DIR` instead of loading |
| *(implicit)* | explicit `startup.cmd` call | upstream's `require` auto-runs it |
| `iocsh.bash foo.script` | `./st.cmd` | a normal EPICS IOC |

Everything else — every `addSlave.cmd`, every `Cfg.*` command, every SDO line — is
**unchanged**. The divergence is confined to the preamble. That is the whole
practical cost of not using `require`; see [`../appendix-require.md`](../appendix-require.md).

Note the example hard-codes `SLAVE_ID=9`. Upstream examples come from someone
else's crate, so bus positions are almost never right for yours. Always
re-derive them from `crate.md`.

---

## Exercises

1. **Survey and inventory.** Run `survey-crate.sh`, write `crate.md`. State which
   position phase 02's temperature terminal is at, and which positions phase 03
   will need.
2. **Identity check.** For every slave, confirm the product code matches the
   `ECMC_EC_PRODUCT_ID` in its ecmccfg script. Note any mismatch — you have found
   a variant, and identified the correct `HW_DESC`.
3. **PDO vs SDO.** For your temperature terminal: from `sdos`, find the object
   that selects the RTD element (hint: `0x80n0:19`). From `pdos`, find the entry
   carrying the measured value. Explain in one sentence why one is startup-only
   and the other is every cycle.
4. **Read a live SDO.** `ethercat upload -p <n> 0x8000 0x19`. Compare to what
   `ecmcEL32XX-Sensor-chX_*_PT100.cmd` would write. Do they agree? Should they?
5. **Translate.** Take any `examples/test/*.script` for hardware you own and
   convert its preamble. You will run the result in phase 02.

### Expected outcomes

- `crate.md` exists and matches the physical crate.
- You can state each slave's position, product code and `HW_DESC` without looking.
- You can explain why the IOC aborts on an identity mismatch, and defend it.
- You can convert any upstream example in under a minute.

---

## Next

[`../02-daq-ioc/`](../02-daq-ioc/) — build the temperature DAQ IOC against the
terminal you just identified.
