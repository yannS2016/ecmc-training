# Version baseline

## Short version

Pin both repositories to their **matched `11.0.8` tags**. Do not track `master`.

| Component | Tag | Commit | Date |
|---|---|---|---|
| `ecmc` | `v11.0.8` | `594ccb502caf1e0047e8c06d273e012a5e0d8457` | 2026-06-16 |
| `ecmccfg` | `11.0.8` | `ca9ea844594a8d9a3a279f87a493f96ae9ab9f8e` | 2026-06-16 |

Both were released the same day. `ecmc` `RELEASE.md` documents 11.0.8, and
`ecmccfg` `11.0.8` is the configuration framework built against it. This is a
coordinated pair, and it is the version this course is written for.

## Watch the tag naming

The two projects disagree on prefixes, which makes the tags easy to miss:

- `ecmc` uses a `v` prefix throughout: `v9.6.8`, `v10.0.10`, **`v11.0.8`**
- `ecmccfg` used `v` only up to 8.x, then dropped it: `v8.0.1`, `10.0.13`, **`11.0.8`**

Also note that `git ls-remote --tags` returns refs in **lexicographic** order, so
`v10.*` and `v11.*` sort *before* `v9.*`. Listing tags with `tail` will show you
the 9.x series and hide the current ones. Always sort explicitly:

```bash
git ls-remote --tags <url> | grep -v '\^{}' | sed 's|.*refs/tags/||' | sort -V | tail
```

Both tags are **annotated**, so the ref points at a tag object, not a commit.
`git ls-remote` shows the tag object SHA; append `^{}` to dereference to the
commit (that is where `594ccb5` / `ca9ea84` above come from).

## Why tags and not master

`master` moves. As of writing, `ecmccfg` master is `b30e460` (2026-08-10) — about
two months of commits past the `11.0.8` tag, with no tag of its own and no
guarantee it pairs with any released `ecmc`.

Pinning to tags gives the course three things master cannot:

1. **A reproducible baseline.** A trainee hitting an error is running the same
   code the exercise was written against.
2. **A matched pair.** `ecmc` and `ecmccfg` are separate repositories with a tight
   runtime contract; the tags are where the maintainers assert they fit together.
3. **A meaningful version to report.** `git describe` returns `v11.0.8` rather
   than a bare SHA.

Track master only when you need a fix that has not been tagged yet — and record
the SHA here when you do.

## Checking out the baseline

Both local checkouts point at personal forks (`yannS2016/...`), so `origin` is
not upstream. Add upstream explicitly, then check out the tag.

### ecmc — already on the tag

Local `HEAD` is `594ccb5`, which *is* `v11.0.8`. Nothing to do. To confirm:

```bash
cd $ECMC_SRC
git remote add upstream https://github.com/epics-modules/ecmc.git
git fetch upstream --tags
git describe --tags        # expect: v11.0.8
```

### ecmccfg — already on the tag

Local `HEAD` is `ca9ea844`, a detached checkout of `11.0.8`. Nothing to do. To
confirm:

```bash
cd $ECMCCFG_SRC
git remote add upstream https://github.com/paulscherrerinstitute/ecmccfg.git
git fetch upstream --tags
git describe --tags        # expect: 11.0.8
```

> **Do not read the version out of `Changelog.adoc`.** Its top entry still says
> `= v8.0.0` at tag `11.0.8` — upstream stopped maintaining it. `git describe
> --tags` is the only reliable answer, and it is what `preflight.sh` uses.

Prefer a detached checkout of the tag over merging upstream into the fork's
`master`. It is unambiguous, and it avoids dragging two years of history through
a merge for no benefit.

**One local commit to be aware of.** The fork carries `c623df80`, renaming
`examples/test/PSI/MCAG001/aux.db` to `extra.db` because `aux` is a reserved
device name on Windows and blocked cloning on NTFS. That directory no longer
exists upstream, so the change is obsolete — checking out `11.0.8` drops it
correctly.

The build and install host is Rocky 9, where reserved names are a non-issue. The
constraint only ever applied to a Windows browsing clone.

## After checking out

1. Re-run `00-bootstrap/stage-ecmccfg.sh`. It asserts there are no basename
   collisions when flattening — a real risk after two years of upstream change,
   and the reason that assertion exists.
2. Re-run `00-bootstrap/preflight.sh`. It prints each checkout's commit and warns
   if `ecmccfg` predates ecmc 11.x (it probes for `loadYamlAxis.cmd`,
   `loadCppLogic.cmd`, `loadYamlPlc.cmd`).
3. Smoke-test the upstream examples the course teaches from before teaching them.

For reference, the 2024-era `ecmccfg` this course was first drafted against staged
to **810 scripts, 329 templates** with no collisions. Expect different numbers at
`11.0.8`; changed counts are fine, a collision failure is not.

## Known incompatibility: ecmc 11.0.x vs upstream motor

ecmc 11.0.x references `motorLowLimitRO_` / `motorHighLimitRO_`, members of
`asynMotorController` that exist only in an ESS/PSI motor fork. They are **not**
in any released `epics-modules/motor`, including `R7-4` and `master`, so ecmc
does not compile against upstream motor as released.

Neither direction of version change helps:

| | |
|---|---|
| Newer motor | no upstream release has the symbols |
| Older/newer ecmc | present in every tag `v11.0.0` … `v11.0.8`, and on `v11.0.9_RC1` |
| ecmc 10.x | would avoid it, but loses `cpp_logic`, which phase 04 needs |

`00-bootstrap/make-demo-branch.sh` rewrites `$ECMC_SRC` onto a `demo` branch
from the pristine `v11.0.8` tag and adds the `#ifdef motorHighLimitROString`
guard that ecmc's own `ecmcMotorRecordController.cpp` documents in a
commented-out block, alongside the PCDS arch/path fixes. See the script's
header comment for the full list of edits and the behavioural consequence.

**When bumping ecmc**, re-check whether the guard is still needed — upstream
may have fixed it — and update `make-demo-branch.sh`'s anchors for the new tag.
