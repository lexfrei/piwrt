# piwrt on Hopper

Netcraze Hopper (NC-3811 / hardware-identical Keenetic KN-3811) running OpenWrt 25.12.3 as a Wi-Fi access point that tunnels all client traffic through an AmneziaWG v2 VPN. Dual-WAN failover between ethernet uplink and a Huawei E3372 LTE modem (HiLink mode). DoH upstream, DNS-level kill switch, domain-based split-tunnel that bypasses the VPN for Russian services (Ozon, Avito, Yandex, banks, gov services) so their anti-fraud doesn't trip on a foreign exit IP — same data flow as the Pi setup, adapted for MediaTek silicon and a mobile cellular backup link.

## Architecture

```text
[home ethernet] ── wan  (DHCP, metric 10) ─┐
                                            │
[Huawei E3372 HiLink] ─ eth1 ── wwan (DHCP, metric 20) ─┤
                                            │
                                            ├── awg0 (AmneziaWG v2)  ── lan forward (kill switch)
                                            │
                                            └── table 100 (fwmark 0x100)
                                                ECMP over up-WANs (per-flow hash)

[Wi-Fi clients] ── phy0-ap0 (2.4 GHz HE20) ──┐
                ── phy1-ap0 (5 GHz HE80)  ───┴── br-lan (lan1..lan3 + radios) ── 192.168.1.0/24
```

Three traffic classes:

- **All LAN client traffic** is forwarded through `awg0` (no `lan → wan` rule exists, only `lan → awg`). If the tunnel is down, clients lose internet entirely — that's the kill switch.
- **Split-VPN bypass** (Russian domain list) is marked `fwmark 0x100` by an nftables prerouting hook and routed through table 100. When both wan and wwan are up, table 100 holds an ECMP multipath default and bypass traffic is hashed per-flow across both uplinks. When one is down, the single remaining nexthop is used.
- **AWG outer UDP** (the encrypted handshake / data stream to the AWG server) is sent to a specific endpoint route installed by the netifd AWG handler. It rides whichever WAN has the lowest metric (wan when available, wwan when wan is down). Failover happens via `awg-watchdog` re-bringing up `awg0` after a stale handshake — single-path by design because WireGuard's endpoint roaming makes ECMP on the outer path unreliable.

## Scope, explicitly

Does exactly one thing: receive internet over ethernet (or LTE backup), broadcast Wi-Fi, shove client traffic through a VPN tunnel. No LuCI, no web UI, no `mwan3` policy routing, no IDS, no AdGuard Home, no Samba. Headless SSH-only admin via key auth from the WAN side.

If you want any of those, add them on top and keep your own branch — the README won't guide you there.

## Hardware caveats learned the hard way

### Netcraze NC-3811 vs Keenetic KN-3811

Hardware identical: MediaTek MT7981BA SoC, MT7976CN Wi-Fi 6 dual-band, MT7531AE managed switch (3 LAN + 1 WAN GbE), 512 MB DDR4, 256 MB SPI-NAND, USB 3.0. Netcraze is the post-sanctions rebrand of Keenetic, same team, same NDMS firmware family.

**TFTP recovery filename is different**. The stock Netcraze bootloader requests `NC-3811_recovery.bin`, not `KN-3811_recovery.bin` like the OpenWrt wiki documents for Keenetic. The dnsmasq TFTP log will show the exact filename being polled — symlink your factory image to whichever name the loader asks for. Otherwise the loader keeps re-trying every 2 seconds with no progress.

### Huawei E3372h-320 modem

- **Default firmware is HiLink** — the modem presents itself as an RNDIS network adapter on USB (vendor `12d1`, product `14db` after usb-modeswitch flips it out of CD-ROM mode `1f01`). OpenWrt sees `eth1` with DHCP from `192.168.8.1/24`, which is the modem's own NAT-router on the LTE WAN side.
- **HiLink mode means double NAT**. Hopper is in 192.168.8.0/24 from the modem; the modem itself NATs everything onto its LTE WAN public IP. Routable, but no AT-command access from OpenWrt.
- **Stick mode (NCM/PPP) is not viable** on the -320 hardware revision. The Balong 711 chipset has a signed bootloader. The OpenWrt forum has [a tracking thread](https://forum.openwrt.org/t/e3372h-320-from-hi-link-to-stick-mode/90544) where the original poster gave up and went back to HiLink; community attempts with `balong-usbdload` mostly brick the device.
- **TTL must be 65, not 64, on egress to the modem**. The HiLink-mode E3372 is a NAT-router, not a USB-Ethernet bridge — it decrements TTL on egress to LTE. Without the fix, operator-side tethering detection sees TTL=62 from a Linux source and applies throttling / forced tariff change / block. See [`configs/nftables/60-mobile-ttl.nft`](configs/nftables/60-mobile-ttl.nft) — sets `ip ttl set 65` and `ip6 hoplimit set 65` on `oifname "eth1"` egress, modem decrements to 64, operator sees phone-native value.

### MediaTek MT7976 Wi-Fi

- **ACS works** — unlike brcmfmac on the Pi, `mt76` supports the automatic channel selection survey, so `channel 'auto'` is a valid value on both 2.4 GHz and 5 GHz radios.
- **Two phys exposed as `radio0` (2.4 GHz, phy0) and `radio1` (5 GHz, phy1)**. Use both for full band coverage. Same SSID on both = client-side band steering.
- **RX-deaf state of the BCM43455 has not been observed** on MT7976 across multiple `wifi down; wifi up` cycles and reboots. `wifi-watchdog` is shipped as pre-emptive insurance but it has not logged an event yet — if it stays silent for months, safe to delete.
- **SSID with `@` or `.`**: OpenWrt's hostapd has `utf8_ssid=1` by default and emits `ssid2="..."` (quoted-string form) instead of `ssid=`. On the BCM43455 Pi setup this broke macOS / Nintendo Switch silent-fail association. On the MT7976 the same `ssid2=` emission was observed but the author reports clients associate fine. The hostapd build / hostapd version may matter — test with the actual clients you intend to use before assuming MT7976 is exempt. Falls-back is plain ASCII without `@`/`.`.

### USB and power

- **USB 3.0 port is on the side of the chassis**. E3372 plus a 25 cm extension cable so the modem's antenna can be positioned outside the metal box. The chassis Wi-Fi antennas are not affected because the modem is USB 3 and the Wi-Fi is on a separate SoC bus.
- **External antenna**. The modem has two TS-9 connectors under a small flap. If you mount the router away from a window (typical for a remote-cabin setup), the difference between built-in stub antennas and an external dual-MIMO panel is 6–10 dB SINR, easily the difference between LTE Cat.4 max throughput and crawl.
- **PSU 12V/1.5A barrel jack stock**. Has been stable; no PoE on this device.

## Prerequisites

- A Netcraze NC-3811 or Keenetic KN-3811 (any firmware — we'll wipe it).
- A spare ethernet-equipped Linux host on a wired network, with `dnsmasq` (or `tftpd-hpa` / `atftpd`) installable. Can be a NAS, a desktop, a laptop. The host's local NIC will be temporarily reconfigured to `192.168.1.2/24` for the TFTP-recovery step.
- An ethernet uplink (router / switch with DHCP) for the Hopper's WAN port.
- The AmneziaWG v2 server config file from your provider — `.conf` with `[Interface]` (PrivateKey, Address, MTU, Jc, Jmin, Jmax, S1..S4, H1..H4) and `[Peer]` (PublicKey, Endpoint, AllowedIPs, PersistentKeepalive).
- (Optional, for mobile backup) A Huawei E3372h-320 with a working SIM. Russian-region firmware (`H195SP3C...`) works out of the box on MegaFon / MTS / Beeline. Stick-mode firmware not required, not recommended.
- (Optional, for remote location) An outdoor LTE antenna with two TS-9 connectors and an indoor enclosure for the modem (UE200-style waterproof case keeps the modem on the antenna mast instead of fishing USB cables through a wall).

## Installation walkthrough

The numeric steps below assume you've never touched the device. If you have a partial install, skim the section headers and pick up where it makes sense.

### 1. Factory recovery: TFTP-flash OpenWrt 25.12.3

The stock NDMS / Netcraze firmware will not accept an OpenWrt `.bin` through its web UI — there's no path to flash anything not signed by the vendor. We use the bootloader's built-in TFTP-recovery mode instead, which fires before NDMS even loads.

On the helper Linux host:

```sh
# Get the OpenWrt factory image — check sha256sums on the mirror.
cd /srv/tftp
wget https://downloads.openwrt.org/releases/25.12.3/targets/mediatek/filogic/openwrt-25.12.3-mediatek-filogic-keenetic_kn-3811-squashfs-factory.bin

# The bootloader requests NC-3811_recovery.bin on Netcraze rebrand, KN-3811
# on Keenetic original. Symlink to whichever the device asks for — the
# dnsmasq log below will tell you definitively.
ln -s openwrt-25.12.3-mediatek-filogic-keenetic_kn-3811-squashfs-factory.bin NC-3811_recovery.bin
```

Pick a spare ethernet interface on the helper host (call it `enpX`), bring it up at the address the bootloader expects:

```sh
sudo ip addr flush dev enpX
sudo ip addr add 192.168.1.2/24 dev enpX
sudo ip link set enpX up

# TFTP-only dnsmasq — DNS disabled (--port=0), bound to the interface.
sudo dnsmasq --port=0 --enable-tftp --tftp-root=/srv/tftp \
             --interface=enpX --bind-interfaces \
             --log-facility=/tmp/tftp.log --log-debug --no-daemon &
```

Now to the Hopper:

1. **Power off completely.**
2. **Hold the recessed reset button** (paperclip).
3. **Apply power while still holding reset.**
4. **Keep reset held** until the Status LED starts blinking (3–5 seconds), then release. The bootloader is now in TFTP-recovery mode.
5. **Plug an ethernet cable** from a LAN port (blue) of the Hopper to `enpX` on the helper host. Not WAN — the bootloader listens on LAN.
6. **Watch the dnsmasq log** — within ~5 seconds the bootloader sends a TFTP read request:

   ```
   dnsmasq-tftp: file /srv/tftp/NC-3811_recovery.bin not found for 192.168.1.1
   ```

   That `file ... not found` line confirms the bootloader is talking to you and reveals the exact filename it wants. If the file is named correctly, the next line will be `sent /srv/tftp/NC-3811_recovery.bin to 192.168.1.1` and the transfer completes in ~3 seconds. The bootloader then writes the image to NAND (60–90 s of LED activity) and reboots into OpenWrt.

7. **Wait for it to come back up at `192.168.1.1`**. Default OpenWrt password is empty.

```sh
ssh -o PreferredAuthentications=password -o StrictHostKeyChecking=no root@192.168.1.1
# (press enter on password prompt — empty)
```

Stop and uninstall the helper's `dnsmasq` and remove the static IP on `enpX` — TFTP service is done with.

### 2. Why 25.12.3 specifically, not 25.12.4

The kmod-amneziawg kernel module is compiled against a specific OpenWrt kernel ABI. Slava-Shchipunov's [awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt) build releases track OpenWrt releases by tag (`v25.12.0`, `v25.12.1`, ..., `v25.12.3`). At the time this README was written, the latest release with a published Hopper-compatible `kmod-amneziawg` was **v25.12.3** (built against kernel `6.12.85`). OpenWrt 25.12.4 (kernel `6.12.87`) had been released, but no matching AWG package was up yet — `apk add` rejects the v25.12.3 kmod on a v25.12.4 system because the kernel hash in the package metadata doesn't match.

The fix is simple: stay on 25.12.3 until Slava cuts a 25.12.4 build, then re-flash the sysupgrade image and re-run the AWG install. Don't chase the OpenWrt bleeding edge unless you've confirmed AWG packages exist for it.

### 3. First-boot bootstrap: SSH key + password

Add your SSH pubkey (YubiKey-backed or whatever you trust) so you can disable password auth in a later step:

```sh
mkdir -p /etc/dropbear
cat > /etc/dropbear/authorized_keys <<'EOF'
ssh-ed25519 AAAA... your-pubkey-here
EOF
chmod 600 /etc/dropbear/authorized_keys
```

Set a root password as a fallback (optional — if you're confident in the key, leave it empty for now; we'll disable password auth entirely later anyway):

```sh
passwd
```

Optionally add a second admin pubkey for emergencies (lost YubiKey, etc.). The author keeps the deployment-tooling key alongside the YubiKey one until SSH-key-only is verified end-to-end with the YubiKey from a real client.

### 4. Modem bring-up (USB / cellular backup)

Plug the E3372 into the USB 3.0 port. By default it enumerates as CD-ROM with a Windows installer:

```sh
cat /sys/kernel/debug/usb/devices | grep -A4 12d1
# T:  ... Vendor=12d1 ProdID=1f01
# I:  ... Cls=08(stor.) Driver=(none)
```

Install usb-modeswitch and the RNDIS / CDC-Ether drivers — the modeswitch rule for vendor `12d1` PID `1f01` is shipped in the package's `usb_modeswitch.d`, no manual rule needed:

```sh
apk update
apk add usb-modeswitch kmod-usb-net-cdc-ether kmod-usb-net-rndis \
        kmod-usb-net-cdc-ncm kmod-usb-serial-option
```

Within seconds the modem re-enumerates as `12d1:14db` (HiLink RNDIS) and `eth1` appears with a Huawei OUI MAC. The interface is `DOWN` until netifd brings it up — done automatically once `/etc/config/network` has the `wwan` section (step 6 below).

### 5. AmneziaWG packages

`apk install` for AWG works the same as the Pi setup, but the ARCH string is the Hopper's `aarch64_cortex-a53_mediatek_filogic` instead of the Pi's `aarch64_cortex-a76_bcm27xx_bcm2712`:

```sh
VERSION="v25.12.3"
ARCH="aarch64_cortex-a53_mediatek_filogic"
URL="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/${VERSION}"

# Deps from the base feed (apk doesn't auto-resolve transitive deps
# of locally-installed .apk files).
apk add kmod-udptunnel4 kmod-udptunnel6 \
        kmod-crypto-lib-chacha20poly1305 kmod-crypto-lib-curve25519

# Then the three AWG packages.
for pkg in kmod-amneziawg amneziawg-tools luci-proto-amneziawg; do
    f="${pkg}_${VERSION}_${ARCH}.apk"
    wget -q -O "/tmp/${f}" "${URL}/${f}"
done
apk add --allow-untrusted \
    /tmp/kmod-amneziawg_*.apk \
    /tmp/amneziawg-tools_*.apk \
    /tmp/luci-proto-amneziawg_*.apk

modprobe amneziawg
awg --version
```

Note: `luci-proto-amneziawg` is installed but then immediately removed in step 9 (LuCI removal) — it's only needed transiently to register the proto handler with netifd. The kernel module + userspace tools stay.

### 6. DNS, dual-WAN, multipath, watchdog packages

```sh
# Base dnsmasq lacks nftset support — replace with dnsmasq-full.
apk del dnsmasq
apk add dnsmasq-full

# DoH proxy.
apk add https-dns-proxy

# Full iproute2 ip command — BusyBox ip applet does NOT implement
# multipath syntax, so the ECMP dual-WAN hotplug silently produces an
# empty table 100 without this.
apk add ip-full

# Optional but recommended: /etc git tracking.
apk add git

# Diagnostic tools.
apk add tcpdump-mini
```

### 7. Drop in the configs

All of these are templates with `<PLACEHOLDER>` slots. Replace from your AWG `.conf` and choose your Wi-Fi SSID / password.

```sh
# Network with awg0 + wan + wwan
cp configs/network.example /etc/config/network
$EDITOR /etc/config/network  # fill PrivateKey, peer block, addresses, J/S/H values

# Wireless — both radios, same SSID / key
cp configs/wireless.example /etc/config/wireless
$EDITOR /etc/config/wireless  # fill SSID and key

# Firewall, DHCP, https-dns-proxy — no placeholders
cp configs/firewall          /etc/config/firewall
cp configs/dhcp              /etc/config/dhcp
cp configs/https-dns-proxy   /etc/config/https-dns-proxy
cp configs/dropbear.example  /etc/config/dropbear

# nftables files (auto-included by fw4 from /etc/nftables.d/)
mkdir -p /etc/nftables.d
cp configs/nftables/50-allow-domains.nft /etc/nftables.d/
cp configs/nftables/60-mobile-ttl.nft    /etc/nftables.d/

# Hotplug script (ECMP-aware split-VPN router)
mkdir -p /etc/hotplug.d/iface
cp configs/hotplug.d/iface/90-split-vpn /etc/hotplug.d/iface/
chmod +x /etc/hotplug.d/iface/90-split-vpn
```

### 8. Patch dnsmasq init to run as root

Required because the `nftset=/domain/...` directives in `/etc/dnsmasq.d/allow-domains.conf` need `CAP_NET_ADMIN` to actually write into the nft sets. The default `dnsmasq` user inside the ujail sandbox does not have that capability — the directives parse silently but `nft list set inet fw4 allow_domains_v4` stays empty.

```sh
sed -i \
    -e 's|xappend "--user=dnsmasq"|xappend "--user=root"|' \
    -e 's|xappend "--group=dnsmasq"|xappend "--group=root"|' \
    /etc/init.d/dnsmasq
/etc/init.d/dnsmasq restart
```

Long-term fix would be to create `/etc/capabilities/dnsmasq.json` granting `cap_net_admin` and `procd_set_param capabilities ...` in the init script. OpenWrt 25.12 dnsmasq-full does not ship this and we don't want to maintain a downstream patch — the user-flip is one line and survives `apk upgrade dnsmasq-full` provided you re-run it (handled by `scripts/post-upgrade.sh`).

### 9. Drop in the scripts + crontab

```sh
mkdir -p /usr/share/piwrt
cp scripts/post-upgrade.sh /usr/share/piwrt/post-upgrade.sh
chmod +x /usr/share/piwrt/post-upgrade.sh

for s in awg-watchdog wifi-watchdog update-bypass-list.sh etc-autocommit; do
    cp scripts/$s /usr/bin/${s%.sh}
    chmod +x /usr/bin/${s%.sh}
done

# rc.local hook — calls post-upgrade.sh on every boot (idempotent).
# Insert before the final `exit 0`. See configs/rc.local.append.
$EDITOR /etc/rc.local

# Crontab — watchdogs + weekly bypass-list refresh + hourly autocommit.
cat >> /etc/crontabs/root <<'EOF'
*/2 * * * * /usr/bin/awg-watchdog
*/5 * * * * /usr/bin/wifi-watchdog
0 6 * * 0   /usr/bin/update-bypass-list
30 * * * *  /usr/bin/etc-autocommit
EOF
/etc/init.d/cron enable
/etc/init.d/cron restart
```

### 10. Activate

Order matters because of dependency chains (DNS for AWG endpoint resolution, etc.):

```sh
/etc/init.d/network restart
/etc/init.d/firewall restart
/etc/init.d/https-dns-proxy enable
/etc/init.d/https-dns-proxy restart
sleep 2
/etc/init.d/dnsmasq restart
sleep 2
ifup awg0           # endpoint now resolvable via the running DoH proxy
sleep 4
wifi reload

# Populate the bypass list.
/usr/bin/update-bypass-list
```

### 11. Verify

```sh
# AWG up and handshaking
awg show awg0
# expect "latest handshake: Xs ago" where X is small

# Default route in main table
ip -4 route show default
# expect: default dev awg0 proto static scope link
# plus    default via $wan_gw  ... metric 10
# plus    default via $wwan_gw ... metric 20

# Table 100 (split-VPN bypass)
ip -4 route show table 100
# with one WAN up:  default via $gw dev $dev
# with two WANs up: default
#                       nexthop via $w1 dev $d1 weight 1
#                       nexthop via $w2 dev $d2 weight 1

# Egress location
curl https://1.1.1.1/cdn-cgi/trace
# ip=<AWG server's egress IP>
# loc=<AWG exit country>

# Bypass-set populated
nft list set inet fw4 allow_domains_v4 | head -n 30
```

### 12. Disable password auth + remove LuCI

Only after verifying you can SSH in with the key.

```sh
# Drop LuCI / web stack.
apk del luci luci-base luci-light luci-mod-admin-full luci-mod-network \
        luci-mod-status luci-mod-system luci-proto-amneziawg luci-proto-ipv6 \
        luci-proto-ppp luci-ssl luci-theme-bootstrap luci-lib-uqr \
        luci-app-attendedsysupgrade luci-app-firewall luci-app-https-dns-proxy \
        luci-app-package-manager \
        uhttpd uhttpd-mod-ubus libustream-mbedtls \
        rpcd-mod-luci rpcd-mod-rrdns

# Disable password auth in dropbear.
uci set dropbear.@dropbear[0].PasswordAuth='off'
uci set dropbear.@dropbear[0].RootPasswordAuth='off'
uci commit dropbear
/etc/init.d/dropbear restart
```

After this the router has no web UI and no password fallback. SSH key auth is the only way in. If you lose your key, the path to recovery is TFTP-flash (step 1) — losing all state.

## Dual-WAN architecture

### Why no mwan3

mwan3 is the obvious tool for dual-WAN failover on OpenWrt, but it is **incompatible with the piwrt killswitch architecture** where AWG is the default route in the main routing table.

The mechanism of the conflict:

1. mwan3's `mangle_hook` (output) sets fwmark `0x200` (or similar, in range `0x3f00`) on every locally-originated packet.
2. mwan3's `ip rule pref 2002 from all fwmark 0x200/0x3f00 lookup 2` sends marked packets into mwan3's `table 2`.
3. mwan3's `table 2` contains its own `default via <gw>` route built from the active mwan3 members — which is wan or wwan directly, not awg0.
4. So every locally-originated packet from Hopper (including AWG's own outer UDP, our curl tests, NTP, apk, anything) skips the `default dev awg0` route in main table and exits straight out the WAN.

The symptom: `awg show awg0` reports a fresh handshake (because keepalive packets are riding the same WAN-bypass path that everything else does), `ip route get 1.1.1.1` says `dev awg0` (because route lookup without mark uses main table), but `curl https://1.1.1.1/cdn-cgi/trace` returns the operator's CGNAT IP and the AWG server's country is nowhere in sight. Tunnel up, tunnel unused.

The resolution: don't run mwan3. Use kernel-native ECMP via the hotplug script + ip-full, and let the AWG `default` route in main table sit on top of everything else. Failover is handled by `awg-watchdog` (every 2 minutes — bounces `awg0` if last handshake is older than 180 s). It's not as fast as mwan3's ping-based failover (~15 s), but with this architecture mwan3's faster failover never actually translated into a working tunnel.

### "WAN group" abstraction

The firewall zone `wan` lists both `wan` and `wwan` (plus `wan6`), so any rule referring to the `wan` zone — like `SSH-WAN` or `Split-VPN-bypass` — automatically applies to both. Adding a third WAN (a second SIM modem, a backup ethernet, etc.) means a single `list network 'wan3'` addition and adding the iface to `WAN_IFACES` in the hotplug script. No mangle rules, no policy table maintenance.

### Table 100 ECMP

`/etc/hotplug.d/iface/90-split-vpn` runs on every iface up/down event and rebuilds table 100 from scratch:

- **0 WANs up** — table flushed, no leak.
- **1 WAN up** — `ip route add default via $gw dev $dev table 100`. Single nexthop.
- **2+ WANs up** — `ip route add table 100 default nexthop via $w1 dev $d1 weight 1 nexthop via $w2 dev $d2 weight 1`. Per-flow hash distribution.

The Russian-DNS resolver (`77.88.8.8` Yandex) is pinned alongside in main table with the same ECMP shape so dnsmasq's lookups for bypass domains don't accidentally leak through the AWG tunnel.

**Critical gotcha: BusyBox `ip` does not support multipath.** OpenWrt's default `ip` is a BusyBox applet (`/sbin/ip -> /bin/busybox`). It silently rejects the `nexthop via X dev Y weight N` syntax with `"either to is duplicate, or nexthop is garbage"`. The 2-WAN branch then no-ops. **`apk add ip-full`** installs the real iproute2 (`/sbin/ip -> /usr/libexec/ip-full`) which actually implements multipath. `post-upgrade.sh` ensures this on every boot.

Additional iproute2-full quirk: the `table N` argument must come **before** the nexthop chain. `ip route add default nexthop ... nexthop ... table 100` fails with `'nexthop' or end of line is expected instead of 'table'`. Correct order: `ip route add table 100 default nexthop ... nexthop ...`. The hotplug script writes it correctly; if you reorder, expect breakage.

### AWG endpoint pinning

The AWG netifd handler installs a specific route to the AWG endpoint IP (resolved at `ifup awg0` time) via whatever gateway main table picks for that destination. With `wan metric 10` and `wwan metric 20` defaults both present, that's the wan gateway. When wan drops, the endpoint route also disappears (its gateway is unreachable), the AWG tunnel can't send keepalives, the handshake goes stale, `awg-watchdog` notices after up to 2 minutes and re-runs `ifdown awg0 && ifup awg0`. The new `ifup` re-resolves the endpoint via the now-active `wwan` gateway and rebuilds the route.

Endpoint cannot be ECMP'd safely. WireGuard supports endpoint roaming on the server side — if it receives a packet from a new source IP, it updates the peer record to point at the new IP. If outer UDP packets are ECMP-distributed across two WANs, they leave via two different source IPs and the server gets confused: half its replies land on the wrong WAN. Pin the outer path.

## Mobile-specific quirks

### TTL=65 rationale

Covered briefly in the hardware-caveats section; in full detail with measurements:

```sh
# Local kernel default on Hopper for ICMP echo
sysctl net.ipv4.ip_default_ttl
# net.ipv4.ip_default_ttl = 64

# Verify the egress TTL on the wire
tcpdump -n -i eth1 -v icmp &
ping -c 3 -W 2 -I eth1 1.1.1.1
# > 192.168.8.X > 1.1.1.1: ICMP echo request, ttl 65, ...
# < 1.1.1.1 > 192.168.8.X: ICMP echo reply, ttl 50, ...
```

The ICMP echo request leaving Hopper carries `ttl=65` because of the `mangle_postrouting_mobile` chain. The modem decrements to 64 before forwarding to LTE. Cloudflare receives `ttl=64` and replies with its own default 64; by the time the reply gets back through 14 cellular hops it's `ttl=50`. That's the working confirmation that:

- Our egress is set correctly,
- The modem decrements (otherwise the operator would see 65, also tethering-suspect),
- The reply path is alive (so the rule isn't accidentally dropping anything).

### What firmware does the modem run

The HiLink web API (`http://192.168.8.1/api/device/information`) reports `SoftwareVersion: 10.0.5.1(H195SP3C983)`. The `C983` customer code is **not** China-specific despite high numbering — the author originally guessed it was, then the modem registered on MegaFon RU with a real `100.94.x.x` CGNAT IP and IPv6 (`2a03:d000::/32`, MegaFon's allocation). Cyrillic stickers inside the chassis are a much more reliable signal of regional intent than firmware customer-code heuristics.

OpenWrt cannot upgrade Huawei modem firmware. The HiLink web UI has a FOTA stub but Huawei pulled the update servers for the -320 H195 line. If a newer firmware is wanted, it's a Windows-only flash via Mobile Partner / Hi-Link Update Wizard, with the modem detached from the OpenWrt host.

### Why not stick mode

Stick mode (NCM/PPP) would give AT-command access from OpenWrt — band lock, cell lock, USSD, direct signal info to the router. On older E3372 variants (the -153) the conversion is well-trod: usb-modeswitch with a specific transport string, plus a firmware upload via balong-usbdload.

On the -320 (Balong 711 chipset), this **does not work**. The bootloader is signed; balong-usbdload either fails to enter download mode or bricks the device. The community-maintained tracking thread on the OpenWrt forum has the original poster giving up and going back to HiLink. There are no reliable success reports.

The features we lose by staying in HiLink:

- No band lock — can't pin to LTE Band 7 / 20 / 3 for stability in a known-good coverage area.
- No cell lock (PCI / TAC) — can't avoid an oversold tower.
- No USSD — service codes (`*100#` etc.) only via the modem's own web UI.
- No SMS — same.
- Double NAT — modem at `192.168.8.1` NATs us onto its LTE WAN. Hopper sees a private IP, not the cellular public IP.

For a backup-only / failover use case, none of these matter enough to risk a bricked modem.

## SSH hardening

### Why disable password auth

Dropbear out of the box on OpenWrt accepts an empty root password during initial setup, then any password matching `/etc/shadow`. The shadow file is part of `sysupgrade.conf`'s default keep list, so a previously-set password survives upgrades — but it's also brute-forceable from the WAN side if `SSH-WAN` is open (and we want it open). The only safe configuration is **no password auth at all**, key-only.

`uci set dropbear.@dropbear[0].PasswordAuth='off'` and `uci set ... RootPasswordAuth='off'` accomplish that. The shadow file becomes irrelevant for SSH; even an empty password no longer grants access.

The only risk is locking yourself out by disabling password auth before verifying a working key. Mitigation:

1. Add your primary key first.
2. Test from a separate session: `ssh -o PasswordAuthentication=no root@router 'echo ok'`. If it greets you, you're safe.
3. Add a secondary fallback key (e.g. a deployment-tooling key) so a single lost key doesn't lock you out.
4. Only then flip password auth off.

### Exposing SSH on the WAN

The `SSH-WAN` firewall rule (in `configs/firewall`) allows `tcp/22` from the `wan` firewall zone. Since the zone includes both ethernet wan and the LTE wwan, this technically exposes 22 on both interfaces. In practice:

- **Ethernet wan**: SSH is reachable from anything on the upstream network. If the upstream is a home LAN behind your own router, this is fine. If the upstream is a hostile network, lock the rule down with a source IP whitelist.
- **LTE wwan**: SSH is technically listening on the modem-side IP, but the modem is at `192.168.8.X` private from OpenWrt's perspective and behind operator CGNAT from the public internet. There's no inbound path. To make the modem-side reachable, run Tailscale on the Hopper or a reverse SSH tunnel — neither is in scope of this README.

### LuCI removal

LuCI is OpenWrt's web admin UI. We're admin-by-SSH-only, so it's dead weight: 24 packages (luci-base, luci-mod-*, luci-app-*, rpcd-mod-luci, themes, lib-uqr, ...) plus `uhttpd` and `uhttpd-mod-ubus` and `libustream-mbedtls`. Removing them frees about 5 MiB of squashfs overlay and silences a network service nobody talks to. The dependency `rpcd` (without the LuCI module) stays — it backs ubus, which other things use.

Removal command in step 12 of the walkthrough above. `post-upgrade.sh` does **not** re-install any of these on sysupgrade — the comments in the script call out the omission explicitly.

## Track changes to /etc

OpenWrt has no native `etckeeper` (a [package was requested in 2019](https://forum.openwrt.org/t/etckeeper-requesting-help-with-building-an-openwrt-package/28283), never landed). The Hopper uses the same lightweight cron-based approach as the Pi:

```sh
apk add git
cd /etc
git config --global user.email 'piwrt-etc@hopper.local'
git config --global user.name  'piwrt-etc'
git config --global commit.gpgsign false
cat > .gitignore <<'EOF'
# Secrets — root can read these on the box, but we still avoid baking
# them into commit history that might leak via backup/export.
shadow*
gshadow*
dropbear/dropbear_*_host_key
ssl/private/

# Volatile / generated
hosts.dnsmasq
resolv.conf
board.json
mtab

# OpenWrt apk DB working state
apk/.lock
apk/cache/

# Backup files
*.bak
*.orig
*~
EOF
git init --initial-branch=master
git add -A
git commit -m "initial commit on Hopper $(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

The `etc-autocommit` cron job (in `scripts/`) runs hourly and commits any drift with a UTC timestamp message. `cd /etc && git log` answers "what changed yesterday at 03:00".

`/etc/.git/` and `/etc/.gitignore` are added to `sysupgrade.conf` so history survives upgrades.

The cron-based approach loses the precise ordering that etckeeper's package-manager hooks would give you (commit-before-install / commit-after-install), but on OpenWrt there's no good way to hook apk events anyway — apk has only per-package post-install scripts, not a global hook like dpkg.

## Sysupgrade resilience

OpenWrt sysupgrade preserves `/etc/config/*` and whatever's in `/etc/sysupgrade.conf`. Everything else — including all custom-installed packages — gets wiped. `/usr/share/piwrt/post-upgrade.sh` re-installs them on every boot, idempotently:

```sh
log "ensuring modem packages"
apk add usb-modeswitch kmod-usb-net-cdc-ether kmod-usb-net-rndis ...

log "ensuring ip-full (multipath route support)"
apk add ip-full

if ! apk list --installed | grep -q '^dnsmasq-full '; then
    apk del dnsmasq
    apk add dnsmasq-full
fi

log "ensuring https-dns-proxy"
apk add https-dns-proxy

if ! awg --version >/dev/null 2>&1; then
    log "AWG missing, installing"
    # ... AWG kmod / tools fetch + apk add --allow-untrusted ...
fi

# Patch dnsmasq init (idempotent — sed only acts if pattern matches).
sed -i 's|--user=dnsmasq|--user=root|' /etc/init.d/dnsmasq

# Regenerate bypass list if missing.
[ ! -s /etc/dnsmasq.d/allow-domains.conf ] && /usr/bin/update-bypass-list

# Restart services in dependency order.
```

The script is invoked from `/etc/rc.local` on every boot (backgrounded so boot isn't held up). In the steady state — every reboot after the first — apk metadata reads ~1 second of CPU and apk-add steps are no-ops because packages are already installed. On the first boot after sysupgrade, the script takes 30–90 seconds to download the AWG kmod and run the patches.

### wait_for_wan — why ping + DNS

The script can't `apk update` until both the WAN has a route AND DNS works. Pure ping-only check fires too early — wan is up at the link / route layer well before dnsmasq + https-dns-proxy are ready to resolve `downloads.openwrt.org`. The actual condition:

```sh
wait_for_wan() {
    for _ in $(seq 1 60); do
        if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 \
           && nslookup downloads.openwrt.org >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}
```

Both checks must pass before the rest of the script proceeds.

## Watchdogs

- **`awg-watchdog`** — runs every 2 minutes from cron. Reads `awg show awg0 latest-handshakes`, checks how long ago the last handshake was. If older than 180 s (twice the keepalive interval), it bounces `awg0` with `ifdown` + `ifup`. This also serves as the dual-WAN failover trigger: when wan dies and the endpoint route becomes unreachable, handshakes stop, watchdog notices within 2 minutes, the bounce re-resolves the endpoint via the still-up wwan.
- **`wifi-watchdog`** — runs every 5 minutes. Checks that both `phy0-ap0` and `phy1-ap0` exist via `iw dev`. If either is missing, `wifi up`. If that doesn't help, `rmmod mt7915e && modprobe mt7915e && wifi up`. The 90-second uptime skip avoids fighting netifd during boot.

Both skip the first 90 seconds of uptime — NTP needs to bring system time into sync before the AWG handshake age can be evaluated, and netifd is still racing during early boot.

## Operations

```sh
# Egress sanity check (should match AWG server country)
curl -s https://1.1.1.1/cdn-cgi/trace | grep -E '^(ip|loc|colo)='

# AWG tunnel status (handshake age + counters)
awg show awg0

# Routing tables
ip -4 route show default               # main table — awg0 + WAN fallbacks
ip -4 route show table 100             # split-VPN bypass — ECMP or single

# WAN states
ifstatus wan  | jsonfilter -e '@.up'
ifstatus wwan | jsonfilter -e '@.up'

# nftables sets (populated by dnsmasq from bypass list)
nft list set inet fw4 allow_domains_v4 | head -n 30

# Refresh the bypass list on demand (cron does this weekly anyway)
/usr/bin/update-bypass-list

# TTL on the wire — confirm 65 on egress to modem
tcpdump -n -i eth1 -v 'icmp' -c 3 &
ping -c 3 -I eth1 1.1.1.1

# Modem signal / operator (HiLink XML API)
wget -qO- http://192.168.8.1/api/device/signal
wget -qO- http://192.168.8.1/api/net/current-plmn

# Last commits to /etc
cd /etc && git log --oneline -n 20
```

## License

Same as the parent repo. See top-level `LICENSE` if present; otherwise the contents are released as-is with no warranty.
