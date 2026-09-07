# Realtime kernel for ecmc motion control

Companion to [`INSTALL.md`](INSTALL.md) and [`BUILD.md`](BUILD.md). Do this **after** the EtherCAT bus
works on the stock kernel, not before — see [§2](#2-order-of-operations).

Target: Rocky/RHEL 9.8, `5.14.0-687.10.1.el9_8.0.1.x86_64` → `kernel-rt`.

---

## 1. What realtime buys, and what it does not

ecmc runs a cyclic task — typically 1 kHz — that must do the same work in the same time slot every
millisecond. Each cycle it calls `ecrt_master_receive()`, runs the axis and PLC logic, then
`ecrt_master_send()`. Two failure modes matter:

| Symptom | Cause | Consequence |
|---|---|---|
| **Jitter** — the cycle runs, but late | preemption by another task or an interrupt | the commanded position is stale by the jitter; following error grows with velocity |
| **Overrun** — the cycle is missed entirely | a long non-preemptible section in the kernel | slaves see a missing frame; the watchdog trips; drives fault out |

A stock kernel is built for **throughput**. Worst-case latency is unbounded in practice — long spinlock
sections, non-threaded interrupt handlers and softirq processing can each delay your task by a millisecond
or more. Fine for a DAQ IOC. Fatal for coordinated motion.

`PREEMPT_RT` converts most kernel spinlocks into sleeping mutexes, threads nearly all interrupt handlers,
and adds priority inheritance. The result is not "faster" — average throughput *drops* — it is
**bounded**. That bound is the only property motion control actually needs.

> **RT is necessary but not sufficient.** An RT kernel with default firmware power management and no CPU
> isolation can be *worse* than a well-tuned stock kernel. Sections 5 and 6 are not polish; they are where
> the latency actually comes from.

---

## 2. Order of operations

Do not install the RT kernel first.

1. **Stock kernel, `generic` driver — get the bus up.** `ethercat slaves` lists your hardware and
   `ethercat master` reaches `Phase: Operation`. Cabling, MAC selection, NetworkManager and permissions all
   get debugged here, and none of it is easier on an RT kernel.
2. **Install `kernel-rt`, reboot** — §3.
3. **Rebuild the EtherCAT master against it** — §4. Non-negotiable; the existing modules will not load.
4. **Tune** — §5, §6, §7.
5. **Measure** — §8. Without a `cyclictest` number, "realtime" is an assertion.

Debugging a bus problem and a latency problem simultaneously is how a two-hour job becomes a two-day one.

---

## 3. Install the RT kernel

Rocky ships the realtime kernel in a separate repository, enabled by a release package:

```bash
sudo dnf install -y rocky-release-rt
sudo dnf install -y kernel-rt kernel-rt-devel rt-tests tuned-profiles-realtime
```

> **Verify these package names on the host before trusting them.** Repository layout differs between Rocky
> point releases, and on RHEL proper Real Time is a separate subscription entirely:
>
> ```bash
> dnf repolist --all | grep -i rt
> dnf list --showduplicates kernel-rt | tail
> ```
>
> If `rocky-release-rt` does not exist, the repo may already be present but disabled — reach for
> `--enablerepo=rt` rather than adding a third-party source.

`kernel-rt-devel` is the RT equivalent of the `kernel-devel` from `INSTALL.md` step 1, and §4 cannot
proceed without it.

Make it the default and reboot:

```bash
sudo grubby --info=ALL | grep -E '^(index|kernel)='     # find the kernel-rt entry
sudo grubby --set-default=/boot/vmlinuz-<the rt kernel>
sudo reboot
```

Confirm afterwards:

```bash
uname -r                          # ...rt<n>.<n>.el9_8.x86_64
uname -v | grep -o PREEMPT_RT     # must print PREEMPT_RT
cat /sys/kernel/realtime          # must print 1
```

`/sys/kernel/realtime` is what [`preflight.sh`](../00-bootstrap/preflight.sh) tests.

---

## 4. Rebuild the EtherCAT master — required

`kernel-rt` is a different kernel, so the modules built in `INSTALL.md` step 4 carry the wrong `vermagic`
and are refused:

```
insmod: ERROR: could not insert module ec_master.ko: Invalid module format
dmesg:  ec_master: version magic '5.14.0-687...x86_64' should be '5.14.0-687...rt...x86_64'
```

**The two compatibility patches are still required.** `kernel-rt` is the same 5.14 el9 base carrying the
same Red Hat backports, so `master/cdev.c` and `master/module.c` fail identically without them.

```bash
cd "$EC_SRC"
git status --short                       # expect: M master/cdev.c, M master/module.c

make clean
./configure \
  --prefix=/opt/etherlab --sysconfdir=/etc \
  --with-linux-dir=/usr/src/kernels/"$(uname -r)" \
  --enable-generic --enable-tool --enable-userlib --enable-hrtimer --disable-eoe
make all modules -j"$(nproc)"
sudo make modules_install install CONFIG_MODULE_SIG_ALL=
sudo depmod -a
sudo systemctl restart ethercat
```

`--with-linux-dir` resolves to the **RT** tree only because `uname -r` changed. That is the whole trick,
and the whole trap: run it from a shell you opened before the reboot and it silently rebuilds against the
old kernel, producing modules that fail exactly as above.

Verify:

```bash
modinfo /lib/modules/"$(uname -r)"/ethercat/master/ec_master.ko | grep vermagic
lsmod | grep '^ec_'
/opt/etherlab/bin/ethercat master
```

You now maintain modules for **two** kernels. Updating either orphans its modules — `INSTALL.md` §12
applies twice over.

---

## 5. Isolate CPUs

Latency comes from other work landing on the core running the cyclic task. Give it a core nothing else may
use.

```bash
lscpu | grep -E '^CPU\(s\)|Thread|Core|Model name'
```

Reserve the **highest-numbered** cores; the kernel and userspace gravitate to low ones. On a 4-core host,
isolating 2–3:

```bash
sudo tee /etc/tuned/realtime-variables.conf >/dev/null <<'EOF'
isolated_cores=2-3
isolate_managed_irq=Y
EOF
sudo tuned-adm profile realtime
sudo reboot
```

`tuned-adm profile realtime` writes the kernel command line for you — `isolcpus`, `nohz_full`, `rcu_nocbs`,
`intel_pstate=disable`, `nosoftlockup` — which is why it beats hand-editing GRUB. Check what it actually
applied rather than assuming:

```bash
cat /proc/cmdline
tuned-adm active
```

Then pin the IOC to the isolated set:

```bash
taskset -c 2,3 ./st.cmd
```

> **Do not isolate every core.** The kernel needs somewhere to run, and so do `ethercatctl`, `depmod` and
> your own shell. Leave one core free, two on a busy host.

**Hyper-threading:** disable it in firmware, or never place the cyclic task on the sibling of a busy core.
Two threads sharing one physical core share its execution units — and the resulting jitter is invisible to
every tool that merely counts logical CPUs.

---

## 6. Firmware settings

More RT latency is lost in the BIOS than in the kernel. A core in a deep C-state takes tens of microseconds
to wake, and frequency transitions stall execution outright.

| Setting | Value | Why |
|---|---|---|
| C-states / package C-states | disabled, or C1 only | exit latency lands directly on your cycle |
| SpeedStep / EIST / P-states | disabled | frequency transitions stall the core |
| Turbo Boost | disabled | opportunistic clocking is jitter by definition |
| Hyper-Threading / SMT | disabled | siblings contend for one physical core |
| Power profile | maximum performance | sets most of the above in one place |
| SMI sources (health/power monitoring) | minimise | see below |

System Management Interrupts are the ones that defeat an otherwise perfect setup. Firmware runs *below*
the kernel: an SMI preempts everything including RT threads, and Linux cannot measure or prevent it. On
vendor hardware, look for "processor power and utilisation monitoring" or memory pre-failure notification
and switch them off. The signature is a `cyclictest` histogram with a clean body and a handful of enormous
outliers.

---

## 7. Grant the IOC its privileges

Already carried by [`config/99-ecmc-realtime.conf`](config/99-ecmc-realtime.conf) →
`/etc/security/limits.d/`:

```
@ethercat  -  rtprio   90
@ethercat  -  memlock  unlimited
```

Not optional — and its absence is **quiet**. ecmc asks for EPICS priority 72 for its cyclic thread
(`ECMC_PRIO_HIGH`, thread `ecmc_rt`), and when that fails it falls back and keeps running:

```
ERROR: Can't create high priority thread, fallback to low priority
```

One line in a long IOC startup log, followed by an IOC that looks healthy and jitters. Check both ends:

```bash
grep -i 'fallback to low priority' <ioc log>
chrt -p "$(pgrep ecmc_rt)"          # expect SCHED_FIFO, not SCHED_OTHER
```

`memlock` matters for the same reason: ecmc calls `mlockall(MCL_CURRENT|MCL_FUTURE)` to stay out of swap
and **warns rather than fails** if it cannot. A page fault in the cyclic path is a missed cycle.

Never run the IOC as root to obtain these. Group membership is the supported route
(`INSTALL.md` §8 and §10).

---

## 8. Measure — a number, not a claim

```bash
sudo cyclictest -m -p 80 -t1 -n -a 2 -i 1000 -D 10m -h 400 -q
```

`-a 2` pins to isolated core 2, `-i 1000` samples at your 1 kHz cycle, `-D 10m` runs long enough to catch
something. Read the **Max**, never the Avg — RT is a statement about the worst case:

| Max latency | Verdict |
|---|---|
| < 50 µs | good; 1 kHz motion is comfortable |
| 50–150 µs | usable at 1 kHz; fix firmware and isolation before going faster |
| > 200 µs | something is wrong — revisit §5 and §6 before blaming the kernel |
| clean body, rare huge outlier | almost always SMI (§6) |

Run it **under realistic load** — `stress-ng`, or simply the IOC plus a live bus. An idle machine measures
nothing interesting.

Then check the real thing, because `cyclictest` measures the kernel, not your application:

```bash
/opt/etherlab/bin/ethercat master        # working counter / DC status
```

ecmc's own cycle-time statistics are the number that ultimately matters.

---

## 9. Revisit the native `e1000e` driver

RT shifts the trade-off that settled on `generic` (`INSTALL.md` §3).

`generic` sends through a raw packet socket, so every frame traverses the kernel network stack. Under
`PREEMPT_RT` that softirq work becomes thread-scheduled — **bounded, which is what matters** — but with more
scheduling hops than a native driver, which hands frames straight to the master and is polled from the
cyclic task with interrupts disabled.

The blocker is unchanged and has nothing to do with RT: the `*-5.14-ethercat.c` files are verbatim forks
carrying **zero** `LINUX_VERSION_CODE` guards, so there is nothing to patch (`BUILD.md` §5). One experiment
remains — of the shipped variants only the **6.12** fork uses all four ethtool APIs el9.8 expects:

```bash
./configure ... --enable-e1000e --with-e1000e-kernel=6.12
```

It is a coin flip: 6.12's driver may use other things el9.8 lacks. **Measure first.** If `cyclictest` and
ecmc's cycle statistics are inside budget on `generic`, this buys nothing worth the risk of an unvalidated
NIC driver running in ring 0.

---

## 10. Going back

Both kernels remain installed; you choose at boot.

```bash
sudo grubby --set-default=/boot/vmlinuz-<stock kernel>
sudo tuned-adm profile throughput-performance
sudo reboot
```

The stock kernel's EtherCAT modules are still in `/lib/modules/<stock>/ethercat/` — installing for the RT
kernel did not disturb them, so the bus returns without a rebuild. Preserve that symmetry: do **not**
`rm -rf` the other kernel's module directory to tidy up.

---

## 11. What to expect

An RT kernel is not free. Average throughput drops, measurably on IO-heavy work, because what used to be a
spinlock is now a mutex with priority inheritance. You trade average speed for a bound on the worst case.
For a motion controller that trade is the entire point; for a build host it would be a poor one.

Set expectations honestly on a training box: firmware settings and CPU isolation will move your numbers
more than the kernel choice alone, and a stock kernel with isolated cores can beat a badly-tuned RT kernel.
Do all three, then measure.

---

## Reference

| | |
|---|---|
| `PREEMPT_RT` upstream | <https://wiki.linuxfoundation.org/realtime/start> |
| `cyclictest` | <https://wiki.linuxfoundation.org/realtime/documentation/howto/tools/cyclictest/start> |
| RHEL 9 realtime tuning | Red Hat's guide documents the `tuned` `realtime` profile and `isolate_managed_irq` |
| [`INSTALL.md`](INSTALL.md) §12 | surviving a kernel update — now doubled |
| [`BUILD.md`](BUILD.md) §5 | why RHEL backports break the native drivers |
