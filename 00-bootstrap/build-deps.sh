#!/usr/bin/env bash
#
# build-deps.sh -- fetch and build the source dependencies listed in deps.conf.
#
# These are libraries the ecmc stack needs that Rocky 9 does not package, so
# they are built from source at a pinned version. EPICS base and the EPICS
# modules are NOT handled here; they have a different build system and are
# covered in MODULES.md.
#
# Usage:
#   ./build-deps.sh                 fetch and build everything in deps.conf
#   ./build-deps.sh ruckig          just this one
#   ./build-deps.sh --list          show what is configured and what is built
#   ./build-deps.sh --fetch-only    check out the pinned versions, do not build
#   ./build-deps.sh --rebuild       discard the build directory first
#   ./build-deps.sh --force         allow checkout over local modifications
#   ./build-deps.sh --dry-run       print what would happen
#
# Re-running is safe: an already-correct checkout is left alone.
# Local modifications are never discarded without --force.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
conf="$here/deps.conf"

DO_BUILD=1 REBUILD=0 FORCE=0 DRY=0 LIST=0
WANTED=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)       LIST=1 ;;
    --fetch-only) DO_BUILD=0 ;;
    --rebuild)    REBUILD=1 ;;
    --force)      FORCE=1 ;;
    --dry-run)    DRY=1 ;;
    -h|--help)    sed -n '2,22p' "$0"; exit 0 ;;
    -*)           echo "unknown option: $1" >&2; exit 2 ;;
    *)            WANTED+=("$1") ;;
  esac
  shift
done

[[ -f "$conf" ]] || { echo "ERROR: $conf not found" >&2; exit 1; }

if [[ -f "$repo/site.conf" ]]; then
  # shellcheck disable=SC1091
  source "$repo/site.conf"
fi

# Site convention: /cds/group/pcds/pkg_mgr/<package>. Override in site.conf.
DEPS_DIR="${DEPS_DIR:-/cds/group/pcds/pkg_mgr}"
if [[ -z "$DEPS_DIR" ]]; then
  echo "ERROR: DEPS_DIR is empty; set it in site.conf" >&2
  exit 1
fi

run() {
  if [[ $DRY -eq 1 ]]; then
    printf '    would run: %s\n' "$*"
  else
    "$@"
  fi
}

hdr()  { printf '\n== %s ==\n' "$1"; }
info() { printf '    %s\n' "$1"; }
die()  { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Read deps.conf into parallel arrays. Comments and blank lines are skipped;
# everything from the fifth field on is the options string.
# ---------------------------------------------------------------------------
names=() types=() versions=() sources=() options=()
while read -r name type version source rest; do
  [[ -z "${name:-}" || "$name" == \#* ]] && continue
  names+=("$name"); types+=("$type"); versions+=("$version")
  sources+=("$source"); options+=("${rest:-}")
done < <(sed 's/[[:space:]]*#.*$//' "$conf")

[[ ${#names[@]} -gt 0 ]] || die "no entries in $conf"

if [[ $LIST -eq 1 ]]; then
  hdr "configured dependencies"
  printf '  %-12s %-10s %-12s %s\n' NAME TYPE VERSION STATE
  for i in "${!names[@]}"; do
    d="$DEPS_DIR/${names[$i]}/${versions[$i]}"
    if [[ -d "$d/.git" ]]; then
      cur="$(git -C "$d" describe --tags --always 2>/dev/null || echo '?')"
      state="at $cur"
      [[ "$cur" == "${versions[$i]}" ]] || state="$state (wanted ${versions[$i]})"
    elif [[ -d "$d" ]]; then
      state="present, not a git checkout"
    else
      state="not fetched"
    fi
    printf '  %-12s %-10s %-12s %s\n' "${names[$i]}" "${types[$i]}" "${versions[$i]}" "$state"
  done
  echo
  exit 0
fi

# ---------------------------------------------------------------------------
fetch_git() {
  local name="$1" version="$2" source="$3" opts="$4" dir="$5"

  if [[ ! -d "$dir/.git" ]]; then
    info "cloning $source"
    run git clone --quiet "$source" "$dir" || die "clone failed: $name"
  fi
  [[ $DRY -eq 1 ]] && return 0

  # Never silently throw away someone's edits.
  if [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" && $FORCE -eq 0 ]]; then
    die "$name has local modifications. Commit them, or re-run with --force."
  fi

  local cur
  cur="$(git -C "$dir" describe --tags --exact-match 2>/dev/null || echo '')"
  if [[ "$cur" == "$version" ]]; then
    info "already at $version"
  else
    info "fetching and checking out $version"
    git -C "$dir" fetch --quiet --tags origin || die "fetch failed: $name"
    # NB: ${FORCE:+--force} would expand whenever FORCE is set at all, and it is
    # always set to 0 or 1. Test the value.
    local co=(checkout --quiet)
    [[ $FORCE -eq 1 ]] && co+=(--force)
    git -C "$dir" -c advice.detachedHead=false "${co[@]}" "$version" \
      || die "no such tag/branch/commit in $name: $version"
  fi

  if [[ "$opts" == *--submodules* ]]; then
    info "updating submodules"
    git -C "$dir" submodule update --init --recursive --quiet
  fi
}

fetch_tarball() {
  local name="$1" source="$2" dir="$3"
  if [[ -d "$dir" ]]; then
    info "already unpacked"
    return 0
  fi
  info "downloading $source"
  run mkdir -p "$dir"
  run bash -c "curl -fsSL '$source' | tar -xz -C '$dir' --strip-components=1"
}

# Strip the pseudo-flags so the rest can go to the configure step verbatim.
# Prints nothing at all when there is nothing left, so callers using mapfile do
# not end up with one empty argument (which cmake rejects).
configure_args() {
  local opts="$1" tok
  for tok in $opts; do
    [[ "$tok" == "--submodules" ]] && continue
    printf '%s\n' "$tok"
  done
}

build_cmake() {
  local dir="$1" opts="$2"
  local args=(); mapfile -t args < <(configure_args "$opts")
  local prefix=""
  for a in "${args[@]}"; do [[ "$a" == --prefix=* ]] && prefix="${a#--prefix=}"; done

  [[ $REBUILD -eq 1 ]] && run rm -rf "$dir/build"

  local cm=(cmake -B "$dir/build" -S "$dir" -DCMAKE_BUILD_TYPE=Release)
  [[ -n "$prefix" ]] && cm+=("-DCMAKE_INSTALL_PREFIX=$prefix")
  for a in "${args[@]}"; do [[ "$a" == --prefix=* ]] || cm+=("$a"); done

  run "${cm[@]}"                              || die "cmake configure failed"
  run cmake --build "$dir/build" -j"$(nproc)" || die "cmake build failed"
  [[ -n "$prefix" ]] && run cmake --install "$dir/build"
  return 0
}

build_autotools() {
  local dir="$1" opts="$2"
  local args=(); mapfile -t args < <(configure_args "$opts")

  if [[ ! -x "$dir/configure" ]]; then
    info "no configure script; running autoreconf"
    run bash -c "cd '$dir' && (./bootstrap 2>/dev/null || autoreconf -i)"
  fi
  run bash -c "cd '$dir' && ./configure ${args[*]}" || die "configure failed"
  run bash -c "cd '$dir' && make -j$(nproc)"        || die "make failed"
  for a in "${args[@]}"; do
    if [[ "$a" == --prefix=* ]]; then
      run bash -c "cd '$dir' && make install"
      break
    fi
  done
  return 0
}

build_make() {
  local dir="$1" opts="$2"
  local args=(); mapfile -t args < <(configure_args "$opts")
  run bash -c "cd '$dir' && make -j$(nproc) ${args[*]}" || die "make failed"
}

# ---------------------------------------------------------------------------
built=()
for i in "${!names[@]}"; do
  name="${names[$i]}" type="${types[$i]}"
  version="${versions[$i]}" source="${sources[$i]}" opts="${options[$i]}"

  if [[ ${#WANTED[@]} -gt 0 ]]; then
    skip=1
    for w in "${WANTED[@]}"; do [[ "$w" == "$name" ]] && skip=0; done
    [[ $skip -eq 1 ]] && continue
  fi

  hdr "$name $version ($type)"
  dir="$DEPS_DIR/$name/$version"

  case "$source" in
    *.tar.gz|*.tgz|*.tar.bz2) fetch_tarball "$name" "$source" "$dir" ;;
    *)                        fetch_git "$name" "$version" "$source" "$opts" "$dir" ;;
  esac

  if [[ $DO_BUILD -eq 0 || "$type" == "fetch" ]]; then
    info "not building (${type} / --fetch-only)"
    built+=("$name:$version")
    continue
  fi

  case "$type" in
    cmake)     build_cmake     "$dir" "$opts" ;;
    autotools) build_autotools "$dir" "$opts" ;;
    make)      build_make      "$dir" "$opts" ;;
    *)         die "unknown type '$type' for $name" ;;
  esac

  info "built in $dir"
  built+=("$name:$version")
done

[[ ${#built[@]} -gt 0 ]] || die "nothing matched: ${WANTED[*]:-<all>}"

# ---------------------------------------------------------------------------
# Record exactly what was built. deps.conf says what you asked for; this says
# what you got, which is what you need when a build works on one host and not
# another.
# ---------------------------------------------------------------------------
if [[ $DRY -eq 0 ]]; then
  lock="$here/deps.lock"
  {
    echo "# generated by build-deps.sh on $(date -Iseconds)"
    echo "# DEPS_DIR = $DEPS_DIR"
    echo "# name        version       commit    path"
    for entry in "${built[@]}"; do
      n="${entry%%:*}"; v="${entry#*:}"
      d="$DEPS_DIR/$n/$v"
      sha="$(git -C "$d" rev-parse --short HEAD 2>/dev/null || echo 'n/a')"
      ver="$(git -C "$d" describe --tags --always 2>/dev/null || echo "$v")"
      printf '%-13s %-13s %-9s %s\n' "$n" "$ver" "$sha" "$d"
    done
  } > "$lock"
  hdr "done"
  info "recorded in $lock"
  info "DEPS_DIR = $DEPS_DIR"
  echo
fi
