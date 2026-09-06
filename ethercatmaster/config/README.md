# Site configuration for the EtherCAT master

## Why this directory exists

A reasonable question is why the master's configuration is not carried as a
patch against the `ethercat` checkout. The answer is that **none of it lives in
that tree**:

| What | Where it lives | Tracked here? |
|---|---|---|
| `./configure` arguments | command line; output is `Makefile`, `Kbuild`, `config.h`, `config.status` — all in the master's own `.gitignore` | no — see `../INSTALL.md` step 3 |
| Master settings | `/etc/ethercat.conf`, **installed** from `script/ethercat.conf` (`dist_sysconf_DATA`) | values in `site-ethercat.env` |
| systemd ordering | `/etc/systemd/system/ethercat.service.d/` | yes |
| Device permissions | `/etc/udev/rules.d/` | yes |
| Linker path | `/etc/ld.so.conf.d/` | yes |
| Realtime limits | `/etc/security/limits.d/` | yes |
| ecmc build path | `ecmc/configure/RELEASE.local` — matched by `*.local` in ecmc's `.gitignore`, i.e. the *designed* site-override hook | written by `../../00-bootstrap/bootstrap.sh` |

So the upstream checkout stays byte-identical to tag `1.6.12`, which is the
whole point of pinning a tag: you can verify provenance with `git status` and
re-clone at any time without replaying local edits.

## Files

| File | Installs to |
|---|---|
| `site-ethercat.env` | nothing — the values, read by `apply-config.sh` |
| `50-dependencies-generic.conf` | `/etc/systemd/system/ethercat.service.d/50-dependencies.conf` |
| `50-dependencies-native.conf` | the same path, when using a native driver |
| `99-EtherCAT.rules` | `/etc/udev/rules.d/99-EtherCAT.rules` |
| `ld-etherlab.conf` | `/etc/ld.so.conf.d/ethercat.conf` |
| `99-ecmc-realtime.conf` | `/etc/security/limits.d/99-ecmc-realtime.conf` |

## Use

```bash
./apply-config.sh --dry-run     # show every change, write nothing
sudo ./apply-config.sh          # apply
```

Run it **after** `make modules_install install` — `/etc/ethercat.conf` does not
exist before then. It is idempotent, backs up `/etc/ethercat.conf` once to
`.orig`, and re-running reports `unchanged`.

`/etc/ethercat.conf` is edited in place rather than overwritten, so a future
master version that adds new variables keeps them.

## Changing hosts

Edit `site-ethercat.env` — `MASTER0_DEVICE` (the MAC of the dedicated NIC) and
`UPDOWN_INTERFACES` are the two that always differ. Get the MAC with:

```bash
ip -br link            # pick the NIC with NO ip address
```
