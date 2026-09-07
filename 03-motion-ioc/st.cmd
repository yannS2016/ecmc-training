#!../00-bootstrap/ecmcTrainingApp/bin/linux-x86_64/ecmcTrainingIoc
#
# Phase 03 -- motion IOC.
#
# One axis on a Beckhoff EL7041-0052 stepper terminal, built up in stages.
# Select the stage with AXIS_CFG:
#
#   ./st.cmd                                                    # stage 1, open loop
#   ./st.cmd -m AXIS_CFG=./cfg/02-closedloop.ax
#   ./st.cmd -m AXIS_CFG=./cfg/03-homing.ax
#   ./st.cmd -m AXIS_CFG=./cfg/axis1.yaml,AXIS_FMT=yaml          # YAML form of stage 3
#
# Override bus positions from your crate.md:
#   ./st.cmd -m DRV_POS=5,DIN_POS=1
#
# SAFETY: this moves a motor. Before the first run, confirm the axis is free to
# travel, limit switches are wired and working, and you can reach an e-stop.
# Stage 1 has NO position feedback and NO software limits -- see README section 3.

< ../ecmcPaths.cmd

epicsEnvSet("IOC",          "$(IOC=TRAIN-MOTION)")
epicsEnvSet("SCRIPTEXEC",   "iocshLoad")
epicsEnvSet("ECMCCFG_INIT", "")

require ecmccfg "11.0.8"

# ---------------------------------------------------------------------------
# MODE=FULL -- the default. Creates axis objects and the motor record
# controller. Contrast phase 02, which used MODE=DAQ: configureAxis.cmd
# deliberately aborts in DAQ mode.
#
# Record update is pinned to 10 ms here rather than following EC_RATE, so
# database processing does not compete with the motion thread.
# ---------------------------------------------------------------------------
$(SCRIPTEXEC) ${ecmccfg_DIR}startup.cmd, "IOC=$(IOC),ECMC_VER=11.0.8,MODE=FULL,EC_RATE=$(EC_RATE=1000)"

# ---------------------------------------------------------------------------
# 1. Declare the bus
# ---------------------------------------------------------------------------
$(SCRIPTEXEC) ${ecmccfg_DIR}addSlave.cmd, "SLAVE_ID=$(COUPLER_POS=0), HW_DESC=$(COUPLER_HW=EK1100)"
$(SCRIPTEXEC) ${ecmccfg_DIR}addSlave.cmd, "SLAVE_ID=$(DIN_POS=1),     HW_DESC=$(DIN_HW=EL1808)"
$(SCRIPTEXEC) ${ecmccfg_DIR}addSlave.cmd, "SLAVE_ID=$(DRV_POS=5),     HW_DESC=$(DRV_HW=EL7041-0052)"

# ---------------------------------------------------------------------------
# 2. Configure the drive -- motor parameters over SDO
#
# Same PDO/SDO split as phase 02: coil current, microstepping and maximum speed
# are SDO settings written once; the velocity setpoint is cyclic PDO data.
#
# I_RUN_MA / I_STDBY_MA MUST match your motor's datasheet. Too high overheats the
# windings; too low stalls under load. There is no safe default -- look it up.
# ---------------------------------------------------------------------------
epicsEnvSet("ECMC_EC_SLAVE_NUM", "$(DRV_POS=5)")
$(SCRIPTEXEC) ${ecmccfg_DIR}applySlaveConfig.cmd, "CONFIG=$(MOTOR_CFG=-Motor-Nanotec-ST4118M1804-B), CFG_MACROS='I_RUN_MA=$(I_RUN_MA=900),I_STDBY_MA=$(I_STDBY_MA=200)'"

# ---------------------------------------------------------------------------
# 3. Apply -- build the process image (irreversible, as in phase 02)
# ---------------------------------------------------------------------------
$(SCRIPTEXEC) ${ecmccfg_DIR}applyConfig.cmd

# ---------------------------------------------------------------------------
# 4. Create the axis
#
# configureAxis.cmd sources the .ax file (which is nothing but epicsEnvSet) and
# then runs addAxis.cmd, which turns those ~89 variables into ecmc Cfg.* calls
# and loads the motor record database.
#
# DEV becomes the PV prefix for this axis: $(DEV):$(ECMC_MOTOR_NAME).
# ---------------------------------------------------------------------------
epicsEnvSet("DEV", "$(IOC)")

# Two loaders, same resulting axis. AXIS_FMT selects which:
#   AXIS_FMT=ax    (default) classic epicsEnvSet config -- pure iocsh
#   AXIS_FMT=yaml            YAML config -- shells out to Python, see README s.8
#
# ecmcEpicsEnvSetCalcTernary is ecmccfg's way of doing an if/else: it sets the
# variable to "" or "#- " and that either enables or comments out the next line.
# This is iocsh, so this is what a conditional has to look like.
epicsEnvSet("AXIS_CFG", "$(AXIS_CFG=./cfg/01-openloop.ax)")

ecmcEpicsEnvSetCalcTernary(ECMC_USE_AX,   "'$(AXIS_FMT=ax)'=='ax'",   "", "#- ")
$(ECMC_USE_AX)$(SCRIPTEXEC) ${ecmccfg_DIR}configureAxis.cmd, "CONFIG=${AXIS_CFG}"

ecmcEpicsEnvSetCalcTernary(ECMC_USE_YAML, "'$(AXIS_FMT=ax)'=='yaml'", "", "#- ")
$(ECMC_USE_YAML)$(SCRIPTEXEC) ${ecmccfg_DIR}loadYamlAxis.cmd, "FILE=${AXIS_CFG}, DEV=$(DEV)"

# ---------------------------------------------------------------------------
# 5. Diagnostics
# ---------------------------------------------------------------------------
ecmcConfigOrDie "Cfg.EcSetDiagnostics(1)"
ecmcConfigOrDie "Cfg.EcEnablePrintouts(0)"
ecmcConfigOrDie "Cfg.EcSetDomainFailedCyclesLimit(100)"

# Per-axis diagnostic printout. Enable while commissioning a specific axis:
ecmcConfigOrDie "Cfg.SetDiagAxisIndex(1)"
ecmcConfigOrDie "Cfg.SetDiagAxisFreq(2)"
ecmcConfigOrDie "Cfg.SetDiagAxisEnable($(DIAG_AXIS=0))"

# ---------------------------------------------------------------------------
# 6. Go active
# ---------------------------------------------------------------------------
$(SCRIPTEXEC) ${ecmccfg_DIR}setAppMode.cmd

iocInit()
