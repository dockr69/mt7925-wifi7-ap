# Learnings – MT7925 as an access point on Linux

Everything here was verified on real hardware (Radxa ROCK 3A, RK3568, Debian 12,
kernel 6.12.95, hostapd 2.12 – see [testhardware.md](testhardware.md)).
Error messages are quoted verbatim from the logs.

## 1. Kernel 6.1 is not enough

`mt7925e` landed in **Linux 6.7**. Debian 12 ships 6.1, and vendor BSP kernels
(e.g. Rockchip `6.1.84-rk2410`) don't have it either:

```
$ find /lib/modules/$(uname -r) -iname '*mt79*'
.../mediatek/mt7601u/mt7601u.ko.xz      # only the ancient mt7601u
```

The card shows up on PCIe (`lspci` → `14c3:7925`) but stays unbound.
Fix: `linux-image-arm64` from `bookworm-backports` (6.12).
On arm64 the kernel, its modules **and** the DTBs are one package
(`linux-image-6.12.x+deb12-arm64`, ~92 MB) – there is no separate modules package.

## 2. Firmware is missing from older packages

`firmware-misc-nonfree 20230210-5` does not know the MT7925. You need:

```
/lib/firmware/mediatek/mt7925/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin
/lib/firmware/mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin
/lib/firmware/mediatek/mt7925/BT_RAM_CODE_MT7925_1_1_hdr.bin   # Bluetooth only
```

Without them the driver loads but firmware init fails. `setup.sh` fetches them
from `linux-firmware` (git.kernel.org). A healthy init looks like this:

```
mt7925e 0000:01:00.0: ASIC revision: 79250000
mt7925e 0000:01:00.0: WM Firmware Version: ____000000, Build Time: ...
mt7925e 0000:01:00.0 wlp1s0: renamed from wlan0
```

## 3. Wi-Fi 7 needs hostapd ≥ 2.11 – build 2.12

The driver supports EHT in AP mode:

```
$ iw list | grep -E 'HE Iftypes|EHT Iftypes'
        HE Iftypes: AP
        EHT Iftypes: AP
```

…but Debian 12 **and** 13 ship hostapd **2.10**, which has no 802.11be at all.
hostapd 2.11 added EHT, but has a missing bounds check in the Wi-Fi 7 MLO
association path that was only fixed in **2.12**. So: build 2.12 from
[w1.fi](https://w1.fi/releases/) with `CONFIG_IEEE80211BE=y`
([`scripts/build-hostapd.sh`](../scripts/build-hostapd.sh)) and point the
service at it with a drop-in ([`systemd/hostapd-2.12.conf`](../systemd/hostapd-2.12.conf)).
The Debian package stays installed as a fallback.

Config lines on top of a working HE setup:

```
ieee80211be=1
eht_oper_chwidth=2               # same encoding as he_oper_chwidth (2 = 160 MHz)
eht_oper_centr_freq_seg0_idx=47
```

Result, straight from `iw dev wlp1s0 station dump`:

```
tx bitrate: 1200.9 MBit/s 80MHz EHT-MCS 11 EHT-NSS 2 EHT-GI 0
rx bitrate:  864.6 MBit/s 160MHz EHT-MCS 4 EHT-NSS 2 EHT-GI 0
```

Kernel 6.12 does **not** advertise 320 MHz for the MT7925 – 160 MHz is the maximum.
Multi-link operation (MLO) was not tested.

## 4. 6 GHz: WPA3 only – and SAE H2E is mandatory

6 GHz refuses open and WPA2 networks:

```
Pre-RSNA security methods are not allowed in 6 GHz
```

It needs **SAE + PMF** (`wpa_key_mgmt=SAE`, `ieee80211w=2`). That is not
enough though: on 6 GHz clients **only** do SAE *hash-to-element* (H2E).
hostapd defaults to `sae_pwe=0` (hunting-and-pecking only), so every attempt
ends with a plain **"connection failed"** on the client – and hostapd logs
nothing at its default log level. Fix:

```
sae_pwe=2      # H2E + hunting-and-pecking (1 = H2E only)
```

Regulatory (DE): `(5945 - 6425 @ 320), 23 dBm, NO-OUTDOOR`.

## 5. 160 MHz on 6 GHz needs `op_class=134` and `he_oper_chwidth=2`

With `op_class=133` and `he_oper_chwidth=1`, `iw dev … info` happily reports
`width: 160 MHz`, but clients associate with **80 MHz** only. Set both:

```
channel=37
op_class=134                 # 6 GHz, 160 MHz
he_oper_chwidth=2            # 2 = 160 MHz
he_oper_centr_freq_seg0_idx=47
```

## 6. Only **one** AP interface per card

A second AP VIF on the same PHY fails:

```
nl80211: Failed to set interface 5 to mode 3: -16 (Device or resource busy)
nl80211 driver initialization failed.
```

So it's 5 GHz **or** 6 GHz (`wlan-ap-band 5|6`), not both at once.

## 7. A second VIF needs its own MAC

A VIF created with `iw dev wlp1s0 interface add … type __ap` inherits the
parent MAC, and the kernel refuses to bring it up:

```
Could not set interface wlp1s0-6g flags (UP): Name not unique on network
```

Fix: `ip link set <vif> address <mac+1>` **before** bringing it up.

## 8. hostapd is masked after installation

```
Failed to enable unit: Unit file /etc/systemd/system/hostapd.service is masked.
```

→ `systemctl unmask hostapd`, then set `DAEMON_CONF="/etc/hostapd/hostapd.conf"`
in `/etc/default/hostapd`. Without `DAEMON_CONF` the service does not start
(`ConditionFileNotEmpty`).

## 9. Failed SAE logins only show up in debug mode

For any "client can't connect" problem, turn on the debug log first:

```bash
echo 'DAEMON_OPTS="-d -t -f /var/log/hostapd-debug.log"' | sudo tee -a /etc/default/hostapd
sudo systemctl restart hostapd
```

A good login ends with `AP-STA-CONNECTED` and `EAPOL-4WAY-HS-COMPLETED`.
Switch it off again afterwards – the log grows fast.

## 10. Boot order: NAT started before hostapd

At boot `wlan-ap-nat.service` ran before hostapd had put the interface into AP
mode and failed with `no AP interface found`. Fix in the unit:
`After=/Wants=hostapd.service`, `Environment=AP_IFACE=wlp1s0`, `Restart=on-failure`.
hostapd itself may also start before `wlp1s0` exists
(`Cannot find device "wlp1s0"`) – its `Restart=on-failure` covers that.

## 11. Interface names and MAC change with the kernel

Moving from a vendor kernel to mainline renamed the interfaces and the board
got a different Ethernet MAC (vendor DTB vs. eFuse) – and therefore a new
DHCP address:

| Vendor 6.1 | Mainline 6.12 |
|---|---|
| `end1` (Ethernet) | `end0` |
| `wlan0` → `wlp1s0` | `wlp1s0` |

That's why `wlan-ap-nat` takes the uplink from the default route at runtime
instead of hardcoding `end0`. Use mDNS (`<hostname>.local`) or a DHCP reservation.

## 12. TX power reads 3 dBm

```
$ iw dev wlp1s0 info
    txpower 3.00 dBm
```

`iw dev wlp1s0 set txpower fixed|limit 2000` is ignored in AP mode. The value
looks cosmetic: a client next to the board still sees −41 dBm and runs
EHT-MCS 11. Range at larger distances was not measured.

## 13. Performance

Measured with one Wi-Fi 7 client next to the AP (6 GHz, 160 MHz, 2×2):

| Test | Result |
|---|---|
| `iperf3 -c 192.168.50.1 -R -P 4` (AP → client, 4 streams) | **≈ 1.2 Gbit/s** |
| Internet download through NAT | ≈ 910 Mbit/s (Gigabit uplink is the limit) |
| Link rate | 1200 Mbit/s EHT-MCS 11 / 160 MHz |

With iperf3 *to the AP* the board terminates TCP itself, so this is CPU-bound
on the 4× Cortex-A55 – the MT7925 does a lot in hardware.

## 14. `systemctl` without sudo hangs in non-TTY sessions

```
Failed to restart hostapd.service: Interactive authentication required.
```

Over SSH without a TTY, PolicyKit waits for interactive auth and the command
seems to hang forever. Always use `sudo`.

## 15. Handy checks

```bash
lspci -nn | grep 14c3                 # card present?
lsusb | grep 0e8d                     # the MT7925 also shows up on USB (Bluetooth)
iw list | grep -E 'HE Iftypes|EHT Iftypes'
iw reg get                            # country code / channels
hostapd_cli -p /run/hostapd -i wlp1s0 status
iw dev wlp1s0 station dump            # clients incl. EHT/HE rates
journalctl -u hostapd -u dnsmasq -f
```
