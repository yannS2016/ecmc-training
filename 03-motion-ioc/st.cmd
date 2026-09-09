#!../00-bootstrap/ecmcTrainingApp/bin/current/ecmcTrainingIoc
#
# Phase 03 -- motion IOC for the training crate:
#
#   0  EK1101      EtherCAT coupler (ID switch)
#   1  EL5042      2ch BiSS-C encoder interface
#   2  EL7062-0000 2ch stepper output stage (48 V, 3 A)
#
# Stages:
#   ./st.cmd                                     # stage 1, open loop
#   ./st.cmd -m STAGE=2                          # stage 2, closed loop on BiSS-C
#
# Override bus positions if yours differ:
#   ./st.cmd -m DRV_POS=2,ENC_POS=1
#
# Motor is wired to EL7062 ch2 (ch1 unused) -- baked in as the default below.
# Override if yours differs, e.g. for ch1: -m DRV_CH=01,CH_ID=1,CH_ID_OTHER=2
#
# SAFETY: this moves a motor.
#   * Set I_MAX_MA / I_STDBY_MA from YOUR motor's datasheet before first run.
#   * This crate has no digital input terminal. Unless you have wired limit
#     switches to the EL7062's own inputs AND enabled them in the config,
#     NOTHING stops the axis at end of travel except you.
#   * Run stage 1 with the motor decoupled if you can.

< ../ecmcPaths.cmd

epicsEnvSet("IOC",          "$(IOC=TRAIN-MOTION)")
epicsEnvSet("SCRIPTEXEC",   "iocshLoad")
epicsEnvSet("ECMCCFG_INIT", "")

require ecmccfg "11.0.8"

# ENG_MODE=1 adds the commissioning PVs and the hardware expert panels -- needed
# for the EL7062 auto-tune in exercise 2. Turn it off in production.
$(SCRIPTEXEC) ${ecmccfg_DIR}startup.cmd, "IOC=$(IOC),ECMC_VER=11.0.8,MODE=FULL,EC_RATE=$(EC_RATE=1000),ENG_MODE=$(ENG_MODE=1)"

# ---------------------------------------------------------------------------
# 1. Declare the bus
# ---------------------------------------------------------------------------
$(SCRIPTEXEC) ${ecmccfg_DIR}addSlave.cmd, "SLAVE_ID=$(COUPLER_POS=0), HW_DESC=$(COUPLER_HW=EK1101)"

# The EL5042 BiSS-C encoder interface.
$(SCRIPTEXEC) ${ecmccfg_DIR}addSlave.cmd, "SLAVE_ID=$(ENC_POS=1), HW_DESC=EL5042"
# Encoder-specific SDO setup: BiSS-C frame length, clock, data format. Replace
# with the component matching YOUR scale -- ls the staged dir for Encoder-*BISS*.
$(SCRIPTEXEC) ${ecmccfg_DIR}applyComponent.cmd, "COMP=$(ENC_COMP=Encoder-RLS-LA11-26bit-BISS-C), CH_ID=1"
epicsEnvSet("ENC_SID", "${ECMC_EC_SLAVE_NUM}")

# ---------------------------------------------------------------------------
# The stepper terminal -- note HW_DESC=EL7062, not EL7062_CSP.
#
# CSV, not CSP: CSP only makes sense when the drive closes its own position
# loop against a shaft-mounted encoder. Ours (EL5042) measures the LOAD, not
# the shaft, so ecmc closes the loop itself and sends velocity setpoints.
# See cfg/01-openloop.yaml's header and README section 3 for the tradeoff --
# the EL7062 has a confirmed CSV firmware bug (open-loop counter jumps to the
# nearest full turn on every disable); accepted as a known risk for now.
# ---------------------------------------------------------------------------
$(SCRIPTEXEC) ${ecmccfg_DIR}addSlave.cmd, "SLAVE_ID=$(DRV_POS=2), HW_DESC=EL7062"

# Motor electrical parameters. CHANGE THESE FOR YOUR MOTOR -- current too high
# cooks the windings, too low stalls under load.
#
# CH_ID / CH_ID_OTHER select which of the EL7062's two channels the motor is
# actually wired to. This crate's motor is on ch2 (ch1 unused) -- see crate.md.
$(SCRIPTEXEC) ${ecmccfg_DIR}applyComponent.cmd, "COMP=Motor-Generic-2Phase-Stepper, CH_ID=$(CH_ID=2), MACROS='I_MAX_MA=$(I_MAX_MA=1000),I_STDBY_MA=$(I_STDBY_MA=100),U_NOM_MV=$(U_NOM_MV=24000),L_COIL_UH=$(L_COIL_UH=1400),R_COIL_MOHM=$(R_COIL_MOHM=400)'"

# Drive current/velocity loop gains. Get these from the EL7062 auto-tune in the
# expert panel (needs ENG_MODE=1), then paste the MACROS string it gives you.
$(SCRIPTEXEC) ${ecmccfg_DIR}applyComponent.cmd, "COMP=Drive-Generic-Ctrl-Params, CH_ID=$(CH_ID=2), MACROS='$(DRV_CTRL_MACROS=L_COIL_UH=3100,R_COIL_MOHM=2620,I_TI=12,I_KP=59,V_TI=150,V_KP=176,P_KP=10)'"

# The other channel is unused. ecmc verifies that every drive channel linked to
# motion received SDO settings, and refuses to start otherwise -- so an unused
# channel must be declared unused explicitly.
$(SCRIPTEXEC) ${ecmccfg_DIR}applyComponent.cmd, "COMP=Generic-Ch-Not-Used, CH_ID=$(CH_ID_OTHER=1)"
epicsEnvSet("DRV_SID", "${ECMC_EC_SLAVE_NUM}")

# ---------------------------------------------------------------------------
# 2. Apply -- build the process image (irreversible)
# ---------------------------------------------------------------------------
$(SCRIPTEXEC) ${ecmccfg_DIR}applyConfig.cmd

# ---------------------------------------------------------------------------
# 3. Create the axis
#
# Both stages are YAML -- README section 7 explains why, and what that says
# about the two dialects (the classic .ax dialect can't express a CSP drive
# with a load-side primary encoder, the case that first forced this choice).
# ---------------------------------------------------------------------------
epicsEnvSet("DEV", "$(IOC)")

ecmcEpicsEnvSetCalcTernary(ECMC_STAGE1, "$(STAGE=1)==1", "", "#- ")
ecmcEpicsEnvSetCalcTernary(ECMC_STAGE2, "$(STAGE=1)==2", "", "#- ")

# --- Stage 1: one encoder, the drive's own step counter ---
$(ECMC_STAGE1)$(SCRIPTEXEC) ${ecmccfg_DIR}loadYamlAxis.cmd, "FILE=./cfg/01-openloop.yaml, DEV=${DEV}, AX_NAME=$(AX_NAME=M1), AXIS_ID=1, DRV_SID=${DRV_SID}, DRV_CH=$(DRV_CH=02)"

# --- Stage 2: BiSS-C is the only encoder -- see cfg/02-closedloop.yaml header ---
$(ECMC_STAGE2)$(SCRIPTEXEC) ${ecmccfg_DIR}loadYamlAxis.cmd, "FILE=./cfg/02-closedloop.yaml, DEV=${DEV}, AX_NAME=$(AX_NAME=M1), AXIS_ID=1, DRV_SID=${DRV_SID}, DRV_CH=$(DRV_CH=02), ENC_SID=${ENC_SID}, ENC_CH=01, ABS_OFFSET=$(ABS_OFFSET=0)"

# ---------------------------------------------------------------------------
# 4. Diagnostics
# ---------------------------------------------------------------------------
ecmcConfigOrDie "Cfg.EcSetDiagnostics(1)"
ecmcConfigOrDie "Cfg.EcEnablePrintouts(0)"
ecmcConfigOrDie "Cfg.EcSetDomainFailedCyclesLimit(100)"
ecmcConfigOrDie "Cfg.SetDiagAxisIndex(1)"
ecmcConfigOrDie "Cfg.SetDiagAxisFreq(2)"
ecmcConfigOrDie "Cfg.SetDiagAxisEnable($(DIAG_AXIS=0))"

# ---------------------------------------------------------------------------
# 5. Go active
# ---------------------------------------------------------------------------
$(SCRIPTEXEC) ${ecmccfg_DIR}setAppMode.cmd

iocInit()
