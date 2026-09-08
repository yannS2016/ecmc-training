/*****************************************************************************
 * systemStub.cpp
 *
 * A minimal `system` iocsh command, for hosts whose EPICS base build does
 * not register one.
 *
 * WHY THIS EXISTS
 * ----------------
 * ecmccfg's own startup.cmd (which this course does not patch) calls
 * `system "mkdir -p ..."` to create ECMC_TMP_DIR, the scratch directory it
 * renders jinja2 templates and temporary axis files into. On a stock EPICS
 * base this is normally a builtin iocsh command; on this site's base it is
 * not registered, so `system` fails with "Command system not found" the
 * first time ecmccfg needs it.
 *
 * Rather than patch or rebuild the shared EPICS base (which every other IOC
 * on this host also links against), this file registers an iocsh command
 * literally named "system" that does exactly what the missing builtin
 * would: hand the string straight to the C library system() call. This is
 * the same approach requireStub.cpp uses for `require` -- a small stand-in
 * scoped to this IOC, not a site-wide change.
 *
 * If EPICS base on this host DOES already provide `system`, registering a
 * second command with the same name is harmless: iocshRegister simply
 * replaces the earlier registration, and the behavior here (call
 * ::system(), no extra checks) matches what any earlier registration would
 * have done.
 *****************************************************************************/

#include <stdio.h>
#include <stdlib.h>

#include <iocsh.h>
#include <epicsExport.h>

int systemStub(const char *cmd) {
  if (!cmd || cmd[0] == '\0') {
    printf("Error: system: command missing.\n");
    printf("       Usage: system <shell command>\n");
    return -1;
  }

  return system(cmd);
}

/* --- iocsh registration -------------------------------------------------- */

static const iocshArg systemStubArg0 = { "command", iocshArgString };
static const iocshArg *const systemStubArgs[] = { &systemStubArg0 };
static const iocshFuncDef systemStubFuncDef = { "system", 1, systemStubArgs };

static void systemStubCallFunc(const iocshArgBuf *args) {
  systemStub(args[0].sval);
}

static void systemStubRegister(void) {
  iocshRegister(&systemStubFuncDef, systemStubCallFunc);
}

extern "C" {
epicsExportRegistrar(systemStubRegister);
}
