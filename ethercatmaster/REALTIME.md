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
2. **Capture the stock baseline while the bus is known-good** — see below. Skipping this means "is the bus
   unchanged?" becomes a memory test after the kernel swap.
3. **Install `kernel-rt`, reboot** — §3.
4. **Rebuild the EtherCAT master against it** — §4. Non-negotiable; the existing modules will not load.
5. **Measure untuned** — §8. This is the control.
6. **Then tune** — §5, §6, §7 — and measure again.

Measuring before tuning costs one extra reboot and buys attributability: a bad number after tuning is
otherwise indistinguishable between the kernel, the isolation and the firmware.

Debugging a bus problem and a latency problem simultaneously is how a two-hour job becomes a two-day one.

### Capture the baseline first

One file per command. A single concatenated file cannot be diffed reliably: `ethercat slaves -v` and
`ethercat pdos` both emit `=== Master 0, Slave N ===` headers, so any `sed` range over the combined
output splits in the wrong place.

```bash
mkdir -p ~/bus-stock
ethercat master    > ~/bus-stock/master.txt
ethercat slaves    > ~/bus-stock/slaves.txt
ethercat slaves -v > ~/bus-stock/slaves-v.txt
ethercat pdos      > ~/bus-stock/pdos.txt
uname -r           > ~/bus-stock/kernel.txt
wc -l ~/bus-stock/*        # every file non-empty, or the capture is not a baseline
```

That `wc -l` is the point of the exercise: an empty `slaves-v.txt` looks like a passing diff later, which
is the worst possible failure mode for a baseline.

§5 diffs against these. Slave identity and error counts must not change across the kernel swap; frame
counters and DC timestamps of course will.

---

## 3. Install the RT kernel

Rocky ships the realtime kernel in a separate repository, enabled by a release package:

```bash
sudo dnf install -y rocky-release-rt
sudo dnf install -y kernel-rt kernel-rt-devel tuned-profiles-realtime
sudo dnf install -y realtime-tests              # cyclictest -- NOT called rt-tests here, see below
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

> **The package is not called `rt-tests` on Rocky.** It carries `cyclictest`, which §8 needs, and the
> RHEL name finds nothing:
>
> ```
> $ sudo dnf install -y --enablerepo=rt rt-tests
> Error: Unable to find a match: rt-tests
> ```
>
> Ask for the *file* rather than guessing at package names:
>
> ```bash
> $ dnf provides '*/cyclictest'
> realtime-tests-2.9-1.el9.x86_64 : Programs that test various rt-features
> Repo        : appstream
> Filename    : /usr/bin/cyclictest
> ```
>
> So on Rocky 9 it is **`realtime-tests`**, in `appstream` — already enabled, no extra repo needed:
>
> ```bash
> sudo dnf install -y realtime-tests
> ```
>
> None of this blocks §3 or §4 in any case. `cyclictest` is a measurement tool, not a build dependency.

`kernel-rt-devel` is the RT equivalent of the `kernel-devel` from `INSTALL.md` step 1, and §4 cannot
proceed without it.

> **`kernel-rt-devel` is a separate package, and it is easy to end up with the wrong one.** Two failure
> modes, both of which cost a full build before they show up:
>
> ```bash
> sudo dnf install -y "kernel-rt-devel-$(rpm -q --qf '%{VERSION}-%{RELEASE}' kernel-rt)"
> rpm -q kernel-rt-devel
> ls -d /usr/src/kernels/*+rt
> ```
>
> - **Version skew.** A bare `dnf install kernel-rt-devel` can pull a newer build than the `kernel-rt` you
>   have. Pin it to the installed kernel's version, as above.
> - **Variant skew — the subtle one.** `kernel-devel` for the *same version* installs
>   `/usr/src/kernels/5.14.0-687.44.1.el9_8.x86_64`, with **no `+rt`**. It sits right next to the tree you
>   want, matches the version you are looking for, and builds cleanly — producing modules whose `vermagic`
>   lacks `preempt_rt`, rejected at `insmod`. Always confirm the path you pass to `--with-linux-dir` ends
>   in `+rt`; `"$(uname -r)"` gets this right on its own, which is why §4 uses it rather than a literal.

Find the RT entry and make it the default:

```bash
sudo grubby --info=ALL | grep -E '^(index|kernel)='
sudo grubby --default-kernel        # often already the RT one after installing kernel-rt
```

On this host that prints:

```
index=0  kernel="/boot/vmlinuz-5.14.0-687.44.1.el9_8.x86_64+rt"     <- RT
index=1  kernel="/boot/vmlinuz-5.14.0-687.10.1.el9_8.0.1.x86_64"    <- stock
```

Two things to read out of that, neither cosmetic:

- **RT is a `+rt` suffix on the same NVR**, not the older `5.14.0-284.rt14.310.el9_2` form. So
  `uname -r` will end in `+rt`, and the build tree is
  `/usr/src/kernels/5.14.0-687.44.1.el9_8.x86_64+rt`. Anything that greps for `rt` in the middle of the
  version string will miss it.
- **It is a newer point build** — `687.44.1` against the running `687.10.1`, not merely an RT variant of
  the same kernel. A different el9.8 build can carry different backports, so a clean compile on the stock
  kernel does **not** guarantee one here. Expect the possibility of a third guard failure, and treat §4 as
  a real build rather than a formality.

```bash
sudo grubby --set-default=/boot/vmlinuz-5.14.0-687.44.1.el9_8.x86_64+rt   # if not already default
sudo reboot
```

Confirm afterwards:

```bash
uname -r                          # 5.14.0-687.44.1.el9_8.x86_64+rt
uname -v | grep -o PREEMPT_RT     # must print PREEMPT_RT
cat /sys/kernel/realtime          # must print 1
ls -d /usr/src/kernels/"$(uname -r)"    # kernel-rt-devel must match, or §4 dies at ./configure
```

`/sys/kernel/realtime` is what [`preflight.sh`](../00-bootstrap/preflight.sh) tests.

---

## 4. Rebuild the EtherCAT master — required

`kernel-rt` is a different kernel, so the modules built in `INSTALL.md` step 4 carry the wrong `vermagic`
and are refused:

```
insmod: ERROR: could not insert module ec_master.ko: Invalid module format
dmesg:  ec_master: version magic '5.14.0-687.10.1.el9_8.0.1.x86_64 SMP mod_unload modversions '
        should be  '5.14.0-687.44.1.el9_8.x86_64+rt SMP preempt_rt mod_unload modversions '
```

Note both halves differ here — the point build *and* the `preempt_rt` flag. Either alone is enough to be
rejected.

**Both compatibility patches are still required.** This is the same 5.14 el9.8 base carrying the same Red
Hat backports, and their thresholds (RHEL 9.4 and 9.6) are below 9.8, so `master/cdev.c` and
`master/module.c` fail identically without them.

Run [`pre-build.sh`](pre-build.sh) first. It reads the *new* kernel's headers to see which patches this
kernel needs, reads the checkout to see which are actually applied, and with `--apply` closes the gap in
one step:

```bash
<training>/ethercatmaster/pre-build.sh --apply
```

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

# make install just overwrote /etc/ethercat.conf with the upstream template.
# Put the site settings back before starting the master.
( cd <training>/ethercatmaster/config && sudo ./apply-config.sh )

sudo systemctl restart ethercat
```

`--with-linux-dir` resolves to the **RT** tree only because `uname -r` changed. That is the whole trick,
and the whole trap: run it from a shell you opened before the reboot and it silently rebuilds against the
old kernel, producing modules that fail exactly as above.

Verify, then prove the bus is unchanged rather than merely alive:

```bash
modinfo /lib/modules/"$(uname -r)"/ethercat/master/ec_master.ko | grep vermagic
lsmod | grep '^ec_'

mkdir -p ~/bus-rt
ethercat master    > ~/bus-rt/master.txt
ethercat slaves    > ~/bus-rt/slaves.txt
ethercat slaves -v > ~/bus-rt/slaves-v.txt
ethercat pdos      > ~/bus-rt/pdos.txt

diff ~/bus-stock/slaves.txt   ~/bus-rt/slaves.txt      # must be empty
diff ~/bus-stock/slaves-v.txt ~/bus-rt/slaves-v.txt    # only RxTime / DC times
diff ~/bus-stock/pdos.txt     ~/bus-rt/pdos.txt        # must be empty
```

`vermagic` must contain both the new version **and** `preempt_rt`:

```
vermagic: 5.14.0-687.44.1.el9_8.x86_64+rt SMP preempt_rt mod_unload modversions
```

The gate is: the same slaves at the same positions, all `PREOP` with `Flag: +`, `Link: UP`,
`Lost frames: 0`, `Phase: Idle`. Port `RxTime` and DC transmission delays will differ and should — slave
identity, product codes, revisions and error counts must not.

A difference in *slave count* after nothing but a kernel change means the new driver build is dropping
frames during scan, not that your hardware moved.

> **Empty PDO names are cosmetic.** If `pdos.txt` differs only in the quoted strings —
> `RxPDO 0x1600 ""` where the stock capture had `RxPDO 0x1600 "DRV RxPDO-Map Controlword Ch.1"` — with
> every index, sub-index and bit width matching, that is the SII string table not having been re-read,
> not a bus problem. ecmc addresses PDOs numerically, so nothing downstream depends on those strings. A
> `sudo ethercat rescan` usually restores them.

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
every tool that merely counts logical CPUs. Check before assuming you have it:
`lscpu | grep 'Thread(s) per core'` — a value of 1 means there is nothing to disable. (This host: an
i5-6500, 4 cores, 1 thread each.)

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

Take **two** measurements: untuned first, tuned second. The untuned one is the control. Without it, a
disappointing final number cannot be attributed between the kernel, the CPU isolation and the firmware,
and you end up changing three things and guessing.

### First: untuned, straight after §4

Nothing is isolated yet, so do not pin:

```bash
sudo cyclictest -m -p 80 -t1 -i 1000 -D 10m -h 400 -q | tee ~/cyclictest-rt-untuned.txt
```

### Then: tuned, after §5 and §6

```bash
sudo cyclictest -m -p 80 -t1 -a 2 -i 1000 -D 10m -h 400 -q | tee ~/cyclictest-rt-tuned.txt
```

> **`-n` does not exist in this build, and `-N` is not a substitute.** Many guides pass a lowercase `-n`;
> `realtime-tests 2.9` rejects it:
>
> ```
> cyclictest: invalid option -- 'n'
> ```
>
> Drop it. Do **not** reach for `-N` instead — that switches the output units to nanoseconds
> (`-N, --nsecs: print results in ns instead of us`), which changes how you read every number in the
> table below. Harmless if deliberate, confusing if it was a typo for `-n`.
>
> `cyclictest --help` is authoritative for your build; the option set has drifted and most material online
> predates the current one.

`-a 2` pins to isolated core 2, `-i 1000` samples at your 1 kHz cycle, `-D 10m` runs long enough to catch
something. Read the **Max**, never the Avg — RT is a statement about the worst case:

| Max latency | Verdict |
|---|---|
| < 50 µs | good; 1 kHz motion is comfortable |
| 50–150 µs | usable at 1 kHz; fix firmware and isolation before going faster |
| > 200 µs | almost certainly un-isolated cores — do §5 before anything else |
| clean body, rare huge outlier | not the kernel — measure `MSR_SMI_COUNT` before assuming SMI |

Run both **under realistic load** — `stress-ng`, or simply the IOC plus a live bus. An idle machine
measures nothing interesting, and an idle measurement is the one that flatters you.


### Read the histogram, not just the Max

`Max` alone cannot tell you what to fix. The **shape** can. From this host, untuned, 600,000 cycles:

```
000002 596189      <- 99.36% of all samples
000003 003175
000004 000361
000005 000106
...
000033 000001
000044 000001
                   <- ~24 further samples, scattered out to 298 us
```

Three regions, three different causes:

| Region | This host | Cause | Fix |
|---|---|---|---|
| **Body** — one dominant bucket | 2 µs, 99.36% | none; this is the kernel working | — |
| **Shoulder** — smooth decay | 3–44 µs, 0.6% | scheduler tick, load balancing, IRQs, RCU callbacks | CPU isolation, §5 |
| **Far outliers** — sparse, orders of magnitude out | ~25 samples to 298 µs | SMI, P-state transitions, or kernel housekeeping — **measure, do not guess** | §6, or isolation |


Two properties of the far tail carry more information than its magnitude:

- **Rate.** Divide the outlier count by the run duration. On this host, 25 samples over 600 s is one every
  ~24 seconds. Scheduling interference tracks load; it does not arrive on a fixed interval. A periodic
  outlier is something polling — firmware, or a timer.
- **Clustering.** Random interference scatters. A *recurring* event lands repeatedly at nearly the same
  duration. This host showed `237, 238, 239` and `248, 249, 250` — three consecutive microsecond buckets,
  once each, twice over. That is one event type recurring, not twenty unrelated ones.

A big `Max` with a clean body and a handful of far outliers is **not** a kernel problem, and tuning the
kernel harder will not move it. Conversely a fat shoulder with no far outliers is pure scheduling, and
firmware settings will do nothing for it. Knowing which you have decides where the next hour goes.

Print the tail rather than truncating it — `head -25` hides exactly the samples that matter:

```bash
sed -n '/^# Histogram$/,/^# Min Latencies/p' ~/cyclictest-rt-untuned.txt \
  | awk '$1+0 >= 40 && $2+0 > 0 {print}'
```

To confirm SMI directly, read the firmware's own counter before and after a run:

```bash
sudo dnf install -y msr-tools
sudo rdmsr -a 0x34; sleep 60; sudo rdmsr -a 0x34    # MSR_SMI_COUNT, per CPU
```

**Read it as a test, not a formality.** On this host both reads returned `0x1e3f` on all four cores —
7743 SMIs accumulated during firmware init at boot, and **none since**. That eliminated firmware as the
cause of a tail whose shape had pointed straight at it, and redirected the work to the next candidate
rather than into the BIOS.

A count that climbs on an idle machine means firmware is preempting the kernel and no kernel setting will
change it; §6 is the only lever. A count that does not move means look elsewhere:

| Next candidate | Test | Reboot? |
|---|---|---|
| P-state / turbo transitions | check `intel_pstate/*` first, then `no_turbo=1` — see below | no |
| Kernel housekeeping — RCU, workqueues, thermal polling, watchdog | isolate cores (§5), re-measure | yes |
| The EtherCAT master's own idle-phase bus scanning | `systemctl stop ethercat`, re-measure | no |

Each is cheap, and each isolates one variable. Run them in that order — cheapest and most reversible
first — and stop when the tail moves.

#### "Performance governor" does not mean fixed frequency

Setting the governor is the usual advice and it is not sufficient. Check what is actually in force:

```bash
grep . /sys/devices/system/cpu/intel_pstate/*
dmesg | grep -i 'intel_pstate\|HWP'
```

On this host the governor was **already** `performance` before anything was changed, so that experiment
was a no-op — and the state underneath was:

```
min_perf_pct: 100     floor pinned to maximum
max_perf_pct: 100     ceiling too -- ordinary P-state scaling is already out
no_turbo:     0       turbo still ENABLED
HWP enabled           the hardware, not the kernel, decides when to use it
```

So sustained frequency was pinned while **turbo transitions continued**, managed autonomously by Speed
Shift below the kernel's visibility. Each transition stalls the core, and turbo residency tracks thermal
headroom — which varies on a timescale of tens of seconds, not milliseconds.

Turbo can be disabled at runtime, which makes it a five-minute experiment rather than a BIOS trip:

```bash
echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo
# ... measure ...
echo 0 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo
```

`intel_pstate=disable` on the kernel command line takes the driver out entirely, and `tuned`'s `realtime`
profile sets it — so if you are going to isolate cores anyway (§5), that arrives at the same time.



#### A worked elimination

Each of these took one five-minute run and no reboot. The control throughout was **9–16 outliers ≥40 µs
per 300 s, with nothing between 20 and 69 µs** — a stable, bimodal distribution.

| Candidate | Test | Result |
|---|---|---|
| SMI | `rdmsr -a 0x34` before/after | **Cleared.** `0x1e3f` unchanged — all 7743 SMIs were at boot |
| P-state scaling | `grep . intel_pstate/*` | **Cleared.** `min_perf_pct=max_perf_pct=100`, already pinned |
| Turbo | `no_turbo=1`, re-measure | **Cleared.** 11 outliers vs 9 — unchanged |
| Scheduled jobs | `systemctl list-timers --all` | **Cleared.** Nothing faster than hourly |
| The EtherCAT master | `systemctl stop ethercat`, re-measure | **Cleared** for the outliers; see below |
| Transparent huge pages | `cat .../transparent_hugepage/enabled` | **Cleared.** Not built into `kernel-rt` at all |

Stopping the master produced the one genuinely useful side result. The far outliers did not move — 16
against 9 and 11 — but the **shoulder halved**, from 2,453–3,433 samples above 2 µs down to 1,311. That is
the master's idle-phase frame processing, ~880 frames/s routed through the kernel network stack by the
`generic` driver. It is a direct measurement of the `generic`-versus-native trade-off in §9, and it belongs
in the PLC comparison: a hardware PLC does not pay it.

It also confirmed the two populations are independent. Stopping the master moved one and left the other
untouched.

What remains after all that is kernel housekeeping — RCU callbacks, workqueues, kworkers, the scheduler
tick, IRQ steering. Testing those individually would take an afternoon; isolation removes them as a class,
and you need it anyway. So stop testing one at a time and go to §5.

If outliers survive on an isolated `nohz_full` core, the remaining suspects are platform-level. ACPI
thermal zone polling is worth checking — it runs on intervals in this range and executes AML in kernel
context:

```bash
grep . /sys/class/thermal/thermal_zone*/polling_delay
grep . /sys/class/thermal/thermal_zone*/type
```


#### The result on this host

Isolation alone, no firmware changes:

| | Untuned | Isolated | Isolated + load |
|---|---|---|---|
| Max | 298–344 µs | **5 µs** | **9 µs** |
| Outliers ≥ 40 µs | 9–16 per 300 s | **0** | **0** |
| Samples > 2 µs | 1,311–3,433 | 783 | 11,720 |
| Body at 2 µs | 99.2–99.6% | 99.74% | 96.09% |

A 60× reduction in worst case, and the entire far population gone. On a 2015 i5-6500, with no BIOS
changes at all. Under a four-way CPU load it holds at 9 µs -- and note what that load actually did:
`isolcpus` keeps unpinned tasks off cores 2-3, so all four `stress-ng` workers piled onto cores 0-1. Two
cores carrying a four-way load while the isolated core stayed under 10 µs.

Measured **with the bus running** — `systemctl is-active ethercat` returning `active` with all 3 slaves
enumerated, not on an idle machine. Note the shoulder: 783 samples above 2 µs *with* the master running,
against 1,311 with the master stopped and no isolation. `isolate_managed_irq=Y` steered the NIC interrupt
away from cores 2-3, so the master's ~880 frames/s no longer reach the measured core at all.

**The elimination sequence above pointed at firmware, and firmware was not the answer.** Periodicity and
clustering are real signals, and here they were misleading: kernel housekeeping on a shared core produces
a periodic, clustered tail that looks exactly like SMI. The six negative results were not wasted — they
are what make this one attributable — but the inference drawn from them was wrong. Isolate first; it is
cheap, it is needed anyway, and it removes an entire class of cause in one step.

Note `nohz_full` was **not** set by this profile — `cat /sys/devices/system/cpu/nohz_full` returned
`(null)` — so the scheduler tick still fires on the isolated cores. 5 µs was reached without it. At a 1 kHz
cycle that is 0.5% of the budget, so there is little reason to chase the remainder.

### Recording the comparison

Where the point of the exercise is to compare a Linux + ecmc motion application against a hardware PLC,
record the method alongside the number or the comparison is not defensible. Filled in for this host:

| | value |
|---|---|
| Hardware | Intel i5-6500, 4 cores, no SMT, 2015 |
| Kernel | `5.14.0-687.44.1.el9_8.x86_64+rt`, Rocky 9.8 |
| Tuning | `tuned` `realtime`, `isolated_cores=2-3`, `isolate_managed_irq=Y`. **No BIOS changes.** |
| Isolated cores | 2-3 (`nohz_full` not set; tick still fires there) |
| EtherCAT | IgH 1.6.12, `generic` driver, 3 slaves, ~880 frames/s, 0 lost |
| Load during the run | `stress-ng --cpu 4` — all 4 workers on cores 0-1, since `isolcpus` keeps them off 2-3 |
| `cyclictest` idle | Max **5 µs**, Avg 2 µs, 300k cycles |
| `cyclictest` under load | Max **9 µs**, Avg 2 µs, 300k cycles |
| Untuned, for reference | Max 298–344 µs |
| ecmc cycle overruns | *(next milestone — `cyclictest` measures the scheduler, not the application)* |
| PLC figure being compared against, and how *it* was measured | *(fill in — see below)* |

That last row is the one that decides whether the comparison means anything. A PLC vendor's quoted jitter
is usually measured on dedicated hardware with a specific task class, often excluding the application
layer entirely. Compare like for like, or the number proves nothing in either direction.

Two honest caveats on the figures above, which belong next to them whenever they are quoted:

- **`cyclictest` measures the scheduler waking a thread, not a motion application doing work.** ecmc's own
  cycle-time statistics include the master, the driver and the PLC logic. Expect them to be worse, and
  treat them as the real number.
- **`generic` driver, not native.** Stopping the master halved the sub-20 µs shoulder, which is the cost of
  routing frames through the kernel network stack (§9). A PLC does not pay it.

`cyclictest` measures the kernel's ability to wake a thread on time. It is necessary, not sufficient:

```bash
/opt/etherlab/bin/ethercat master        # working counter / DC status
```

ecmc's own cycle-time statistics are what ultimately matter, since they include the master, the driver and
your PLC logic — not just the scheduler.

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
