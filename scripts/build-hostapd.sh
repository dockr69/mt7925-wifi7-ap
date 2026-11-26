#!/usr/bin/env bash
# Build hostapd with 802.11be (EHT / Wi-Fi 7) and install it to /usr/local/sbin.
# Debian 12/13 only ship hostapd 2.10 (no EHT). The package stays installed as a fallback.
#
#   sudo ./scripts/build-hostapd.sh            # version 2.12
#   sudo HOSTAPD_VERSION=x.y ./scripts/build-hostapd.sh   # another release (>= 2.12 recommended)
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Please run as root: sudo $0"; exit 1; }

VER="${HOSTAPD_VERSION:-2.12}"
SRC=/usr/local/src
export DEBIAN_FRONTEND=noninteractive

echo "==> Build dependencies"
apt-get update -qq
apt-get install -y -qq build-essential pkg-config libnl-3-dev libnl-genl-3-dev \
  libnl-route-3-dev libssl-dev curl >/dev/null

echo "==> Downloading hostapd-$VER"
mkdir -p "$SRC" && cd "$SRC"
rm -rf "hostapd-$VER" "hostapd-$VER.tar.gz"
curl -fsSLO "https://w1.fi/releases/hostapd-$VER.tar.gz"
if [ "$VER" = "2.12" ]; then
  echo "f43502561c28ba47ab77e18e1a973d07361c68cc8b14178e619bd5796b70eabd  hostapd-2.12.tar.gz" | sha256sum -c -
else
  sha256sum "hostapd-$VER.tar.gz"   # no pinned checksum for this version – compare with w1.fi
fi
tar xzf "hostapd-$VER.tar.gz"
cd "hostapd-$VER/hostapd"

cp defconfig .config
cat >> .config <<'CFG'
CONFIG_DRIVER_NL80211=y
CONFIG_LIBNL32=y
CONFIG_IEEE80211AC=y
CONFIG_IEEE80211AX=y
CONFIG_IEEE80211BE=y
CONFIG_SAE=y
CONFIG_OWE=y
CONFIG_CTRL_IFACE=y
CFG

echo "==> Compiling (about 5–10 min on 4× Cortex-A55)"
make -j"$(nproc)" > /tmp/hostapd-build.log 2>&1 || { tail -30 /tmp/hostapd-build.log; exit 1; }
install -m 755 hostapd     /usr/local/sbin/hostapd
install -m 755 hostapd_cli /usr/local/sbin/hostapd_cli
{ /usr/local/sbin/hostapd -v 2>&1 || true; } | head -1   # hostapd -v exits 1
