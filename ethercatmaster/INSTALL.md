# Installing the IgH EtherCAT master — runbook

Target: **Rocky/RHEL 9.8**, kernel `5.14.0-687.10.1.el9_8.0.1.x86_64`, IgH EtherCAT master **1.6.12**,
installed to **`/opt/etherlab`**.

Read `BUILD.md` first — it explains *why* each choice below is what it is. This file is
the command sequence.

Every step is idempotent or has an explicit rollback (§11). Steps 1-9 need `sudo`.

---

## This host

| | `eno1` | `enp0s20f0u4` |
|---|---|---|
| Hardware | Intel Ethernet Connection (5) I219-LM | USB 10/100/1000 LAN |
| Driver | `e1000e` | `r8152` |
| MAC | `f4:39:09:06:88:69` | `00:e0:4c:68:0d:5b` |
| IP | none | 192.168.0.4 |
| **Role** | **EtherCAT** | **management — never touch** |

`eno1` is the EtherCAT NIC: Intel silicon, well supported by EtherLab, and carrying no IP so taking it
costs nothing. The management NIC uses `r8152`, for which EtherLab ships no driver at all, so it cannot be
hijacked by a configuration mistake.

Set these once per shell; every later step uses them.

```bash
export EC_SRC=$HOME/src/ethercat          # your ethercat checkout
export EC_NIC=eno1
export EC_MAC=f4:39:09:06:88:69
```

---

## 0. Survey — confirm nothing has changed

```bash
cat /etc/os-release
uname -r
lspci -k | grep -A3 -i ethernet
ip -br addr
ethtool -i "$EC_NIC"
mokutil --sb-state 2>/dev/null || echo "no mokutil - legacy BIOS, Secure Boot not a concern"
```

Expected: `$EC_NIC` shows `driver: e1000e`, `ip -br addr` shows **no address** on it, and the address you
are connected over is on `enp0s20f0u4`.

> **Stop if `$EC_NIC` has an IP address.** You are about to take that interface away from the network
> stack. Confirm you are not connected through it.

Optionally run the pre-build check from `BUILD.md` §11 — it prints the driver availability
verdict for your exact kernel.

---

## 1. Prerequisites

```bash
sudo dnf group install -y "Development Tools"
sudo dnf install -y autoconf automake libtool pkgconf-pkg-config \
                    kernel-devel-"$(uname -r)" kernel-headers \
                    elfutils-libelf-devel ethtool
```

Verify the kernel sources — the single most common cause of a failed configure:

```bash
ls -d /usr/src/kernels/"$(uname -r)"
test -r /usr/src/kernels/"$(uname -r)"/Makefile && echo OK || echo "MISSING"
cat /usr/src/kernels/"$(uname -r)"/include/config/kernel.release
```

The last command must print your running `uname -r`, exactly.

> If `kernel-devel-$(uname -r)` is not available, your running kernel is older than the current repo
> contents. Run `sudo dnf update && sudo reboot`, then start again from step 1. Do **not** install a
> different `kernel-devel` version to silence the error — see `BUILD.md` §2.

---

## 2. Select the release

```bash
cd "$EC_SRC"
git remote -v                      # must be https://gitlab.com/etherlab.org/ethercat.git
git status --short                 # must be empty
git fetch --tags origin
git checkout -b build-1.6.12 1.6.12
git describe --tags                # must print exactly: 1.6.12
```

Do not build from the `stable-1.6` tip. See `BUILD.md` §10.

---

## 3. Configure

`configure` is not in the repository — `./bootstrap` generates it from `configure.ac`.

```bash
cd "$EC_SRC"
./bootstrap

./configure \
  --prefix=/opt/etherlab \
  --sysconfdir=/etc \
  --with-linux-dir=/usr/src/kernels/"$(uname -r)" \
  --enable-generic \
  --enable-e1000e \
  --enable-tool \
  --enable-userlib \
  --enable-hrtimer \
  --disable-eoe \
  2>&1 | tee configure.log
```

Why each flag:

| Flag | Reason |
|---|---|
| `--prefix=/opt/etherlab` | the convention across ecmc, ecmccfg and this course. `devEcmcSup/Makefile` and `ecmccfg/startup.cmd` both hardcode it as their default. |
| `--sysconfdir=/etc` | puts the config at `/etc/ethercat.conf`. Without it you get `/opt/etherlab/etc/ethercat.conf` and `ethercatctl` will not find it. |
| `--with-linux-dir=...` | explicit beats the `/lib/modules/$(uname -r)/build` symlink guess. |
| `--enable-generic` | the fallback that always works. Default is on, stated for clarity. |
| `--enable-e1000e` | **default is `no`.** Without this there is no `ec_e1000e.ko`. Matches the I219-LM. |
| `--enable-tool` | the `ethercat` CLI. `ecmccfg/startup.cmd:154` calls it; `preflight.sh` checks for it. Default yes. |
| `--enable-userlib` | `libethercat.so` + `ecrt.h`. **This is the half ecmc compiles against.** Default yes. |
| `--enable-hrtimer` | default `no`; use high-resolution timers for idle-phase scheduling. |
| `--disable-eoe` | default is `yes`. Ethernet-over-EtherCAT bridges the fieldbus into the host IP stack; off unless a slave needs it. See §10.4. |

Deliberately **not** enabled: `--enable-igb`, `--enable-igc`, `--enable-8139too`, `--enable-r8169` — no
such hardware here, and every extra driver is more kernel code loaded for nothing.

Check the output before continuing:

```bash
grep -E 'Linux kernel sources|kernel for e1000e|e1000e source layout|generic|userspace library|command-line tool' configure.log
```

Expect `Kernel 5.14`, `for kernel for e1000e driver... 5.14`, and layout `>= 3.10`.

> **If configure fails with `kernel 5.14 not available for e1000e driver!`** — drop `--enable-e1000e` and
> re-run. `generic` alone is a fully supported configuration and the rest of this runbook is unchanged.

---

## 4. Build and install

```bash
cd "$EC_SRC"
make all modules -j"$(nproc)"
```

> **This is the real compatibility test.** Rocky 9's `5.14` carries years of Red Hat backports, so the
> forked `netdev-5.14-ethercat.c` may not compile even though configure accepted it
> (`BUILD.md` §5). If the failure is inside `devices/e1000e/`, re-run step 3 without
> `--enable-e1000e`, then `make clean && make all modules`. Losing the native driver costs latency, not
> function.

```bash
sudo make modules_install install
sudo depmod -a
```

Verify what landed:

```bash
ls -1 /lib/modules/"$(uname -r)"/ethercat/     # ec_master.ko, ec_generic.ko, ec_e1000e.ko
ls -1 /opt/etherlab/lib/libethercat.*
ls -1 /opt/etherlab/include/ecrt.h
ls -1 /opt/etherlab/bin/ethercat /opt/etherlab/sbin/ethercatctl
modinfo /lib/modules/"$(uname -r)"/ethercat/ec_master.ko | grep -E 'vermagic|version'
```

The `vermagic` must match `uname -r`.

---

## 5. Linker path

ecmc links with an rpath, but the `ethercat` CLI and anything else built later benefit from a system-wide
entry. This mirrors what `ecmc/.ci/ethercat.bash` does.

```bash
echo /opt/etherlab/lib | sudo tee /etc/ld.so.conf.d/ethercat.conf
sudo ldconfig
ldconfig -p | grep ethercat        # expect libethercat.so.1 => /opt/etherlab/lib/...
```

---

## 6. Take `eno1` away from NetworkManager

Skip this and NetworkManager will run DHCP and IPv6 discovery on your EtherCAT segment, injecting
non-EtherCAT frames onto a bus with no arbitration for them.

```bash
sudo nmcli device set "$EC_NIC" managed no
nmcli device status | grep "$EC_NIC"        # expect: unmanaged
```

To make it survive a NetworkManager restart:

```bash
printf '[keyfile]\nunmanaged-devices=mac:%s\n' "$EC_MAC" \
  | sudo tee /etc/NetworkManager/conf.d/99-ethercat.conf
sudo systemctl reload NetworkManager
```

---

## 7. Configure the master

```bash
# Either edit by hand (below), or apply the tracked settings:
#     cd config && ./apply-config.sh --dry-run && sudo ./apply-config.sh
sudo cp /etc/ethercat.conf /etc/ethercat.conf.orig
sudo vi /etc/ethercat.conf
```

Set exactly these three, leaving everything else at its default:

```sh
MASTER0_DEVICE="f4:39:09:06:88:69"
DEVICE_MODULES="generic"
UPDOWN_INTERFACES="eno1"
```

- **`MASTER0_DEVICE` — use the MAC, not `eno1`.** `ethercatctl` resolves either
  (`script/ethercatctl.in:73-89`), but interface names can be renamed by udev or a firmware update; the MAC
  cannot. It is also what determines how many masters exist: one non-empty `MASTER<n>_DEVICE` per master.
- **`DEVICE_MODULES="generic"` to start.** Switch to `"e1000e"` in step 9 once the bus works. Get one
  variable wrong at a time.
- **`UPDOWN_INTERFACES` is mandatory with `generic`.** The generic driver opens a raw socket on the
  interface, so the link must be up before `ec_master` loads or every frame times out.
  `ethercatctl start` brings these up first (`ethercatctl.in:96-99`).

Systemd ordering — as a drop-in, not by editing the shipped unit:

```bash
sudo mkdir -p /etc/systemd/system/ethercat.service.d
sudo tee /etc/systemd/system/ethercat.service.d/50-dependencies.conf >/dev/null <<'EOF'
# Generic driver: the network interfaces must be configured before the master starts.
[Unit]
Requires=network.target
After=network.target
EOF
sudo systemctl daemon-reload
```

> Switching to the native driver later means swapping these for `Before=network-pre.target` /
> `Wants=network-pre.target` — step 9 covers it. The two sets are mutually exclusive; the reasoning is in
> the comments of `script/ethercat.service.in`.

---

## 8. Device permissions

Upstream `INSTALL.md` suggests `MODE="0664"` to give normal users read access. **Do not use that.** The
same character device backs `ethercat download`, `ethercat sii_write` and `ethercat foe_write`, which can
reconfigure slaves or brick their EEPROM. Use a group instead.

```bash
sudo groupadd -f ethercat
sudo usermod -aG ethercat "$USER"          # and the account the IOC runs as

printf 'KERNEL=="EtherCAT[0-9]*", MODE="0660", GROUP="ethercat"\n' \
  | sudo tee /etc/udev/rules.d/99-EtherCAT.rules

sudo udevadm control --reload-rules
```

Group membership applies at next login. `newgrp ethercat` for the current shell.

---

## 9. Start and verify

```bash
sudo systemctl enable --now ethercat
systemctl status ethercat --no-pager
lsmod | grep '^ec_'                        # ec_master, ec_generic
ls -l /dev/EtherCAT0                       # crw-rw---- root ethercat
journalctl -k -b | grep -i ethercat | tail -20
```

Then the master itself:

```bash
/opt/etherlab/bin/ethercat master
/opt/etherlab/bin/ethercat slaves
/opt/etherlab/bin/ethercat pdos | head -40
```

`ethercat master` should report `Phase: Idle` with your MAC as the main device. `ethercat slaves` lists the
bus; empty output with hardware connected means cabling, power, or the wrong port on the first slave (IN
vs OUT).

Put `/opt/etherlab/bin` on `PATH` for convenience:

```bash
echo 'export PATH=/opt/etherlab/bin:$PATH' | sudo tee /etc/profile.d/etherlab.sh
```

### Optional: switch to the native `e1000e` driver

Only after the above works, and only if you built `ec_e1000e.ko`.

```bash
sudo systemctl stop ethercat
sudo sed -i 's/^DEVICE_MODULES=.*/DEVICE_MODULES="e1000e"/' /etc/ethercat.conf

sudo tee /etc/systemd/system/ethercat.service.d/50-dependencies.conf >/dev/null <<'EOF'
# Native driver: the master replaces the stock NIC driver, so it must run before
# the network configuration tools look at the interfaces.
[Unit]
Before=network-pre.target
Wants=network-pre.target
EOF

sudo systemctl daemon-reload
sudo systemctl start ethercat
lsmod | grep -E '^ec_e1000e|^e1000e'       # ec_e1000e present, e1000e absent
/opt/etherlab/bin/ethercat master
```

`ethercatctl start` `rmmod`s the stock `e1000e` and loads `ec_e1000e` in its place
(`ethercatctl.in:135-160`); `stop` reverses it. Safe here because `eno1` is the only `e1000e` device and
your management link is on `r8152`.

If anything regresses, revert `DEVICE_MODULES` to `"generic"` and the drop-in to the step 7 version.

---

## 10. Wire it into ecmc and the course

### Standalone ecmc build

`ecmc/configure/RELEASE` sets `ETHERLAB = $(SUPPORT)/etherlab`, which defeats the `ETHERLAB ?= /opt/etherlab`
in `devEcmcSup/Makefile` — the `?=` never fires. Override it explicitly:

```bash
echo 'ETHERLAB = /opt/etherlab' >> <ecmc>/configure/RELEASE.local
```

### Training course

```bash
grep '^ETHERLAB' <training>/site.conf        # ETHERLAB=/opt/etherlab
<training>/00-bootstrap/preflight.sh
```

The four checks under `== EtherCAT (Etherlab master) ==` must now report `PASS`: etherlab headers,
`libethercat`, the `ethercat` CLI, and "EtherCAT master responds". Then:

```bash
<training>/00-bootstrap/bootstrap.sh
ldd <training>/00-bootstrap/ecmcTrainingApp/bin/$EPICS_HOST_ARCH/ecmcTrainingIoc | grep ethercat
```

That last line must resolve to `/opt/etherlab/lib/libethercat.so*`. It is the real proof that the install,
the rpath and the ecmc build all agree.

### Realtime privileges for the IOC

The IOC needs `SCHED_FIFO`. Grant it to the group, not by running as root:

```bash
sudo tee /etc/security/limits.d/99-ecmc.conf >/dev/null <<'EOF'
@ethercat  -  rtprio   90
@ethercat  -  memlock  unlimited
EOF
```

---

## 11. Rollback

```bash
sudo systemctl disable --now ethercat
sudo rmmod ec_generic ec_e1000e ec_master 2>/dev/null
sudo modprobe e1000e                          # only if the native driver was in use
sudo rm -rf /lib/modules/"$(uname -r)"/ethercat
sudo rm -rf /opt/etherlab
sudo rm -f /etc/ethercat.conf /etc/ld.so.conf.d/ethercat.conf \
           /etc/udev/rules.d/99-EtherCAT.rules \
           /etc/NetworkManager/conf.d/99-ethercat.conf \
           /etc/profile.d/etherlab.sh
sudo rm -rf /etc/systemd/system/ethercat.service.d
sudo rm -f /usr/lib/systemd/system/ethercat.service
sudo depmod -a && sudo ldconfig && sudo systemctl daemon-reload
sudo nmcli device set eno1 managed yes
```

Verify clean: `lsmod | grep ec_` is empty and `ethtool -i eno1` shows `e1000e` again.

---

## 12. Surviving a kernel update

The module is built against exactly one `uname -r`. A `dnf update` that installs a new kernel silently
invalidates it — after the reboot the master is gone.

For this training host, freeze the kernel:

```bash
sudo dnf install -y 'dnf-command(versionlock)'
sudo dnf versionlock add kernel kernel-devel kernel-core kernel-modules
sudo dnf versionlock list
```

This means **you stop receiving kernel security updates.** That is a deliberate trade, appropriate for an
isolated lab machine and not for anything else. The alternative — rebuild after every kernel update — is:

```bash
sudo reboot                                   # into the new kernel first
sudo dnf install -y kernel-devel-"$(uname -r)"
cd "$EC_SRC" && make clean
# re-run steps 3 and 4
```

---

## 13. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `configure: error: Failed to find Linux sources` | no `kernel-devel` for the running kernel | step 1 |
| `configure: error: kernel 5.14 not available for e1000e driver!` | no forked driver for your version | drop `--enable-e1000e`, use `generic` |
| compile error inside `devices/e1000e/` | RHEL backports diverged from upstream 5.14 | drop `--enable-e1000e`, `make clean`, rebuild |
| `Invalid module format` / `dmesg: version magic ... should be ...` | module built against a different kernel | rebuild against the running kernel (§12) |
| module load refused, `Key was rejected by service` | Secure Boot on, module unsigned | enrol a MOK, or disable Secure Boot knowing the cost |
| `ethercat: command not found` | `/opt/etherlab/bin` not on `PATH` | step 9 `profile.d` line |
| `libethercat.so.1: cannot open shared object file` | missed step 5 | `ldconfig` entry |
| `ERROR: No network cards for EtherCAT specified` | `MASTER0_DEVICE` empty | step 7 |
| master starts, `Phase: Idle`, 0 slaves | cabling, slave power, or IN/OUT reversed on the first slave | check link LEDs; `ethtool eno1` shows `Link detected: yes` |
| all frames time out with `generic` | interface not up | `UPDOWN_INTERFACES="eno1"` in step 7 |
| `rmmod e1000e` fails on native start | NetworkManager holding the interface | step 6 |
| ecmc build: `ecrt.h: No such file or directory` | the `configure/RELEASE` `ETHERLAB` trap | step 10 |
| `Permission denied` on `/dev/EtherCAT0` | not in the `ethercat` group yet | log out and in, or `newgrp ethercat` |

---

## 14. Security and safety implications

Installing this is not a neutral act. Each item below is a real consequence with the mitigation this
runbook already applies.

**1. Ring-0 code with no distro review.** `ec_master.ko` and the patched NIC drivers run in kernel space.
A bug is a panic or a root compromise, not a crashed process. This is inherent to the design and cannot be
mitigated away — it is the reason for choosing a released tag over a branch tip (§2) and for keeping the
enabled driver set minimal (§3).

**2. The bus is inside the threat model.** The master parses CoE, FoE, SoE and EoE mailbox traffic from
slaves *in kernel context*. Upstream `NEWS.md` for 1.6.10 lists "Security fixes against malicious
subdevices" — a protected `rec_size` calculation in FoE and validation of EoE frame details. A hostile or
merely faulty slave is a genuine attack path. This is the strongest single argument for 1.6.12 over the
1.5.2-based fork ecmc's dead CI installs, which never received those fixes.

**3. EtherCAT has no authentication and no encryption.** It is raw layer 2 (EtherType `0x88A4`). Anyone
with physical access to the segment can command any drive on it. Mitigation: a dedicated NIC (§7), a
physically isolated bus, and never bridging it to the site network.

**4. EoE bridges the fieldbus into the host IP stack.** Disabled at build time via `--disable-eoe` (§3).
Re-enable only for a slave that genuinely needs it, and understand you are creating a route between the
two networks when you do.

**5. Motion is a physical-safety hazard, and this is not a safety system.** Functional safety must be
independent of ecmc and of EtherCAT — hardwired E-stop and STO. Do not treat an ecmc PLC interlock or a
soft limit as a safety function. Only certified FSoE equipment carries safety over EtherCAT.

**6. `/dev/EtherCATx` is a privileged interface, not a read-only one.** Upstream suggests `0664` "to give
normal users reading access", but the same device backs `ethercat download`, `sii_write` and `foe_write` —
enough to reconfigure a drive or brick a slave's EEPROM. §8 uses `0660 root:ethercat` and puts only the IOC
account in that group.

**7. Kernel taint and loss of vendor support.** Loading an out-of-tree module taints the kernel; Red Hat
will not support a tainted kernel. Check with `cat /proc/sys/kernel/tainted` (non-zero after loading).

**8. Secure Boot.** Unsigned out-of-tree modules are refused. Enrolling a MOK is the correct answer;
disabling Secure Boot works but trades away boot integrity for the whole machine. Make that trade
knowingly rather than as a step in a tutorial.

**9. A native driver takes its NIC exclusively.** Point one at your management interface and you lose the
host. Structurally safe here — the management NIC is `r8152` and EtherLab ships no `r8152` driver — but the
`MASTER0_DEVICE` MAC in §7 is what makes it explicit.

**10. Frozen kernel versus unpatched kernel.** §12's `versionlock` stops kernel security updates. On an
isolated training host that is defensible; on anything reachable from a wider network it is not. Choose,
and write down which you chose.

**11. Realtime privileges without root.** The IOC needs `SCHED_FIFO` and locked memory. §10 grants both to
the `ethercat` group via `limits.d`. Running the IOC as root to get them would hand a bus-facing process
full system privilege.

**12. Supply chain.** The `1.6.12` tag is annotated but **not GPG-signed**, so there is no signature to
verify. Provenance rests on the remote being `https://gitlab.com/etherlab.org/ethercat.git` and the tree
being clean — both checked in §2.

---

## Reference

- `BUILD.md` — compatibility rules and requirements, in depth
- `config/` — the site configuration, version controlled, applied by `apply-config.sh`
- `../00-bootstrap/VERIFY.md` — what a working phase-00 training IOC looks like
- Upstream handbook: <https://gitlab.com/etherlab.org/ethercat/-/jobs/artifacts/stable-1.6/raw/pdf/ethercat_doc.pdf?job=pdf>
- Device driver support table: <https://docs.etherlab.org/ethercat/1.6/doxygen/devicedrivers.html>
