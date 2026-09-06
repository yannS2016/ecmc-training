#!/usr/bin/env bash
#
# survey-crate.sh -- dump everything the EtherCAT master knows about the bus.
#
# Run this once, before writing any ecmc configuration.  It produces the raw
# material you will turn into crate.md, and a record of what the bus looked like
# on the day you configured it -- useful later when a terminal is swapped and
# the IOC stops starting.
#
# Read-only.  Talks to the master, never changes slave state.
#
#   ./survey-crate.sh [output-dir]        default: ./survey-<date>

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"

if [[ -f "$repo/site.conf" ]]; then
  # shellcheck disable=SC1091
  source "$repo/site.conf"
fi
el="${ETHERLAB:-/opt/etherlab}"

ec="$el/bin/ethercat"
[[ -x "$ec" ]] || ec="$(command -v ethercat 2>/dev/null || true)"
if [[ -z "$ec" || ! -x "$ec" ]]; then
  echo "ERROR: 'ethercat' CLI not found." >&2
  echo "       Install the master first: $repo/ethercatmaster/INSTALL.md" >&2
  exit 1
fi

if ! "$ec" master >/dev/null 2>&1; then
  echo "ERROR: the EtherCAT master is not responding." >&2
  echo "       systemctl status ethercat ; lsmod | grep ec_" >&2
  exit 1
fi

out="${1:-$here/survey-$(date +%Y%m%d)}"
mkdir -p "$out"
echo "==> writing survey to $out"

# --- master and bus overview ------------------------------------------------
"$ec" master               > "$out/master.txt"      2>&1
"$ec" slaves               > "$out/slaves.txt"      2>&1
"$ec" slaves -v            > "$out/slaves-v.txt"    2>&1
"$ec" domains              > "$out/domains.txt"     2>&1
"$ec" config               > "$out/config.txt"      2>&1

n_slaves="$(grep -c . "$out/slaves.txt" 2>/dev/null || echo 0)"
echo "    $n_slaves slave(s) on the bus"

if [[ "$n_slaves" -eq 0 ]]; then
  echo
  echo "WARNING: no slaves found. Check cabling, terminal power (E-bus), and that"
  echo "         the EtherCAT NIC is the one the master was configured for."
  exit 0
fi

# --- per-slave detail -------------------------------------------------------
# PDOs define the cyclic process image (what ecmc reads/writes every cycle).
# SDOs are the acyclic object dictionary (how you *configure* a terminal).
# You need both: ecmc maps PDO entries, and configures behaviour over SDO.
mkdir -p "$out/slaves"
for i in $(seq 0 $((n_slaves - 1))); do
  name="$(awk -v n="$i" '$1 == n { $1=""; $2=""; $3=""; $4=""; sub(/^ +/,""); print; exit }' \
          "$out/slaves.txt" 2>/dev/null)"
  printf '    slave %-3s %s\n' "$i" "${name:-<unknown>}"

  "$ec" pdos   -p "$i" > "$out/slaves/$i.pdos.txt"   2>&1
  "$ec" sdos   -p "$i" > "$out/slaves/$i.sdos.txt"   2>&1
  "$ec" slaves -p "$i" -v > "$out/slaves/$i.info.txt" 2>&1
done

# --- identity table ---------------------------------------------------------
# Vendor ID and Product code are what ecmc's Cfg.EcSlaveVerify() checks against
# the hardware script.  A mismatch here is the single most common reason an ecmc
# IOC refuses to start.
{
  echo "# Slave identity -- generated $(date -Iseconds)"
  echo
  printf '%-4s %-22s %-12s %-12s %-12s\n' pos name vendor product revision
  for i in $(seq 0 $((n_slaves - 1))); do
    f="$out/slaves/$i.info.txt"
    ven="$(awk -F'0x' '/Vendor Id:/  {print "0x"$2; exit}' "$f" | tr -d ' ')"
    pro="$(awk -F'0x' '/Product code:/{print "0x"$2; exit}' "$f" | tr -d ' ')"
    rev="$(awk -F'0x' '/Revision number:/{print "0x"$2; exit}' "$f" | tr -d ' ')"
    nam="$(awk -F'  +' '/^Name:/ {print $2; exit}' "$f")"
    printf '%-4s %-22s %-12s %-12s %-12s\n' \
           "$i" "${nam:-?}" "${ven:-?}" "${pro:-?}" "${rev:-?}"
  done
} > "$out/identity.txt"

echo
echo "==> survey complete"
echo
sed -n '3,50p' "$out/identity.txt"
echo
echo "    Next: turn this into crate.md -- see 01-discovery/README.md section 4."
