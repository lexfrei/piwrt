# piwrt

OpenWrt Wi-Fi access points that tunnel all client traffic through an AmneziaWG v2 VPN, with DoH upstream, a DNS-level kill switch, and a domain-based split-tunnel that bypasses the VPN for Russian services (Ozon, Avito, Yandex, banks, gov services) so their anti-fraud doesn't trip on a foreign exit IP.

Two hardware targets, one architecture:

- **[`pi/`](pi/)** — Raspberry Pi 5 with built-in Wi-Fi (BCM43455). Single 5 GHz radio, single ethernet WAN, BCM-specific gotchas (ACS broken on brcmfmac, occasional 2.4 GHz RX-deaf state, NVMe selection matters).
- **[`hopper/`](hopper/)** — Netcraze NC-3811 / Keenetic KN-3811. MediaTek MT7976 dual-band Wi-Fi 6, dedicated 4-port managed switch, Huawei E3372 USB-LTE as cellular backup uplink, dual-WAN ECMP for split-VPN bypass.

## Common architecture

Both targets implement the same data flow:

```text
[Wi-Fi clients] ── radio (AP mode) ── br-lan ── 192.168.1.0/24
                                          │
                                          ├── awg0 (AmneziaWG v2 tunnel, default route)
                                          │       └── all LAN-forward traffic (kill switch)
                                          │
                                          └── fwmark 0x100 → table 100
                                                  └── split-VPN bypass for Russian domains
                                                      (populated by dnsmasq-full nftset
                                                       from itdoginfo/allow-domains list)
```

Common building blocks:

| Piece | Role |
| --- | --- |
| **AmneziaWG v2** | The encrypted tunnel; obfuscation params (`Jc`, `Jmin`, `Jmax`, `S1..S4`, `H1..H4`) make traffic look unlike WireGuard for DPI |
| **fw4 + nftables** | Stateful firewall + dynamic sets for bypass |
| **dnsmasq-full** | DHCP server + DNS forwarder + nftset population |
| **https-dns-proxy** | DoH to Cloudflare on `127.0.0.1:5053`, eliminates plaintext DNS leaks |
| **Hotplug script** | Maintains the bypass routing table on every WAN ifup/ifdown |
| **`awg-watchdog`** | Bounces the tunnel if handshake is stale (every 2 min) |
| **`update-bypass-list`** | Weekly refresh of the Russian-domain list from upstream |
| **`/etc/.git` autocommit** | Lightweight etckeeper-replacement, hourly cron commit |
| **`post-upgrade.sh`** | Idempotent re-install of every custom package after `sysupgrade` |

## When to pick which

| Decision factor | Pi | Hopper |
| --- | --- | --- |
| You want one box, fixed location, single ethernet uplink | ✅ | ⚠️ overkill for stationary |
| You want a 5-port switch and not a USB-ethernet adapter | ❌ stick + USB dongle | ✅ 3×LAN + 1×WAN GbE |
| You want a real Wi-Fi 6 (HE80) radio on 5 GHz | ⚠️ BCM43455 is AC, not AX, single stream | ✅ MT7976CN AX dual-band 2×2 |
| You want LTE cellular backup at the same point | ⚠️ requires USB modem + extra config | ✅ designed-in dual-WAN ECMP |
| You can rebuild software from source in a pinch | ✅ ARMv8 a76, big distro support | ⚠️ ARMv8 a53, OpenWrt build only |
| 25.12.x AWG packages already exist | ✅ for bcm27xx | ✅ for mediatek_filogic |
| Per-watt | Pi5 idle 4–5 W | Hopper idle ~6 W |
| Out-of-band serial console | UART pins on GPIO | UART pads inside chassis |
| Power | 27 W USB-C PD | 12 V/1.5 A barrel jack |

Both run OpenWrt 25.12.3 with the same kernel ABI; the AmneziaWG kmod ships per-target from [Slava-Shchipunov/awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt).

## Getting started

- **Pi build:** see [`pi/README.md`](pi/README.md) — detailed walkthrough including NVMe choice, brcmfmac quirks, and the BCM-specific watchdog logic.
- **Hopper build:** see [`hopper/README.md`](hopper/README.md) — covers TFTP-recovery on a Netcraze rebrand, USB modem bring-up, dual-WAN ECMP, mobile TTL fix, LuCI removal for headless SSH-only admin.

Each subdirectory ships standalone:

- `configs/` — UCI configs (`network`, `wireless`, `firewall`, `dhcp`, ...) as templates with `<PLACEHOLDER>` slots for secrets. AWG private keys, Wi-Fi passwords, SSIDs, and other per-deployment values are never committed.
- `scripts/` — watchdogs, post-upgrade hook, bypass-list updater, etc-autocommit. Identical or near-identical between targets where possible; the differences are documented in each script's header.

## What is *not* here

- No prebuilt OpenWrt images — flash the upstream release factory image, then run the walkthrough.
- No AWG provider recommendations — bring your own `.conf`.
- No traffic accounting (vnstat is mentioned as an optional add-on in the Pi README).
- No mwan3. The Hopper README explains in detail why mwan3 is architecturally incompatible with the AWG-default-route killswitch.

## Repository conventions

- Single maintainer, direct commits to `master`. No PR workflow.
- Signed commits where the maintainer's GPG key is available; never `--no-gpg-sign`.
- Sanitized: configs are committed as `.example` files with `<PLACEHOLDER>` slots when they would otherwise carry secrets. Real keys, SSIDs, Wi-Fi passwords, AWG endpoint hostnames, and operator-specific identifiers are kept out of the tree.
