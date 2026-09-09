# pin-rt.cmd -- pin ecmc's realtime thread to a cpuset, no reboot, no rebuild.
#
# Uses MCoreUtils (mcoreThreadModify) to set CPU affinity on the already-
# running "ecmc_rt" thread (ecmc/devEcmcSup/main/ecmcDefinitions.h,
# ECMC_RT_THREAD_NAME). Only affinity is touched here -- policy and priority
# are left as "*" (unchanged): ecmc already requests its own SCHED_FIFO
# priority at thread-creation time (ECMC_PRIO_HIGH), governed by the rtprio
# limits in ../ethercatmaster/REALTIME.md #7, and MCoreUtils would just be
# fighting that if it also tried to set priority here.
#
# Run AFTER the ecmc_rt thread exists -- i.e. after setAppMode.cmd, whether
# from st.cmd or interactively at the epics> prompt. Re-run any time to move
# it: no reboot, no rebuild, just a different CPUSET.
#
#   iocshLoad("$(PIN_RT_CMD)", "CPUSET=2-3")
#
# CPUSET is an MCoreUtils cpuset spec: a comma/dash list of CPU numbers, e.g.
# "2,3" or "2-3" -- but use the DASH form when passing it through iocshLoad's
# macro string. iocshLoad splits that string on commas to separate multiple
# KEY=value pairs, so "CPUSET=2,3" is parsed as "CPUSET=2" plus a stray,
# invalid "3" that gets silently dropped -- mcoreThreadShow will then report
# a cpuset of just "2", not the "2,3" you asked for. A dash range has no
# comma to collide with.
#
# IMPORTANT: this does NOT isolate the core from the rest of the kernel --
# see ../ethercatmaster/REALTIME.md #5 for that. sched_setaffinity only pins
# THIS thread there; something else on the host can still land on the same
# core. Use this to iterate quickly on which cores work, then take a final
# measurement with real isolcpus isolation in place too -- the two are
# complementary, not substitutes for each other.
mcoreThreadModify("ecmc_rt", "*", "*", "$(CPUSET)")
mcoreThreadShow("ecmc_rt")
