#!/usr/bin/env bash
# MT7925 Wi-Fi 7 access point – setup for Debian 12 arm64. Idempotent, safe to re-run.
#
#   sudo AP_PASS='secret123' ./scripts/setup.sh
#   sudo AP_BAND=5 AP_OPEN_5G=1 ./scripts/setup.sh      # 5 GHz, open network
#   sudo WIFI7=0 ./scripts/setup.sh                     # Wi-Fi 6 only, Debian hostapd 2.10
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Please run as root: sudo $0"; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

AP_IFACE="${AP_IFACE:-wlp1s0}"
AP_SSID="${AP_SSID:-mt7925-ap}"
AP_NET="${AP_NET:-192.168.50}"
AP_BAND="${AP_BAND:-6}"            # 5 | 6 – one band at a time
AP_OPEN_5G="${AP_OPEN_5G:-0}"      # 1 = 5 GHz without password (6 GHz always needs WPA3)
COUNTRY="${COUNTRY:-DE}"
WIFI7="${WIFI7:-1}"                # 1 = build hostapd 2.12 and enable 802.11be
UPSTREAM_DNS="${UPSTREAM_DNS:-$(ip route show default | awk '{print $3; exit}')}"

PASS_NOTE=""
if [ -z "${AP_PASS:-}" ]; then
  AP_PASS="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)"
  PASS_NOTE="   <- randomly generated, write it down"
fi
[ "${#AP_PASS}" -ge 8 ] || { echo "AP_PASS needs at least 8 characters"; exit 1; }

log() { printf '\n==> %s\n' "$*"; }
export DEBIAN_FRONTEND=noninteractive

# --- kernel ------------------------------------------------------------------
CODENAME="$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-unknown}")"
KVER="$(uname -r)"
kernel_ok() {
  [ "${FORCE_KERNEL:-0}" = "1" ] && return 1
  printf '6.7\n%s\n' "${KVER%%-*}" | sort -V -C
}

log "Kernel >= 6.7 (mt7925e)"
if kernel_ok; then
  echo "  running kernel $KVER ships mt7925e"
elif [ "$CODENAME" = "bookworm" ]; then
  grep -rqs 'bookworm-backports' /etc/apt/sources.list /etc/apt/sources.list.d/ || \
    echo 'deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware' \
      > /etc/apt/sources.list.d/backports.list
  apt-get update -qq
  echo "  kernel $KVER too old -> linux-image-arm64 from bookworm-backports"
  apt-get install -y -t bookworm-backports --no-install-recommends linux-image-arm64
else
  echo "  kernel $KVER too old and '$CODENAME' is not bookworm – install a kernel >= 6.7 first." >&2
  exit 1
fi

# --- packages + firmware -----------------------------------------------------
log "Packages"
apt-get update -qq
apt-get install -y -qq iw rfkill hostapd dnsmasq iptables curl >/dev/null

log "MT7925 firmware"
FW=/lib/firmware/mediatek/mt7925
BASE=https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7925
mkdir -p "$FW"
for f in WIFI_MT7925_PATCH_MCU_1_1_hdr.bin WIFI_RAM_CODE_MT7925_1_1.bin BT_RAM_CODE_MT7925_1_1_hdr.bin; do
  [ -s "$FW/$f" ] || curl -fsSL --retry 3 -o "$FW/$f" "$BASE/$f"
done

# --- hostapd with 802.11be ---------------------------------------------------
DROPIN=/etc/systemd/system/hostapd.service.d
install -d "$DROPIN"
if [ "$WIFI7" = "1" ]; then
  log "hostapd with 802.11be"
  HV="$(/usr/local/sbin/hostapd -v 2>&1 || true)"     # hostapd -v exits 1
  if grep -qE 'v2\.(1[1-9]|[2-9][0-9])' <<<"$HV"; then
    echo "  $(head -1 <<<"$HV") already installed"
  else
    "$REPO_DIR/scripts/build-hostapd.sh"
  fi
  install -m 0644 "$REPO_DIR/systemd/hostapd-2.12.conf" "$DROPIN/hostapd-2.12.conf"
else
  rm -f "$DROPIN/hostapd-2.12.conf"
fi

# --- configuration -----------------------------------------------------------
log "Rendering config ($AP_IFACE / $AP_SSID / band $AP_BAND / Wi-Fi 7: $WIFI7)"
install -d /etc/hostapd /etc/dnsmasq.d /etc/NetworkManager/conf.d

esc() { sed -e 's/[\\&|]/\\&/g' <<<"$1"; }   # make values safe for the sed replacement
render() {
  sed -e "s|@AP_IFACE@|$(esc "$AP_IFACE")|g" \
      -e "s|@AP_SSID@|$(esc "$AP_SSID")|g" \
      -e "s|@AP_PASS@|$(esc "$AP_PASS")|g" \
      -e "s|@AP_NET@|$(esc "$AP_NET")|g" \
      -e "s|@COUNTRY@|$(esc "$COUNTRY")|g" \
      -e "s|@UPSTREAM_DNS@|$(esc "$UPSTREAM_DNS")|g" "$REPO_DIR/configs/$1" > "$2"
}
render hostapd-5g.conf /etc/hostapd/ap-5g.conf
render hostapd-6g.conf /etc/hostapd/ap-6g.conf
chmod 600 /etc/hostapd/ap-5g.conf /etc/hostapd/ap-6g.conf   # contain the passphrase
render dnsmasq-wlan-ap.conf         /etc/dnsmasq.d/wlan-ap.conf
render networkmanager-unmanaged.conf /etc/NetworkManager/conf.d/99-wlan-ap.conf
# no default route during setup -> let dnsmasq use /etc/resolv.conf instead of an empty server=
[ -n "$UPSTREAM_DNS" ] || sed -i '/^server=$/d' /etc/dnsmasq.d/wlan-ap.conf

[ "$WIFI7" = "1" ] || \
  sed -i -E '/^(ieee80211be|eht_oper_[a-z0-9_]+)=/d' /etc/hostapd/ap-5g.conf /etc/hostapd/ap-6g.conf
[ "$AP_OPEN_5G" != "1" ] || \
  sed -i -E '/^(wpa|wpa_key_mgmt|wpa_passphrase|rsn_pairwise|ieee80211w|sae_require_mfp|sae_pwe)=/d' \
    /etc/hostapd/ap-5g.conf

ACTIVE=/etc/hostapd/ap-6g.conf; SSID_ACTIVE="$AP_SSID-6g"
[ "$AP_BAND" = "5" ] && { ACTIVE=/etc/hostapd/ap-5g.conf; SSID_ACTIVE="$AP_SSID"; }
install -m 0600 "$ACTIVE" /etc/hostapd/hostapd.conf

# Debian ships hostapd masked and needs DAEMON_CONF
sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd 2>/dev/null || true
grep -q '^DAEMON_CONF=' /etc/default/hostapd 2>/dev/null || \
  echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd

cat > "$DROPIN/ap-addr.conf" <<EOF
[Service]
ExecStartPre=/sbin/ip addr replace ${AP_NET}.1/24 dev ${AP_IFACE}
ExecStartPre=/sbin/ip link set ${AP_IFACE} up
EOF

log "Forwarding, helpers, services"
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wlan-ap.conf
sysctl -q -p /etc/sysctl.d/99-wlan-ap.conf
for s in wlan-ap-band wlan-ap-nat wlan-ap-status; do
  install -m 0755 "$REPO_DIR/scripts/$s" "/usr/local/sbin/$s"
done
sed "s|AP_IFACE=wlp1s0|AP_IFACE=${AP_IFACE}|" "$REPO_DIR/systemd/wlan-ap-nat.service" \
  > /etc/systemd/system/wlan-ap-nat.service

systemctl unmask hostapd >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl reload NetworkManager 2>/dev/null || true
systemctl enable hostapd dnsmasq wlan-ap-nat.service >/dev/null 2>&1

if ip link show "$AP_IFACE" >/dev/null 2>&1; then
  rfkill unblock wlan 2>/dev/null || true
  systemctl restart hostapd dnsmasq wlan-ap-nat.service
  sleep 3
  hostapd_cli -p /run/hostapd -i "$AP_IFACE" status 2>/dev/null \
    | grep -E '^(state|ssid\[0\]|freq|channel|ieee80211be)=' | sed 's/^/  /' || true
else
  echo "  $AP_IFACE does not exist yet – reboot once after the kernel update."
fi

PASS_INFO="$AP_PASS$PASS_NOTE"
[ "$AP_BAND" = "5" ] && [ "$AP_OPEN_5G" = "1" ] && PASS_INFO="(open network)"
cat <<EOF

Done.

  SSID        : $SSID_ACTIVE
  Password    : $PASS_INFO
  Switch band : sudo wlan-ap-band 5 | 6
  Status      : sudo wlan-ap-status
EOF
