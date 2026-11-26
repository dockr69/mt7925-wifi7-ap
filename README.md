<h1 align="center">MT7925 Wi-Fi 7 Access Point</h1>

<p align="center">
  Turn a <b>MediaTek MT7925</b> M.2 card into a <b>Wi-Fi 7 (802.11be)</b> access point on Linux –<br>
  6 GHz, 160 MHz, WPA3, NAT to Ethernet. One script, Debian 12 arm64.
</p>

<p align="center">
  <img alt="Wi-Fi 7" src="https://img.shields.io/badge/Wi--Fi%207-802.11be-6f42c1">
  <img alt="6 GHz" src="https://img.shields.io/badge/6%20GHz-160%20MHz-0a7ea4">
  <img alt="WPA3" src="https://img.shields.io/badge/security-WPA3--SAE%20(H2E)-2ea44f">
  <img alt="Debian 12 arm64" src="https://img.shields.io/badge/Debian%2012-arm64-a80030">
  <img alt="hostapd 2.12" src="https://img.shields.io/badge/hostapd-2.12-555">
  <img alt="License MIT" src="https://img.shields.io/badge/license-MIT-blue">
</p>

---

## Results

| | |
|---|---|
| **Standard** | Wi-Fi 7 (EHT), 2×2 MIMO |
| **Band / width** | 6 GHz, channel 37, **160 MHz** (5 GHz / 80 MHz as alternative) |
| **Link rate** | **2402 Mbit/s** EHT-MCS 11, 2×2 |
| **iperf3, AP → client, 4 streams** | **≈ 1.2 Gbit/s**, peak **1.56 Gbit/s** |
| **Internet through NAT** | ≈ 910 Mbit/s – the Gigabit uplink is the limit |
| **Test hardware** | Radxa ROCK 3A (RK3568, 4× Cortex-A55) – see [test hardware](docs/testhardware.md) |

Not bad for a quad Cortex-A55 board.

## What it takes

| Topic | What really matters |
|---|---|
| Kernel | **≥ 6.7** (`mt7925e`). Debian 12: `bookworm-backports` (6.12) |
| Firmware | `mediatek/mt7925/*` – older `firmware-misc-nonfree` doesn't have it |
| Wi-Fi 7 | **hostapd ≥ 2.11** with `CONFIG_IEEE80211BE`. Debian 12/13 ship 2.10 → build **2.12** |
| 6 GHz security | **WPA3-SAE + PMF only** – and **SAE H2E (`sae_pwe`) is mandatory**, otherwise clients just say *"connection failed"* |
| 160 MHz | `op_class=134` + `he_oper_chwidth=2` – otherwise clients fall back to 80 MHz |
| Bands | **one AP at a time** per card (5 **or** 6 GHz) |
| 320 MHz / MLO | not advertised by the driver in 6.12 / not tested |

All the details – with the original error messages – are in **[docs/learnings.md](docs/learnings.md)**.

## Quick start

```bash
# on the board, as root
git clone https://github.com/dockr69/mt7925-wifi7-ap.git && cd mt7925-wifi7-ap
sudo AP_PASS='change-me-please' ./scripts/setup.sh   # kernel, firmware, hostapd 2.12, dnsmasq, NAT
sudo reboot                                          # only needed after a kernel update
```

That's it: SSID **`mt7925-ap-6g`** on 6 GHz with Wi-Fi 7. Without `AP_PASS`
the script generates a random password and prints it at the end.

```bash
sudo wlan-ap-band 5        # switch to 5 GHz (SSID mt7925-ap, 80 MHz)
sudo wlan-ap-band 6        # back to 6 GHz (SSID mt7925-ap-6g, 160 MHz)
sudo wlan-ap-status        # services, hostapd version, clients with EHT/HE rates
```

### Options

All options are environment variables for `setup.sh`:

| Variable | Default | Meaning |
|---|---|---|
| `AP_PASS` | random | WPA3 passphrase (≥ 8 characters) |
| `AP_SSID` | `mt7925-ap` | SSID (6 GHz gets the suffix `-6g`) |
| `AP_BAND` | `6` | active band: `5` or `6` |
| `AP_OPEN_5G` | `0` | `1` = 5 GHz network without password (6 GHz always needs WPA3) |
| `WIFI7` | `1` | `0` = Wi-Fi 6 only with the Debian hostapd 2.10, no build |
| `COUNTRY` | `DE` | regulatory domain |
| `AP_IFACE` | `wlp1s0` | Wi-Fi interface |
| `AP_NET` | `192.168.50` | AP subnet (`.1` = AP, DHCP `.100–.200`) |
| `FORCE_KERNEL` | `0` | `1` = install the backports kernel even if ≥ 6.7 is running |

## How it works

```
 client ──Wi-Fi 7──▶ wlp1s0 192.168.50.1 ──NAT──▶ end0 ──▶ router ──▶ internet
                        │
                        ├─ hostapd 2.12   6 GHz · 160 MHz · EHT · WPA3-SAE (H2E)
                        ├─ dnsmasq        DHCP .100–.200, DNS forwarder
                        └─ wlan-ap-nat    iptables MASQUERADE + FORWARD, uplink from default route
```

- The self-built hostapd lives in `/usr/local/sbin`; a systemd drop-in points the
  Debian service at it. Delete the drop-in and you are back on the package.
- NetworkManager is told to keep its hands off the AP interface.
- The AP subnet deliberately avoids Docker's `172.17.x`.

## Repository

```
configs/hostapd-6g.conf          6 GHz template – WPA3-SAE (H2E), EHT, 160 MHz
configs/hostapd-5g.conf          5 GHz template – WPA3-SAE, EHT, 80 MHz
configs/dnsmasq-wlan-ap.conf     DHCP/DNS template
scripts/setup.sh                 installation (idempotent)
scripts/build-hostapd.sh         builds hostapd 2.12 with 802.11be
scripts/wlan-ap-band             switch band 5 | 6
scripts/wlan-ap-nat              NAT rules (uplink auto-detected)
scripts/wlan-ap-status           diagnosis
systemd/hostapd-2.12.conf        drop-in: use /usr/local/sbin/hostapd
systemd/wlan-ap-nat.service      NAT service (starts after hostapd)
docs/learnings.md                every pitfall, with original error messages
docs/troubleshooting.md          symptom → cause → fix
docs/testhardware.md             boards it was tested on
```

## Known limitations

- **One band at a time** – the MT7925 runs a single AP interface.
- **No 320 MHz** with kernel 6.12, **MLO** not tested.
- `iw` reports **3 dBm** TX power in AP mode and ignores `set txpower` –
  short range is fine, long range was not measured.
- 2.4 GHz not tested (config would be analogous, `hw_mode=g`).

## License

[MIT](LICENSE)
