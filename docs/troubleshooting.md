# Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `iw dev` shows no Wi-Fi interface | kernel < 6.7, no `mt7925e` | backports kernel 6.12, reboot |
| Interface exists, AP won't start | firmware missing | `mediatek/mt7925/*` in `/lib/firmware` |
| Client: "connection failed" on 6 GHz | SAE without H2E | `sae_pwe=2` (or `1`) |
| Client stuck at 80 MHz on 6 GHz | wrong operating class / width | `op_class=134`, `he_oper_chwidth=2` |
| `unknown configuration item 'ieee80211be'` | Debian hostapd 2.10 | `scripts/build-hostapd.sh`, drop-in `hostapd-2.12.conf` |
| `Pre-RSNA security methods are not allowed in 6 GHz` | open/WPA2 on 6 GHz | `wpa_key_mgmt=SAE`, `ieee80211w=2` |
| `hostapd.service is masked` | Debian masks hostapd | `systemctl unmask hostapd` |
| hostapd exits immediately | `DAEMON_CONF` empty | check `/etc/default/hostapd` |
| `Cannot find device "wlp1s0"` at boot | hostapd faster than the driver | harmless, `Restart=on-failure` retries |
| `-16 (Device or resource busy)` | second AP VIF | one band at a time (`wlan-ap-band`) |
| `Name not unique on network` | VIF without its own MAC | `ip link set <vif> address <mac>` |
| Clients connect but no internet | NAT/FORWARD missing | `wlan-ap-nat start`, `wlan-ap-nat.service` |
| `wlan-ap-nat`: `no AP interface found` | started before hostapd | unit with `After=hostapd.service` + `Restart=on-failure` |
| No DHCP | dnsmasq not on the AP interface | `interface=` in `/etc/dnsmasq.d/wlan-ap.conf` |
| Client has an IP, DNS fails | wrong dnsmasq upstream | set `server=<router>` |
| `systemctl restart` hangs over SSH | PolicyKit without TTY | use `sudo` |
| New IP after a kernel change | MAC from eFuse instead of DTB | mDNS or DHCP reservation |

## Checking the chain

```bash
# 1) AP up? Which hostapd, which standard?
sudo wlan-ap-status

# 2) Client associated (look for EHT-MCS / HE-MCS)?
sudo iw dev wlp1s0 station dump

# 3) Failed logins? (debug log, see learnings #9)
sudo grep -E 'AP-STA-CONNECTED|EAPOL-4WAY-HS-COMPLETED|SAE' /var/log/hostapd-debug.log | tail

# 4) Lease handed out?
sudo journalctl -u dnsmasq -n 30 | grep -i dhcpack

# 5) NAT rules and forwarding?
sudo iptables -t nat -S POSTROUTING | grep MASQUERADE
sudo iptables -S FORWARD | grep wlp1s0
sysctl net.ipv4.ip_forward

# 6) Does the box itself reach the internet?
curl -s -o /dev/null -w '%{http_code}\n' https://deb.debian.org
```
