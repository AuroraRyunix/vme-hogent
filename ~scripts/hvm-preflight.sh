#!/usr/bin/env bash
# hvm-preflight.sh - read-only sanity checks for an HPE VM Essentials (HVM) host.
#
# It changes nothing. It only judges.
#
# Usage:   sudo bash hvm-preflight.sh [manager-ip-or-fqdn]
# Example: sudo bash hvm-preflight.sh 172.16.63.221
#
# Run it on every host. Compare the machine-ids at the end. If two match,
# you cloned without reading the guide. We'll talk.

set -u

MANAGER="${1:-}"
FAILS=0
WARNS=0

if [ -t 1 ]; then
  G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; N=$'\e[0m'
else
  G=""; Y=""; R=""; B=""; N=""
fi

ok()      { printf '  %s[ OK ]%s %s\n' "$G" "$N" "$1"; }
warn()    { printf '  %s[WARN]%s %s\n' "$Y" "$N" "$1"; WARNS=$((WARNS + 1)); }
fail()    { printf '  %s[FAIL]%s %s\n' "$R" "$N" "$1"; FAILS=$((FAILS + 1)); }
info()    { printf '  [INFO] %s\n' "$1"; }
section() { printf '\n%s%s%s\n' "$B" "$1" "$N"; }
have()    { command -v "$1" >/dev/null 2>&1; }

ROOT=0
[ "$(id -u)" -eq 0 ] && ROOT=1

printf '%shvm-preflight%s - checking %s. Brace yourself.\n' "$B" "$N" "$(hostname)"
[ "$ROOT" -eq 1 ] || printf '%sNot running as root: some checks will be skipped. Use sudo.%s\n' "$Y" "$N"

# ---------------------------------------------------------------------------
section "Operating system"
if [ -r /etc/os-release ]; then
  # shellcheck source=/dev/null
  OS_ID=$(. /etc/os-release && printf '%s' "${ID:-}")
  # shellcheck source=/dev/null
  OS_VER=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
  # shellcheck source=/dev/null
  OS_NAME=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}")
  case "$OS_ID:$OS_VER" in
    ubuntu:24.04) ok "$OS_NAME. Correct answer." ;;
    ubuntu:22.04) warn "$OS_NAME. Fine for older cluster layouts, but this guide assumes 24.04." ;;
    *)            fail "$OS_NAME. HVM hosts run Ubuntu. Not this." ;;
  esac
else
  fail "No /etc/os-release. What did you install?"
fi

# ---------------------------------------------------------------------------
section "Virtualization"
VT=$(grep -cwE 'vmx|svm' /proc/cpuinfo 2>/dev/null || true)
if [ "${VT:-0}" -gt 0 ]; then
  ok "CPU exposes VT-x/AMD-V on $VT thread(s)."
else
  fail "No vmx/svm CPU flags. Nested virtualization is off. Mail Annick (cpu_passthrough=true), then power cycle the VM from Prism."
fi
if [ -e /dev/kvm ]; then
  ok "/dev/kvm exists."
else
  warn "/dev/kvm is missing. KVM isn't loaded (yet?)."
fi

# ---------------------------------------------------------------------------
section "Memory"
MEM_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
MEM_GB=$(( (MEM_KB + 524288) / 1048576 ))
if [ "$MEM_GB" -lt 11 ]; then
  fail "About ${MEM_GB} GB RAM. HPE wants 8 GB plus 4 GB per Ceph disk. Math says no."
elif [ "$MEM_GB" -lt 15 ]; then
  warn "About ${MEM_GB} GB RAM. Technically enough. Practically tight."
else
  ok "About ${MEM_GB} GB RAM."
fi
info "Host 1 carries the VME Manager on top of everything else. Give that one 32 GB or more."

# ---------------------------------------------------------------------------
section "Disks (looking for a raw disk for Ceph)"
CANDIDATES=0
while read -r NAME SIZE_B; do
  [ -n "$NAME" ] || continue
  case "$NAME" in
    zram*|ram*|loop*|sr*|nbd*|rbd*|fd*) continue ;;   # not real disks, or Ceph's own block devices
  esac
  [ "${SIZE_B:-0}" -ge 1000000000 ] || continue        # ignore anything under 1 GB
  DEV="/dev/$NAME"
  SIZE_G=$(( SIZE_B / 1000000000 ))
  if lsblk -n -o NAME "$DEV" 2>/dev/null | grep -q 'ceph'; then
    ok "$DEV (${SIZE_G} GB) is already a Ceph OSD. Moving on."
    CANDIDATES=$((CANDIDATES + 1))
    continue
  fi
  KIDS=$(lsblk -n -o NAME "$DEV" 2>/dev/null | wc -l)
  MNT=$(lsblk -n -o MOUNTPOINT "$DEV" 2>/dev/null | tr -d '[:space:]')
  FST=$(lsblk -d -n -o FSTYPE "$DEV" 2>/dev/null | tr -d '[:space:]')
  if [ "$KIDS" -ne 1 ] || [ -n "$MNT" ]; then
    continue
  fi
  CANDIDATES=$((CANDIDATES + 1))
  if [ -n "$FST" ]; then
    warn "$DEV (${SIZE_G} GB) has no partitions but carries a '$FST' signature. Ceph wants it truly raw. Wipe it, carefully, on the RIGHT disk."
  elif [ "$SIZE_G" -lt 100 ]; then
    warn "$DEV (${SIZE_G} GB) is empty but small. It'll work. Barely."
  else
    ok "$DEV (${SIZE_G} GB) is empty and untouched. Ceph approves."
  fi
done < <(lsblk -d -b -n -o NAME,SIZE,TYPE -e 7,11 2>/dev/null | awk '$3 == "disk" {print $1, $2}')

if [ "$CANDIDATES" -eq 0 ]; then
  fail "No empty disk and no Ceph OSD found. Add a second vDisk for Ceph and leave it raw."
elif [ "$CANDIDATES" -gt 1 ]; then
  info "More than one candidate. Older VME docs allowed one Ceph data disk per host; check what your version supports."
fi

# ---------------------------------------------------------------------------
section "Time"
if have timedatectl; then
  SYNC=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
  TZONE=$(timedatectl show -p Timezone --value 2>/dev/null)
  if [ "$SYNC" = "yes" ]; then
    ok "Clock synchronized (timezone: ${TZONE:-unknown})."
  else
    warn "Clock not synchronized. Ceph will whine about clock skew, and it won't be wrong."
  fi
else
  info "No timedatectl. Check your clock some other way. Ceph will."
fi

# ---------------------------------------------------------------------------
section "Network"
GW=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
if [ -n "$GW" ]; then
  ok "Default gateway: $GW"
else
  fail "No default route. The installer needs the internet, and so does your cluster."
fi

if getent hosts archive.ubuntu.com >/dev/null 2>&1; then
  ok "DNS resolves the outside world."
else
  fail "Can't resolve archive.ubuntu.com. It's DNS. It's always DNS."
fi

HN=$(hostname)
HN_IP=$(getent hosts "$HN" 2>/dev/null | awk '{print $1; exit}')
if [ -z "$HN_IP" ]; then
  warn "Hostname '$HN' doesn't resolve. Put it in DNS or /etc/hosts."
else
  case "$HN_IP" in
    127.*) info "Hostname '$HN' resolves to $HN_IP (Ubuntu's default). If the cluster build complains about names, this is a suspect." ;;
    *)     ok "Hostname '$HN' resolves to $HN_IP." ;;
  esac
fi

if [ "$ROOT" -eq 1 ]; then
  if [ -d /etc/netplan ]; then
    if grep -RqsE '^[[:space:]]*dhcp4:[[:space:]]*(true|yes)' /etc/netplan/; then
      warn "netplan has dhcp4 enabled somewhere. Infrastructure gets static IPs."
    else
      ok "No DHCP in netplan."
    fi
    if grep -RqsE '^[[:space:]]*vlans:' /etc/netplan/; then
      warn "VLANs defined in netplan. Only the management network belongs there. Let Open vSwitch have the VM VLANs."
    else
      ok "No VLANs fighting OVS in netplan."
    fi
  fi
else
  info "Run as root to check netplan (its files are root-only)."
fi

if [ -d /etc/cloud ]; then
  if [ -e /etc/cloud/cloud-init.disabled ] || grep -RqsE 'network:[[:space:]]*\{[[:space:]]*config:[[:space:]]*disabled' /etc/cloud/cloud.cfg.d/; then
    ok "cloud-init won't touch your network."
  else
    warn "cloud-init can still rewrite your network on boot. Disable its network config."
  fi
else
  ok "No cloud-init. Nobody to interfere."
fi

if have ufw; then
  if [ "$ROOT" -eq 1 ]; then
    if ufw status 2>/dev/null | grep -q 'Status: active'; then
      warn "ufw is active. Hosts that can't talk to the Manager don't join clusters."
    else
      ok "ufw is inactive."
    fi
  else
    info "Run as root to check ufw."
  fi
fi

# ---------------------------------------------------------------------------
section "Identity (for the clone army)"
MID=$(cat /etc/machine-id 2>/dev/null || true)
if [ -z "$MID" ]; then
  fail "Empty /etc/machine-id. Run: sudo systemd-machine-id-setup"
else
  info "machine-id: $MID"
fi
if [ -r /etc/ssh/ssh_host_ed25519_key.pub ] && have ssh-keygen; then
  info "SSH host key: $(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $2}')"
fi
info "Compare both with your other hosts. Identical values mean a clone that skipped a step."

# ---------------------------------------------------------------------------
section "VME bits"
if dpkg -s hpe-vm >/dev/null 2>&1; then
  ok "hpe-vm installed (version $(dpkg-query -W -f='${Version}' hpe-vm 2>/dev/null))."
else
  info "hpe-vm isn't installed (yet)."
fi
if have ovs-vsctl; then ok "Open vSwitch present."; else info "No ovs-vsctl yet. It shows up once hpe-vm does its thing."; fi
if have virsh;     then ok "libvirt present.";      else info "No virsh yet. It shows up once hpe-vm does its thing."; fi

# ---------------------------------------------------------------------------
if [ -n "$MANAGER" ]; then
  section "Manager ($MANAGER)"
  if ! [[ "$MANAGER" =~ ^[A-Za-z0-9.-]+$ ]]; then
    fail "'$MANAGER' doesn't look like an IP or a hostname. Try again."
  else
    if [[ "$MANAGER" =~ ^[0-9.]+$ ]]; then
      ok "It's an IP. No DNS involved. Smart."
    else
      M_IP=$(getent hosts "$MANAGER" 2>/dev/null | awk '{print $1; exit}')
      if [ -n "$M_IP" ]; then
        ok "$MANAGER resolves to $M_IP."
      else
        fail "$MANAGER doesn't resolve from this host. Enjoy your 99%."
      fi
    fi
    # shellcheck disable=SC2016  # $1 is meant for the inner shell
    if timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/443"' _ "$MANAGER" 2>/dev/null; then
      ok "TCP 443 reachable. The agent can phone home."
    else
      warn "Can't reach $MANAGER on 443. Fine if the Manager isn't deployed yet. Not fine after."
    fi
  fi
fi

# ---------------------------------------------------------------------------
section "Verdict"
if [ "$FAILS" -gt 0 ]; then
  printf '  %s%d fail(s), %d warning(s).%s Fix the fails before you blame HPE.\n' "$R" "$FAILS" "$WARNS" "$N"
  exit 1
elif [ "$WARNS" -gt 0 ]; then
  printf '  %s0 fails, %d warning(s).%s Probably fine. "Probably" is doing a lot of work there.\n' "$Y" "$WARNS" "$N"
else
  printf '  %sAll green.%s Suspicious, but I will allow it.\n' "$G" "$N"
fi
exit 0
