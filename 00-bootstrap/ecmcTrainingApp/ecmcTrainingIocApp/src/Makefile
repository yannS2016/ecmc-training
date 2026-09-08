TOP=../..

include $(TOP)/configure/CONFIG
#----------------------------------------
#  ADD MACRO DEFINITIONS AFTER THIS LINE
#=============================

PROD_IOC = ecmcTrainingIoc

# Flags below are taken verbatim from ecmc's own example IOC
# (ecmc/ecmcExampleTop/ecmcIocApp/src/Makefile).  Do not trim them:
#   --no-as-needed  keeps the ecmc library linked even though the IOC calls
#                   into it only through iocsh-registered commands.
#   c++17           is required by ecmc itself.
USR_LDFLAGS_Linux += -Wl,--no-as-needed
USR_CXXFLAGS += -std=c++17

# --- Etherlab EtherCAT master ----------------------------------------------
# rhel% (T_A on this course's target host, rhel9-x86_64) counts as native
# Linux -- the same arch-filter fix ecmc's own devEcmcSup/Makefile and
# ecmcExampleTop need (see ../../../make-demo-branch.sh step 1). Without it,
# $(filter linux-%,$(T_A)) is empty on rhel9-x86_64 and this falls into the
# cross-compile branch, pointing -L at $(SDKTARGETSYSROOT) (empty on a host
# build) instead of $(ETHERLAB)/lib -- which is what "cannot find -lethercat"
# actually means here: not a missing library, a missing -L path.
ifneq ($(filter linux-% rhel%,$(T_A)),)
ETHERLAB ?= /opt/etherlab
USR_INCLUDES += -I$(ETHERLAB)/include
USR_CFLAGS   += -fPIC
USR_LDFLAGS  += -L$(ETHERLAB)/lib
USR_LDFLAGS  += -Wl,-rpath=$(ETHERLAB)/lib
else
USR_INCLUDES += -I$(SDKTARGETSYSROOT)/usr/include/etherlab
USR_CFLAGS   += -fPIC
USR_LDFLAGS  += -L$(SDKTARGETSYSROOT)/usr/lib/etherlab
USR_LDFLAGS  += -Wl,-rpath=$(SDKTARGETSYSROOT)/usr/lib/etherlab
endif

# --- ruckig (jerk-limited trajectory generation) ----------------------------
USR_INCLUDES += -I$(RUCKIG)/include/ruckig
USR_LDFLAGS  += -L$(RUCKIG)/build
USR_LDFLAGS  += -Wl,-rpath,'$(RUCKIG)/build'

# --- ecmccfg's compiled support ---------------------------------------------
# ecmccfg is mostly iocsh scripts, but it does ship one aSub record routine,
# ECATtimestamp, used by the EtherCAT timestamping templates.  A require-based
# site gets it from the loaded ecmccfg library; we compile it in.
# $(ECMCCFG) comes from configure/CONFIG_SITE, not RELEASE: ecmccfg is a script
# and template tree, not an EPICS module. It must point at the SOURCE checkout,
# not the staged install -- the staged directory has no src/.
SRC_DIRS     += $(ECMCCFG)/src
USR_DBDFLAGS += -I $(ECMCCFG)/dbd

DBD += ecmcTrainingIoc.dbd

ecmcTrainingIoc_DBD += base.dbd
ecmcTrainingIoc_DBD += ecmcController.dbd
ecmcTrainingIoc_DBD += ecmcMotorRecordSupport.dbd
ecmcTrainingIoc_DBD += asyn.dbd
ecmcTrainingIoc_DBD += motorSupport.dbd
ecmcTrainingIoc_DBD += ECATtimestamp.dbd
ecmcTrainingIoc_DBD += requireStub.dbd
ecmcTrainingIoc_DBD += systemStub.dbd

ecmcTrainingIoc_LIBS += ecmc
ecmcTrainingIoc_LIBS += motor
ecmcTrainingIoc_LIBS += exprtkSupport
ecmcTrainingIoc_LIBS += asyn

# ethercat and ruckig are NOT _LIBS: that tells EPICS to search for an
# EPICS-module library under this application's own lib/<T_A>/ tree, which is
# where libecmc.a lives and libethercat.a/libruckig.a never will (they are
# external archives, found through the -L already set above). SYS_LIBS just
# emits -l<name> with no search, placed after -Wl,-Bdynamic -- still after
# -lecmc, which is what resolves the ecrt_*/ruckig:: symbols it needs.
ecmcTrainingIoc_SYS_LIBS += ethercat
ecmcTrainingIoc_SYS_LIBS += ruckig

ecmcTrainingIoc_SRCS += ecmcTrainingIoc_registerRecordDeviceDriver.cpp
ecmcTrainingIoc_SRCS += ECATtimestamp.cpp
ecmcTrainingIoc_SRCS += requireStub.cpp
ecmcTrainingIoc_SRCS += systemStub.cpp

ecmcTrainingIoc_SRCS_DEFAULT += ecmcTrainingMain.cpp
ecmcTrainingIoc_SRCS_vxWorks += -nil-

ecmcTrainingIoc_LIBS += $(EPICS_BASE_IOC_LIBS)

#===========================
include $(TOP)/configure/RULES
#----------------------------------------
#  ADD RULES AFTER THIS LINE
