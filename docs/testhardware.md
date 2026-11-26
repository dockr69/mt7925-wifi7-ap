# Test hardware

The setup is not tied to a board. What matters is a **kernel ≥ 6.7**, the
**firmware** and an **M.2 E-key slot with PCIe**. Everything else is config.

| | Radxa ROCK 3A | Radxa Dragon Q8B |
|---|---|---|
| SoC | Rockchip RK3568 (4× Cortex-A55) | Qualcomm Snapdragon 8cx Gen 3 (SC8280XP) |
| Wi-Fi slot | M.2 E-key (PCIe 2.1 ×1) | M.2 E-key 2230 (PCIe) |
| Vendor kernel | 6.1 BSP, **no** `mt7925e` | distribution ships ≥ 6.7 |
| Kernel fix | `bookworm-backports` 6.12 | usually none |
| Ethernet | 1× GbE (`end0`) | 2× 2.5 GbE |
| Status | **fully tested**: Wi-Fi 7 AP on 6 GHz/160 MHz, NAT, numbers in [learnings #13](learnings.md#13-performance) | notes from the docs, not tested as an AP |

## Radxa ROCK 3A (main test system)

- Debian 12 (Radxa image, desktop removed), kernel `6.12.95+deb12-arm64` from backports
- MT7925 M.2 E-key card, hostapd 2.12 built from source
- After switching from the vendor kernel: `end1` → `end0`, new MAC from eFuse,
  new DHCP address (see learnings #11)
- The vendor 6.1 kernel stays in the boot menu as a fallback

## Radxa Dragon Q8B

According to Radxa's docs (not tested as an AP here):

- Snapdragon 8cx Gen 3, 1× M.2 E-key 2230 for Wi-Fi/BT, 2× 2.5 GbE
- UEFI boot – kernel updates are less fiddly than on U-Boot boards
- Wi-Fi 7 on the board's own module only from **board revision V1.3**
- Debian 13 / Armbian usually ship `mediatek/mt7925/*`; `setup.sh` skips the
  kernel step when `uname -r` is ≥ 6.7 (`FORCE_KERNEL=1` to override)
- `wlan-ap-nat` detects the uplink from the default route, so either 2.5 GbE port works
