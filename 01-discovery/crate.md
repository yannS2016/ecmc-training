# Crate inventory

Surveyed: 2026-09-08   Master: 0   NIC: (per `master.txt` on the host)

| Pos | Terminal    | Product code | HW_DESC     | Used in | Notes |
|-----|-------------|--------------|-------------|---------|-------|
| 0   | EK1101      | 0x044d2c52   | EK1101      | —       | coupler with ID switch; 2A E-Bus |
| 1   | EL5042      | 0x13b23052   | EL5042      | 03      | 2ch BiSS-C encoder interface |
| 2   | EL7062-0000 | 0x1b963052   | EL7062_CSP  | 03      | 2ch stepper 48V 3A; ch2 used, ch1 unused |

All three verified against `$ECMCCFG_SRC/hardware/**/ecmc<HW_DESC>.cmd`'s
`ECMC_EC_PRODUCT_ID` -- exact match, no variant surprises. Vendor ID `0x2`
(Beckhoff) on all three.

All slaves reported `PREOP` with no IOC running -- correct, not a fault (see
README.md §2). Distributed clocks present and enabled on every slave (64-bit),
not yet used by any config in this course.

## Topology

Physical cable order matches logical bus position (0 -> 1 -> 2), confirmed via
`slaves-v.txt`'s port table: slave 0 port 1 (EBUS) -> slave 1; slave 1 port 1
(EBUS) -> slave 2. Slave 2's port 1 is down/closed -- end of chain, as expected
with 3 slaves and no further terminals.

## Wiring

- Axis 1 motor: bipolar stepper, wired **parallel**. Datasheet ratings
  (parallel): 4.24 A/phase, 1.4 mH/phase (1400 uH), 0.4 Ohms/phase (400 mOhm),
  1.8 deg/step. For safety, run well below the parallel current rating for
  now -- `st.cmd -m I_MAX_MA=1000` (st.cmd's own default). Leave
  `I_STDBY_MA` at its default (100). `L_COIL_UH=1400,R_COIL_MOHM=400` for
  the `Motor-Generic-2Phase-Stepper` component (`st.cmd`'s hardcoded
  defaults, 3050/2630, are for the PSI lab motor -- wrong for this one, must
  override). `U_NOM_MV=24000` -- confirmed, matches `st.cmd`'s own default,
  no override needed.
- Axis 1 encoder: Renishaw RL26BAS050C30A, BiSS-C, 26-bit absolute, 50 nm
  resolution, 1-10 MHz clock. Matches `st.cmd`'s own default
  `ENC_COMP=Encoder-RLS-LA11-26bit-BISS-C` (26-bit BiSS-C) -- no override
  needed there. `cfg/02-closedloop.yaml`'s `encoder.denominator: 4096`
  (counts/mm) assumes a 1 mm/rev stage per its own comment; with 50 nm/count
  that denominator is almost certainly wrong for this scale and must be
  re-derived once the physical stage pitch is known (README exercise 1).
- Limit switches: none wired. The EL7062 has two digital inputs per channel
  (`binaryInputs01.0`/`.1`) available if added later.

## Gaps

- No analog input terminal -> phase 02 (`02-daq-ioc`) cannot run as written.
  Deferred for now -- proceeding straight to phase 03 (motion) per current
  priority (real bus/PDO traffic for the REALTIME.md measurement), not
  skipped permanently.
- No digital I/O terminal -> no external switch feed; limit-switch exercises
  in phase 03 use the EL7062's own inputs only, when wired.
