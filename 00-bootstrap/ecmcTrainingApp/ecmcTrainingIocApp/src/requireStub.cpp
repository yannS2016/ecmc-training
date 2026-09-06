/*****************************************************************************
 * requireStub.cpp
 *
 * A verifying stand-in for the PSI/ESS `require` iocsh command.
 *
 * WHY THIS EXISTS
 * ---------------
 * ecmccfg is written for sites that load EPICS modules at runtime with
 * `require` (see ../../../appendix-require.md).  This course targets a site
 * that builds modules the standard EPICS way -- configure/RELEASE, linked at
 * build time -- so the `require` command does not exist in our IOC shell.
 *
 * ecmccfg calls it exactly once, in startup.cmd:
 *
 *     require ecmc "${ECMC_VER}"
 *
 * Everything else ecmccfg needs from require is plain environment variables
 * (<module>_DIR, <module>_DB), which our st.cmd sets directly.  Since this IOC
 * already links ecmc, asyn, motor and exprtkSupport, there is genuinely
 * nothing left for `require` to load.
 *
 * WHY IT IS NOT A NO-OP
 * ---------------------
 * Silently ignoring the call would let an unset or mistyped <module>_DIR sail
 * past this point and resurface much later as a baffling "file not found" from
 * some nested ecmccfg script.  So this command verifies the contract that our
 * st.cmd is supposed to have already satisfied, and fails loudly here -- at
 * the line that names the module -- if it has not.
 *
 * Failure is fatal via exit(EXIT_FAILURE), matching ecmc's own convention for
 * unrecoverable configuration errors (see ecmcConfigOrDie() and
 * ecmcFileExist() in ecmc/devEcmcSup/com/ecmcAsynPortDriver.cpp).
 *
 * This file is the ONLY thing standing between stock ecmccfg scripts and a
 * plain-EPICS IOC.  ecmccfg itself is never patched.
 *****************************************************************************/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include <iocsh.h>
#include <epicsExport.h>
#include <epicsStdio.h>

/* Build "<module>_DIR" the same way require does, so scripts that read
   ${ecmccfg_DIR} find exactly what we verified here. */
static int moduleDirVarName(const char *module, char *buf, size_t bufLen) {
  int n = snprintf(buf, bufLen, "%s_DIR", module);

  return (n > 0 && (size_t)n < bufLen) ? 0 : -1;
}

static int isDirectory(const char *path) {
  struct stat st;

  if (stat(path, &st) != 0) {
    return 0;
  }
  return S_ISDIR(st.st_mode);
}

/** iocsh command: require <module> [version] [macros]
 *
 * Verifies that <module>_DIR is set and points at a real directory.
 * Prints what was requested versus what is linked in, then continues.
 */
int requireStub(const char *module, const char *version, const char *macros) {
  char varName[256];

  if (!module || module[0] == '\0') {
    printf("Error: require: module name missing.\n");
    printf("       Usage: require <module> [version] [macros]\n");
    exit(EXIT_FAILURE);
  }

  if ((strcmp(module, "-h") == 0) || (strcmp(module, "--help") == 0)) {
    printf("Usage: require <module> [version] [macros]\n");
    printf(
      "       Verifying stand-in for the PSI/ESS require command.  This IOC\n");
    printf(
      "       links its modules at build time, so nothing is loaded here.\n");
    printf("       The command only checks that <module>_DIR is set and real.\n");
    return 0;
  }

  if (moduleDirVarName(module, varName, sizeof(varName)) != 0) {
    printf("Error: require: module name \"%s\" is too long.\n", module);
    exit(EXIT_FAILURE);
  }

  const char *moduleDir = getenv(varName);

  if (!moduleDir || moduleDir[0] == '\0') {
    printf("Error: require: \"%s\" is not set.\n", varName);
    printf(
      "       This IOC does not load modules at runtime, so `require %s` cannot\n",
      module);
    printf("       find it for you.  Set the path before the ecmccfg scripts run:\n");
    printf("\n");
    printf("           epicsEnvSet(\"%s\", \"/path/to/%s/\")\n", varName, module);
    printf("\n");
    printf(
      "       See 00-bootstrap/VERIFY.md for the full st.cmd preamble this\n");
    printf("       course expects.\n");
    exit(EXIT_FAILURE);
  }

  if (!isDirectory(moduleDir)) {
    printf("Error: require: %s=\"%s\" is not a directory.\n",
           varName,
           moduleDir);
    printf(
      "       For ecmccfg this must be the STAGED (flattened) install, not the\n");
    printf(
      "       source checkout -- ecmccfg scripts reference each other by bare\n");
    printf("       filename.  Run 00-bootstrap/stage-ecmccfg.sh first.\n");
    exit(EXIT_FAILURE);
  }

  /* Informational: makes the IOC log say which version the config asked for,
     which is the one genuinely useful thing require printed. */
  if (version && version[0] != '\0') {
    printf("require: %s %s (requested) -> %s [linked at build time]\n",
           module,
           version,
           moduleDir);
  } else {
    printf("require: %s -> %s [linked at build time]\n", module, moduleDir);
  }

  if (macros && macros[0] != '\0') {
    printf("require: %s: ignoring macros \"%s\" (not supported by this stub)\n",
           module,
           macros);
  }

  return 0;
}

/* --- iocsh registration -------------------------------------------------- */

static const iocshArg requireStubArg0 = { "module",  iocshArgString };
static const iocshArg requireStubArg1 = { "version", iocshArgString };
static const iocshArg requireStubArg2 = { "macros",  iocshArgString };
static const iocshArg *const requireStubArgs[] = {
  &requireStubArg0,
  &requireStubArg1,
  &requireStubArg2
};
static const iocshFuncDef requireStubFuncDef = { "require", 3, requireStubArgs };

static void requireStubCallFunc(const iocshArgBuf *args) {
  requireStub(args[0].sval, args[1].sval, args[2].sval);
}

static void requireStubRegister(void) {
  iocshRegister(&requireStubFuncDef, requireStubCallFunc);
}

extern "C" {
epicsExportRegistrar(requireStubRegister);
}
