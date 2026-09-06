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
ifneq ($(filter linux-%,$(T_A)),)
ETHERLAB ?= /opt/etherlab
USR_INCLUDES += -I$(ETHERLAB)/include
USR_CFLAGS   += -fPIC
USR_LDFLAGS  += -L$(ETHERLAB)/lib
USR_LDFLAGS  += -lethercat
USR_LDFLAGS  += -Wl,-rpath=$(ETHERLAB)/lib
else
USR_INCLUDES += -I$(SDKTARGETSYSROOT)/usr/include/etherlab
USR_CFLAGS   += -fPIC
USR_LDFLAGS  += -L$(SDKTARGETSYSROOT)/usr/lib/etherlab
USR_LDFLAGS  += -lethercat
USR_LDFLAGS  += -Wl,-rpath=$(SDKTARGETSYSROOT)/usr/lib/etherlab
endif

# --- ruckig (jerk-limited trajectory generation) ----------------------------
USR_INCLUDES += -I$(RUCKIG)/include/ruckig
USR_LDFLAGS  += -L$(RUCKIG)/build -lruckig
USR_LDFLAGS  += -Wl,-rpath,'$(RUCKIG)/build'

# --- ecmccfg's compiled support ---------------------------------------------
# ecmccfg is mostly iocsh scripts, but it does ship one aSub record routine,
# ECATtimestamp, used by the EtherCAT timestamping templates.  A require-based
# site gets it from the loaded ecmccfg library; we compile it in.
# $(ECMCCFG) must point at the ecmccfg SOURCE checkout (not the staged install).
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

ecmcTrainingIoc_LIBS += asyn
ecmcTrainingIoc_LIBS += ecmc
ecmcTrainingIoc_LIBS += motor
ecmcTrainingIoc_LIBS += exprtkSupport

ecmcTrainingIoc_SRCS += ecmcTrainingIoc_registerRecordDeviceDriver.cpp
ecmcTrainingIoc_SRCS += ECATtimestamp.cpp
ecmcTrainingIoc_SRCS += requireStub.cpp

ecmcTrainingIoc_SRCS_DEFAULT += ecmcTrainingMain.cpp
ecmcTrainingIoc_SRCS_vxWorks += -nil-

ecmcTrainingIoc_LIBS += $(EPICS_BASE_IOC_LIBS)

#===========================
include $(TOP)/configure/RULES
#----------------------------------------
#  ADD RULES AFTER THIS LINE
