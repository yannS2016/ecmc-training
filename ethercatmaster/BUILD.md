# Building the IgH EtherCAT master — compatibility and requirements

Read this **before** `INSTALL.md`. That file tells you which commands to run; this one
tells you what has to be true for them to succeed, and how to check each condition yourself.

The short version: the EtherCAT master is an **out-of-tree kernel module**. It is welded to one exact
kernel build, and its optional native NIC drivers are welded to one upstream kernel *minor* version. Almost
every failure people hit installing it is one of those two couplings.

---

## 1. What actually gets built

`make all modules` produces four separate things. They have different compatibility rules, and ecmc needs
different subsets of them.

| Artifact | Installed to | Coupled to | Needed by ecmc? |
|---|---|---|---|
| `ec_master.ko` — the master | `/lib/modules/$(uname -r)/ethercat/` | your exact kernel build | at **run** time |
| `ec_generic.ko` / `ec_e1000e.ko` … — device modules | same | kernel (generic: loosely; native: tightly) | at **run** time, one of them |
| `libethercat.so` + `ecrt.h` — userspace realtime lib | `/opt/etherlab/{lib,include}` | the master's ABI, not the kernel | at **build and run** time |
| `ethercat` — the CLI tool | `/opt/etherlab/bin` | `/dev/EtherCATx` | diagnostics; `ecmccfg` calls it |

Consequence worth internalising: **ecmc compiles against the userspace half only.**
[`devEcmcSup/Makefile:27-32`](../../ecmc/devEcmcSup/Makefile) needs `ecrt.h` and `libethercat.so` and
nothing else. The kernel modules matter only when the IOC actually opens a master at runtime. That is why
`MASTER_ID=-1` lets the phase-00 training IOC run on a machine with no modules loaded at all.

---

## 2. Why the kernel module is version-locked

Linux deliberately has **no stable in-kernel ABI**. Structure layouts, inlined helpers and exported symbols
change between builds, so a module compiled against one kernel is not valid for another. The kernel
enforces this with a `vermagic` string baked into every `.ko`, plus symbol CRCs in `Module.symvers`.

Practical consequences:

- You must build against the headers for the kernel you are **currently running**, not the newest installed
  one. `kernel-devel-$(uname -r)` — the `$(uname -r)` is not decoration.
- `modprobe` refuses a module whose `vermagic` differs. The error is
  `insmod: ERROR: could not insert module: Invalid module format`, and `dmesg` says
  `version magic ... should be ...`.
- A `dnf update` that installs a new kernel silently invalidates your build. After the reboot the master is
  gone. See §12.

Check the coupling at any time:

```bash
uname -r
modinfo /lib/modules/$(uname -r)/ethercat/ec_master.ko | grep vermagic
```

Those two must agree.

---

## 3. Two ways to get frames onto the wire

You choose per-master at runtime, via `DEVICE_MODULES` in `/etc/ethercat.conf`. The choice is the single
biggest factor in how hard the build is.

| | `generic` | native (`e1000e`, `igb`, `igc`, …) |
|---|---|---|
| How it works | opens a `PF_PACKET`/`SOCK_RAW` socket on EtherType `0x88A4` and hands frames to the normal Linux netdev | a **forked copy of the mainline NIC driver**, patched to bypass the network stack and call the master directly |
| Kernel coupling | loose — uses only long-stable socket APIs (`sock_create_kern`, `kernel_sendmsg`) | tight — must match an upstream kernel minor version |
| Built by default | yes (`--enable-generic` is `default=enable-kernel`) | **no** — `default=no`, you must pass `--enable-<driver>` |
| Works on any NIC | yes | only NICs that driver supports |
| Latency / jitter | higher: frames traverse the kernel network stack, extra copy, softirq scheduling | lower: driver hands the frame straight to the master |
| The NIC stays a normal interface | yes, but you must not put an IP on it | no — `ethercatctl` `rmmod`s the stock driver and takes the card exclusively |

Verified in the source: `devices/generic.c:219-235` does

```c
sock_create_kern(&init_net, PF_PACKET, SOCK_RAW, htons(ETH_P_ETHERCAT), &dev->socket);
```

with `#define ETH_P_ETHERCAT 0x88A4`. There is nothing version-specific in there, which is exactly why it
builds on kernels the native drivers do not support.

**Recommendation: get `generic` working first, always.** It isolates "is my master installed correctly"
from "does the native driver compile for my kernel". Add the native driver afterwards as a measured
improvement, not as a prerequisite.

---

## 4. What "the e1000e driver has a 5.14 variant" actually means

This is the part that is easy to misread as a compatibility guarantee. It is not.

### 4a. Native drivers are forks, not abstractions

`devices/update.sh` documents the maintenance model exactly:

```bash
cp -v $f $o                          # copy mainline driver  -> netdev-<VER>-orig.c
cp -v $o $e                          #                       -> netdev-<VER>-ethercat.c
diff -u $op $ep | patch -p1 $e       # re-apply the previous version's EtherCAT patch
```

So for every supported kernel version the repo carries a **pair** of files:

- `devices/e1000e/netdev-5.14-orig.c` — a verbatim copy of `drivers/net/ethernet/intel/e1000e/netdev.c`
  from **upstream Linux 5.14**
- `devices/e1000e/netdev-5.14-ethercat.c` — the same file with the EtherCAT hooks patched in

The `-orig.c` file ships purely so you can diff it against your kernel's real source and see how far your
kernel has drifted from the reference. It is a measuring stick, not build input.

### 4b. How configure picks one

`configure.ac:117-145` derives a two-component version from your kernel sources:

```
kernelrelease = 5.14.0-687.10.1.el9_8.0.1.x86_64     # from include/config/kernel.release
regex         = ^[0-9]+\.[0-9]+                       # because major > 2
linuxversion  = 5.14                                  # <-- everything after this is discarded
```

then, at `configure.ac:411-423`:

```bash
kernels=`ls -1 ${srcdir}/devices/e1000e/ | grep -oE "^netdev-.*" | cut -d "-" -f 2 | uniq`
found=0
for k in $kernels; do
    if test "$kernele1000e" = "$k"; then found=1; fi
done
if test $found -ne 1; then
    AC_MSG_ERROR([kernel $kernele1000e not available for e1000e driver!])
fi
```

That is a **literal string comparison against a directory listing**. Nothing more. `--with-e1000e-kernel`
lets you override the guess when your kernel's driver is closer to a different version than its own number
suggests.

So "configure auto-selects the 5.14 variant" means precisely: *a file named `netdev-5.14-ethercat.c`
exists, so configure will not abort.* It is a **file-existence check, not a compile check and not a
correctness check.**

### 4c. Three levels of confidence — do not confuse them

| Level | What passed | What it proves |
|---|---|---|
| 1. `./configure` succeeds | a filename matched your truncated kernel version | almost nothing |
| 2. `make modules` succeeds | the forked driver still compiles against **your** kernel's headers | the kernel APIs it uses have not changed incompatibly |
| 3. `ethercat master` + `ethercat slaves` work | the driver actually drives your silicon and the bus responds | it works |

Only level 3 counts. Budget for the possibility of stopping at level 1 and falling back to `generic`.

---

## 5. The RHEL backport caveat

**Rocky/RHEL 9's `5.14` is not upstream `5.14`.** Red Hat picks a kernel base and then backports years of
upstream work into it while keeping the version number frozen for kABI stability. A `5.14.0-687.el9_8`
kernel contains driver and networking code substantially newer than upstream 5.14 ever had.

EtherLab's `netdev-5.14-ethercat.c` was forked from **upstream** 5.14. So on Rocky 9 the version numbers
agree while the code underneath may not. Possible outcomes, in decreasing likelihood:

1. It compiles and works — common for `e1000e`, whose internal API is comparatively stable.
2. It fails to compile — a changed struct field or helper signature. You get a hard compiler error, which
   is the *good* failure: loud and immediate.
3. It compiles but misbehaves — rarest and worst. Symptoms are frame timeouts or a NIC that never links.
   If you see that, drop to `generic` before debugging anything else.

### This is not hypothetical — it happened here, and not where expected

On Rocky 9.8 (`5.14.0-687.10.1.el9_8`), `make modules` fails in the **master itself**, before any native
driver is even reached:

```
master/cdev.c:233:19: error: assignment of read-only member 'vm_flags'
  233 |     vma->vm_flags |= VM_DONTDUMP;
```

Mainline Linux 6.3 made `vm_area_struct.vm_flags` read-only and added `vm_flags_set()`. Upstream handles
that — but guards it on the version number alone:

```c
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 3, 0)
    vm_flags_set(vma, VM_DONTDUMP);
#else
    vma->vm_flags |= VM_DONTDUMP;      /* <- el9 compiles this, and fails */
#endif
```

Red Hat backported the const change while keeping the version frozen at 5.14 for kABI stability. The
version test says "older than 6.3"; the kernel says otherwise.

Two things worth taking from this:

- **The risk is not confined to native drivers.** It applies to any upstream code guarded by
  `LINUX_VERSION_CODE`, the master core included. Choosing `generic` does not avoid it.
- **And the native `e1000e` driver failed too, on the same host, for a related but worse reason.** Its
  ethtool file needs `kernel_ethtool_coalesce` (5.15), `kernel_ethtool_ringparam` (5.17), `ethtool_keee`
  (6.9) and `kernel_ethtool_ts_info` (6.11) -- four API families backported into a 5.14 kernel. Crucially
  the `*-5.14-ethercat.c` files carry **zero** `LINUX_VERSION_CODE` guards (§4a: they are verbatim forks),
  so there is nothing to correct with a guard patch. `INSTALL.md` step 3 records the detail and settles on
  `generic`.
- **And then the master failed a second time, in `module.c`.** After `cdev.c` was patched, the build hit
  `master/module.c:115: error: too many arguments to function 'class_create'`. Mainline 6.4 dropped the
  owner argument from `class_create()`; upstream guards on `LINUX_VERSION_CODE < 6.4`; Red Hat backported
  the new signature. Same shape as `cdev.c`, same fix. **Expect a sequence, not a single failure** -- each
  patch only reveals the next guard downstream. Fix, rebuild, repeat.
- **Upstream already knows this pattern** — `devices/generic.c:265` guards on `SUSE_VERSION` alongside the
  version test for exactly this reason. It simply has no RHEL equivalent anywhere in the tree.

The two patchable failures are carried as [`patches/0001-cdev-vm_flags-const-on-rhel9.patch`](patches/) and
[`patches/0002-module-class_create-arity-on-rhel9.patch`](patches/), applied in `INSTALL.md` step 2. See
[`patches/README.md`](patches/README.md) for why source-compatibility patches are tracked while site
configuration is not.

If you want to measure the drift before building, get the kernel source RPM and diff against the reference
copy:

```bash
sudo dnf install -y rpm-build
dnf download --source kernel
rpm2cpio kernel-*.src.rpm | cpio -idmv '*linux*.tar.xz'
tar xf linux-*.tar.xz --wildcards '*/drivers/net/ethernet/intel/e1000e/netdev.c'
diff -u <path-to-ethercat>/devices/e1000e/netdev-5.14-orig.c \
        linux-*/drivers/net/ethernet/intel/e1000e/netdev.c | wc -l
```

A few hundred differing lines is normal and usually harmless. Thousands means treat the native driver as
unlikely and plan on `generic`. This step is optional — the compiler in §4c level 2 is a faster test.

---

## 6. What this checkout supports

Native driver variants shipped at tag `1.6.12`, by upstream kernel minor version:

| driver | versions available |
|---|---|
| `e1000e` | 3.2 3.4 3.6 3.8 3.10 3.12 3.14 3.16 4.4 5.4 5.10 **5.14** 5.15 6.1 6.4 6.12 |
| `igb` | 3.18 4.4 4.19 5.10 **5.14** 5.15 6.1 6.4 6.8 6.12 |
| `igc` | **5.14** 5.15 6.1 6.4 6.6 6.8 6.12 |
| `r8169` | 3.2 3.4 3.6 3.8 3.10 3.12 3.14 3.16 4.4 *(old flat layout)*; 5.10 **5.14** 5.15 6.1 6.4 6.12 *(new `devices/r8169/` layout)* |
| `e100` | 3.0 … 5.4 5.10 5.14 5.15 6.1 6.4 6.12 |
| `8139too` | 3.0 … 5.15 6.1 6.4 6.12 |
| `genet`, `macb`, `stmmac`, `ccat` | ARM/embedded and Beckhoff-specific |

Note the gaps that catch people out:

- **No `4.18`** → Rocky/RHEL **8** cannot use any native driver. `generic` only.
- **There is no `r8152` driver at all.** `r8169` is the *PCIe* Realtek driver; `r8152` is the *USB* one, and
  EtherLab has never shipped a fork of it. USB Ethernet adapters can therefore only be used via `generic` —
  and USB is a poor choice for EtherCAT regardless (bus latency, no reliable cycle timing).
- **Two file layouts coexist**, which makes naive globbing unreliable: `e1000e`, `igb`, `igc` and the modern
  `r8169` live in per-driver subdirectories, while `e100`, `8139too` and the pre-4.4 `r8169` sit as flat
  files in `devices/`. `r8169` is matched against *both*.

Each driver's version check in `configure.ac` uses its own rule, so regenerate the table with those rather
than guessing:

```bash
cd <ethercat>/devices
echo "e1000e: $(ls -1 e1000e/ | grep -oE '^netdev-[0-9.]+-'         | cut -d- -f2 | sort -uV | tr '\n' ' ')"
echo "igb:    $(ls -1 igb/    | grep -oE '^igb_main-[0-9.]+-orig'   | cut -d- -f2 | sort -uV | tr '\n' ' ')"
echo "igc:    $(ls -1 igc/    | grep -oE '^igc_main-[0-9.]+-orig'   | cut -d- -f2 | sort -uV | tr '\n' ' ')"
echo "r8169:  $( { ls -1 .    | grep -oE '^r8169-[0-9.]+-'          | cut -d- -f2
                   ls -1 r8169/ | grep -oE '^r8169_main-[0-9.]+-'   | cut -d- -f2 ; } | sort -uV | uniq | tr '\n' ' ')"
```

---

## 7. Verdict for this host

From `lshw -class network` and `uname -r`:

| | `eno1` | `enp0s20f0u4` |
|---|---|---|
| Hardware | Intel Ethernet Connection (5) **I219-LM**, PCI `0000:00:1f.6` | USB 10/100/1000 LAN (Realtek) |
| MAC | `f4:39:09:06:88:69` | `00:e0:4c:68:0d:5b` |
| In-tree driver | `e1000e` | `r8152` |
| IP address | none | **192.168.0.4** |
| Role | **→ EtherCAT** | **→ management, do not touch** |

Kernel: `5.14.0-687.10.1.el9_8.0.1.x86_64` → Rocky/RHEL **9.8**, `linuxversion` = `5.14`.

> These values are illustrative. The one place they are actually *used* is
> [`config/site-ethercat.env`](config/site-ethercat.env) -- change hardware there, not here.

**Conclusions:**

- **`eno1` is the EtherCAT NIC.** Intel I219-LM on `e1000e` is one of the best-supported combinations for
  EtherLab, and it carries no IP, so taking it is non-disruptive.
- **`--enable-e1000e` passes configure but does not compile.** `netdev-5.14-ethercat.c` exists, so the
  filename match succeeds (§4c level 1) — and then the build fails in `devices/e1000e/ethtool-*.c` against
  el9.8 headers (§4c level 2, §5). This is settled, not a risk to plan around: **build `generic` only.**
- **The master core itself needs two patches**, both `LINUX_VERSION_CODE` guards defeated by RHEL
  backports: `master/cdev.c` (`vm_flags`) and `master/module.c` (`class_create` arity). See
  [`patches/`](patches/). With those applied and `--enable-generic` alone, the build completes:
  `ec_master.ko` and `ec_generic.ko` install cleanly.
- **Secure Boot is disabled here**, confirmed with `mokutil --sb-state`, so the unsigned modules load
  without a MOK and the `sign-file` errors during `modules_install` are cosmetic.
- **Drop `--enable-igb` and `--enable-igc`** — no such hardware here. Every extra driver is more build
  surface and more kernel code loaded for nothing.
- **The management NIC is structurally safe.** EtherLab ships no `r8152` driver, so `ethercatctl` cannot
  unload it or take it, no matter what you put in `DEVICE_MODULES`. This is a genuinely comfortable
  position — on a host where both NICs used `e1000e`, a mistake in `MASTER0_DEVICE` would cost you remote
  access.
- `eno1` currently negotiates 100 Mbit/s. That is not a fault: **EtherCAT is 100BASE-TX full duplex.**
  1 Gbit capability is unused.
- Rocky 9.8 ships SELinux enforcing and a **non-realtime** kernel. Neither blocks the build. Cycle jitter
  without `PREEMPT_RT` is acceptable through phase 02 and is not acceptable for motion — see
  [`REALTIME.md`](REALTIME.md), and note that switching kernels means rebuilding these modules.

---

## 8. Build requirements

### Kernel side

| Requirement | Why | Check |
|---|---|---|
| `kernel-devel` matching `uname -r` **exactly** | §2 | `ls -d /usr/src/kernels/$(uname -r)` |
| `/usr/src/kernels/$(uname -r)/Makefile` readable | `configure.ac:110` errors `No Linux kernel sources in ...` without it | `test -r /usr/src/kernels/$(uname -r)/Makefile` |
| `include/config/kernel.release` present | how configure derives `linuxversion` (§4b) | `cat /usr/src/kernels/$(uname -r)/include/config/kernel.release` |
| `elfutils-libelf-devel` | `modpost` links against libelf | `rpm -q elfutils-libelf-devel` |
| Secure Boot off, or a MOK enrolled | unsigned out-of-tree modules are refused | `mokutil --sb-state` |

If `kernel-devel-$(uname -r)` is not in the repos, your running kernel is older than the current package
set. Either `dnf update && reboot` and build against the new one, or pull the exact version from the
vault repo. Do **not** build against a mismatched version to make the error go away.

### Userspace side

| Requirement | Why |
|---|---|
| `gcc`, `gcc-c++`, `make` | `Development Tools` group |
| `autoconf`, `automake`, `libtool` | `./bootstrap` generates `configure`; it is **not** in the git repo |
| `pkgconf-pkg-config` | `configure.ac:1421-1443` queries it for `systemdsystemunitdir`; without it the systemd unit is silently not installed |
| `udev` running | creates `/dev/EtherCATx` |
| `systemd` | the `ethercat.service` unit |

### The one that is not a package

**A dedicated NIC.** Not a VLAN, not a second IP, not a shared interface. EtherCAT needs the whole card,
and putting an IP or DHCP client on the EtherCAT segment injects non-EtherCAT frames into a bus that has
no arbitration for them.

---

## 9. ecmc-side compatibility

### API

ecmc calls the `ecrt_*` realtime API directly — no abstraction layer. It uses 47 distinct symbols across
`devEcmcSup/ethercat/*.{h,cpp}`, including the less common `ecrt_master_read_idn` / `ecrt_master_write_idn`
(SoE), `ecrt_master_select_reference_clock`, `ecrt_slave_config_watchdog` and
`ecrt_slave_config_create_sdo_request`. **All 47 are present in `include/ecrt.h` at tag 1.6.12**, checked
individually. ecmc includes `ecrt.h` with no `ECRT_VERSION_MAGIC` guard, so there is no runtime version
negotiation — the build either links or it does not.

### The ABI coupling nobody expects

`devEcmcSup/Makefile:32` bakes an rpath into the library:

```make
USR_LDFLAGS += -Wl,-rpath=$(ETHERLAB)/lib
```

Two consequences:

1. No `LD_LIBRARY_PATH` needed at runtime — good.
2. **The build-time path must equal the runtime path.** Installing the master somewhere else later, or
   swapping master generations, requires an ecmc **relink**. An `ldconfig` will not do it.

### The trap that will waste an afternoon

[`ecmc/configure/RELEASE:40`](../../ecmc/configure/RELEASE) contains:

```make
ETHERLAB = $(SUPPORT)/etherlab
```

`configure/RELEASE` is included *before* `devEcmcSup/Makefile` runs, so by the time make reaches

```make
ETHERLAB ?= /opt/etherlab
```

the variable is already set and **`?=` does not fire**. A stock ecmc build looks in `$(TOP)/../etherlab`
and fails with `ecrt.h: No such file or directory` even after a perfect `/opt/etherlab` install.

Fix, once:

```bash
echo 'ETHERLAB = /opt/etherlab' >> <ecmc>/configure/RELEASE.local
```

The training course already handles this — [`bootstrap.sh:83`](../00-bootstrap/bootstrap.sh) writes `ETHERLAB` into the
generated `RELEASE.local` from `site.conf`. The problem only bites a standalone ecmc build.

### Version expectations elsewhere in the tree

Three inconsistent signals exist; none is a hard pin:

- `ecmc/.ci/ethercat.bash` clones `icshwi/etherlabmaster` (the ESS packaging of **IgH 1.5.2**) at `master`,
  no tag. It is invoked only from `.travis.yml`, which is pinned to Ubuntu `xenial`/`bionic`. **That CI is
  dead** — there is no `.github/workflows` in ecmc. Nothing currently validates the EtherCAT build.
- `ecmc/README.md` says only "based on the open Etherlab master" and explicitly disclaims path specificity.
- PSI ships the master as an EPICS `require` module `ECmasterECMC` (v1.1.0 in
  `ecmccfg/examples/test/subst_hw_axes/readme.md`). That layer is not in this checkout.

`RELEASE.md` — all 100 KB of it, back to ecmc 4.x — contains **zero** occurrences of `etherlab`,
`libethercat`, `ecrt` or a master version number. There is no version to honour, so pick on technical
merit.

---

## 10. Which release, and why

**Use tag `1.6.12`.**

| Candidate | Verdict |
|---|---|
| `1.6.12` (tag) | **Chosen.** Latest release. Reproducible. Has the 5.14/6.x drivers. Has the 1.6.10 subdevice security fixes. |
| `stable-1.6` tip (`650888c5`, `1.6.12-7`) | 7 unreleased commits — `macb`/RasPi work and a "Kernel 6.18 test build". Irrelevant here, and a branch tip moves under you. |
| `1.5.2` / `icshwi/etherlabmaster` | **Rejected.** No device drivers for 5.14+, so it will not build on Rocky 9 at all. Also predates the malicious-subdevice fixes, and uses `/etc/sysconfig/ethercat` with older driver names. |

Provenance note: `1.6.12` is an **annotated but unsigned** tag. There is no GPG signature to verify, so
trust rests on the remote being `https://gitlab.com/etherlab.org/ethercat.git` and the tree being clean.
Confirm both before building:

```bash
git remote -v
git status --short          # expect empty
git describe --tags         # expect exactly: 1.6.12
```

---

## 11. Pre-build compatibility check

Run [`pre-build.sh`](pre-build.sh) before `./configure`. It answers every question in this document for
your host, and takes a second.

```bash
./pre-build.sh                          # check only, changes nothing
./pre-build.sh --apply                  # also apply any patch this kernel needs
./pre-build.sh /path/to/ethercat        # or say where the checkout is
EC_SRC=/path/to/ethercat ./pre-build.sh
```

It uses the same `PASS` / `WARN` / `FAIL` convention as
[`../00-bootstrap/preflight.sh`](../00-bootstrap/preflight.sh), quotes the section of this document that
explains each failure, and exits non-zero if anything is a blocker. What it checks:

| Section | Looking for |
|---|---|
| host | distro and kernel; warns on RHEL 8, where no native driver exists (§6) |
| kernel-devel | `/usr/src/kernels/$(uname -r)` **and** that its `kernel.release` matches the running kernel (§2) |
| toolchain | `gcc`, `make`, `perl`, `autoconf`, `automake`, `libtool`, `pkg-config`, libelf headers |
| secure boot | whether unsigned modules will be refused (§8) |
| ethercat checkout | that it exists, is on tag `1.6.12`, and is unmodified (§10) |
| native drivers | per-driver availability for your kernel, each test mirroring that driver's own rule in `configure.ac` |
| NICs | driver, MAC and IP per interface; the one with **no** IP is the EtherCAT candidate |

Two behaviours worth knowing, because the naive version of this check gets both wrong:

- **A missing checkout is reported as a missing checkout, not as "driver not available".** Without the
  tree there is nothing to test, so the driver section is *skipped*. Conflating the two turns a wrong
  path into what looks like a kernel-compatibility verdict.
- **`r8169` is tested against both file layouts** — flat `devices/r8169-*.c` up to 4.4, and the
  `devices/r8169/` subdirectory from 5.10. Testing both globs in a single `ls` reports failure whenever
  *either* is absent, which is always.

---

## 12. What breaks later

**A kernel update.** This is not a maybe. `dnf update` installs a new kernel, you reboot, and
`/lib/modules/<new>/ethercat/` does not exist. Symptoms:

- with `generic`: `systemctl status ethercat` fails, the IOC cannot open a master, `eno1` is unaffected.
- with a **native** driver: worse — `ethercatctl` cannot load `ec_e1000e`, and depending on ordering the
  NIC may come up with no driver at all.

Two defensible strategies:

| | When | Cost |
|---|---|---|
| `dnf versionlock add kernel kernel-devel` | training and lab boxes; anything where the machine's job is this one thing | you stop receiving kernel security updates — a real trade, make it deliberately |
| Rebuild after each kernel update (or DKMS) | long-lived / production hosts | a maintained rebuild step; upstream has an unmerged `dkms` branch, not used here |

For this host — a training machine — versionlock is the right call, with a calendar reminder rather than
a silent freeze.

**Other things that change under you:**

- `git pull` on `stable-1.6` moves you off `1.6.12`. Stay on the tag.
- Reinstalling ecmc to a different `ETHERLAB` prefix needs a relink, not an `ldconfig` (§9).
- Adding an IP or letting NetworkManager manage `eno1` puts DHCP and IPv6 traffic on the EtherCAT segment.
  Set it unmanaged.

---

## Next

`INSTALL.md` — the commands, in order, with the values from §7 filled in.
