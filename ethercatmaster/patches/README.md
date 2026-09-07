# Compatibility patches for the EtherCAT master

Patches applied to the upstream IgH checkout at tag `1.6.12` to make it build on
this site's kernel. Applied in `INSTALL.md` step 2, after checking out the tag
and before `./bootstrap`.

## Policy

Two kinds of local change get confused with each other. They are handled
differently on purpose:

| | Where it goes | Why |
|---|---|---|
| **Site configuration** — which NIC, which driver, permissions, limits | [`../config/`](../config/), installed into `/etc` | None of it lives in the source tree. `./configure` output is gitignored build product, and `ethercat.conf` is *installed* to `/etc` from the master's template. There is nothing to patch. |
| **Source compatibility** — the code does not build against this kernel | here, as real patches | Sometimes unavoidable. Better a reviewed patch with a written rationale than an undocumented local edit. |

The goal is that `git status` inside the checkout is either empty or shows
exactly the files these patches touch — nothing else, ever. If it shows
something not accounted for here, someone edited the tree by hand.

## Patches

| File | Fixes |
|---|---|
| `0001-cdev-vm_flags-const-on-rhel9.patch` | `master/cdev.c:233: error: assignment of read-only member 'vm_flags'` on Rocky/RHEL 9.4+ |

Each file's header carries the full diagnosis: the error, the mainline commit
responsible, why the upstream version guard misses it, and how the fix mirrors
an idiom upstream already uses elsewhere.

## Applying

```bash
for p in patches/*.patch; do
  git apply --check "$p" && git apply "$p" && echo "applied $(basename "$p")"
done
```

`--check` first means a patch that no longer applies stops rather than
half-applying.

## Reverting

```bash
git apply -R patches/0001-cdev-vm_flags-const-on-rhel9.patch
# or, to discard every local change:
git checkout -- .
```

## When upstream fixes one

Check before every version bump:

```bash
git -C <ethercat> log --oneline 1.6.12..origin/stable-1.6 -- master/cdev.c
```

If upstream has fixed it, delete the patch here rather than carrying a
conflicting local change forward. As of `650888c5` (stable-1.6, seven commits
past 1.6.12) `cdev.c` is untouched, and upstream has no RHEL guards anywhere in
the tree — so this is unlikely to be fixed for us soon.
