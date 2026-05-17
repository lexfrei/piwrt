# piwrt on CWWK N305

CWWK 4-port appliance (Intel Core i3-N305 + 2× SFP+ 10G via Intel 82599ES + 2× 2.5GbE via Intel i226-V, external 12V brick, one M.2 PCIe slot used for the NVMe boot device) running OpenWrt 25.12.4 as a headless gateway that tunnels all client traffic through an AmneziaWG v2 VPN. Same architecture as the Pi and Hopper setups — kill-switch-by-default routing, domain-based split-tunnel bypass for Russian services so their anti-fraud doesn't trip on a foreign exit IP, DoH upstream, no LuCI, SSH-key-only admin. Adapted for x86_64 silicon and a wired-only WAN profile (no LTE backup on this hardware).

The CWWK box is positioned as the actual L3 gateway. Downstream is a UniFi UDR7 that operates as an AP + UniFi controller (in the standard UniFi "AP-mode workaround": dummy WAN on an isolated VLAN, all networks marked `VLAN only`, gateway IP repointed at this CWWK). A USW Flex Mini sits in the LAN segment as a downstream switch when needed. The CWWK itself has no Wi-Fi — radio coverage comes from the UniFi AP.

## Architecture

```text
[home ISP] ── wan  (DHCP, metric 10) ────┐
                                          │
                                          ├── awg0 (AmneziaWG v2)  ── lan forward (kill switch)
                                          │
                                          └── table 100 (fwmark 0x100)
                                              single-nexthop default by default;
                                              ECMP across up-WANs when WAN_IFACES
                                              lists more than one entry

[downstream UDR7 / Flex Mini / clients] ── br-lan (trunk port + spares) ── 192.168.1.0/24
                                                                          (optional VLAN subnets
                                                                           layered on top of trunk)
```

Three traffic classes:

- **All LAN client traffic** is forwarded through `awg0` (no `lan → wan` rule exists, only `lan → awg`). If the tunnel is down, clients lose internet entirely — that's the kill switch.
- **Split-VPN bypass** (Russian domain list) is marked `fwmark 0x100` by an nftables prerouting hook and routed through table 100. When the box has a single WAN, table 100 holds a regular `default via <gw>` route to that WAN. When multiple WANs are listed in `WAN_IFACES`, table 100 becomes an ECMP multipath default and bypass traffic is hashed per-flow across all up uplinks.
- **AWG outer UDP** (the encrypted handshake / data stream to the AWG server) is sent to a specific endpoint route installed by the netifd AWG handler. It rides the lowest-metric WAN. Failover via `awg-watchdog` re-bringing up `awg0` after a stale handshake — single-path by design because WireGuard's endpoint roaming makes ECMP on the outer path unreliable.

## Scope, explicitly

Does exactly one thing: receive internet over ethernet, present a LAN trunk to the downstream UniFi cluster, shove client traffic through a VPN tunnel. No LuCI, no web UI, no `mwan3` policy routing, no IDS, no AdGuard Home, no Samba, no Wi-Fi (UDR7 handles that downstream). Headless SSH-only admin via key auth from the WAN side.

If you want any of those, add them on top and keep your own branch — the README won't guide you there.

## Hardware caveats

### CWWK N305 / 82599ES SFP+

- **Intel 82599ES is the SFP+ chip on this design** (per the STH review). Old but rock-solid — same Niantic silicon datacenters ran for a decade. Linux `ixgbe` driver, well-supported in any recent kernel.
- **If you plug in non-Intel SFP+ modules** and see `unsupported SFP+ module type` in `dmesg` with the port refusing to come up: the chip itself accepts any module electrically, but the `ixgbe` driver gates them through a vendor allowlist. Override with `/etc/modules.d/30-ixgbe` containing `ixgbe allow_unsupported_sfp=1,1` (two `1`s for two ports — one value per ixgbe instance, both PCI functions of the 82599ES). Most Intel-coded DACs and FS.com/10gtek modules with Intel vendor strings load without this. Don't set it preemptively — it's a no-op when the ports are empty, and only matters when a specific non-Intel module surfaces an error.

- **82599ES is power-hungry and warm**. ~6 W per chip TDP, no fan on the stock chassis — the SFP+ cage gets noticeably hot under sustained load. Not a defect, just physics. Make sure the thermal pad from the chip to the case is intact when reassembling.

### Intel i226-V

- **Linux kernel 6.8+ has all the i226 EEE / TSN fixes**. OpenWrt 25.12.4 ships kernel 6.12.87, so the historical advice to disable EEE on these NICs is no longer required. Leave defaults.
- **Port naming**: `igc` driver. Combined with `ixgbe` SFP+, expect either `eth0..eth3` (kernel-ordered) or `enp1s0` / `enp2s0` / ... (predictable-name scheme depending on udev rules in the OpenWrt image). Identify which physical port maps to which interface name after the first boot:

  ```sh
  for i in /sys/class/net/eth*; do
      [ -d "$i" ] || continue
      iface=$(basename "$i")
      drv=$(ethtool --driver "$iface" 2>/dev/null | awk '/^driver:/ {print $2}')
      echo "$iface  $drv"
  done
  # ixgbe = SFP+ ports
  # igc   = 2.5G RJ45 ports
  ```

### M.2 slot

The board has an M.2 slot in 2280 form factor (some SKUs may also accept 2230 form-factor cards via additional standoff). It is a **regular PCIe M.2**, not CNVi — confirmed empirically by booting OpenWrt from a WD Green SN350 NVMe SSD installed there. Earlier revisions of CWWK marketing material describe a "Wi-Fi slot", but on this 2×SFP+ N305 board the slot enumerates standard NVMe devices without quirk. PCIe x2 lane width on this design (not x4), so peak read tops out around 1.6 GB/s — irrelevant for a router, take a different board for NAS-class storage.

Wi-Fi is not provisioned in this setup regardless of what the slot can take — radio coverage comes from a downstream UniFi AP, not from a card on this board.

### PSU

- **12 V brick**, typically 5 A / 60 W stock. Under load (N305 + both SFP+ + USB) the box pulls 35–40 W, leaves only marginal headroom. If you find the supplied PSU unreliable, replace with a 12V / 6 A barrel-jack adapter (5.5×2.5 mm tip on the CWWK chassis). Voltage tolerance is reasonable; the connector is the more common failure point than the brick itself.

### Fan / acoustic noise — no Linux-side PWM path

The chassis ships with proprietary 3-pin DC fans (chassis fan + a separate small SFP-cage fan in some SKUs). Bladewheels are screwed directly into the heatsink — no standard 40×40 frame, so axial-fan drop-in replacements need a 3D-printed adapter. Stock fans run at fixed full speed and are the dominant source of acoustic noise on this box.

**SuperIO is not reachable from Linux** on this design. The empirical findings:

- `it87` and `nct6775` kernel modules fail probe even with `acpi_enforce_resources=lax` on the kernel cmdline and brute-force scans across the usual `force_id` values (`0x8625, 0x8628, 0x8665, 0x8688, 0x8686, 0x8728, 0x8772, 0x8623, 0x8613, 0x8716, 0x8718, 0x8720, 0x8607, 0x8771`). The chip is either at a non-standard LPC port or not in either driver's supported list.
- ACPI exposes 5 `cooling_device*` entries of `type=Fan` with `max_state=1` — binary on/off only, no PWM duty cycle surface. All read `cur_state=0` even while the physical fan spins at full speed, confirming the fan is driven by BIOS / EC out-of-band, not by anything Linux can intercept.
- DMI returns `"Default string"` for manufacturer/board, so board-specific quirks lookup is impossible.

There is no programmatic path to throttle or stop the fan from inside OpenWrt. The kernel cmdline parameter is reverted in this setup — leaving `acpi_enforce_resources=lax` on without a working driver only loosens ACPI resource enforcement for no benefit.

**Empirical thermal headroom** — `stress-ng --cpu 8 --vm 1 --vm-bytes 256M --timeout 300s` against N305 with the stock fan running, package and core temps as measured via `coretemp`:

```text
idle        30 °C
min 1       64 °C
min 2       62 °C
min 3       64 °C
min 4       67 °C   ← steady-state peak under 100% × 8 threads
cooldown    35 °C after 30 s
```

TjMAX on N305 is 105 °C, throttling begins ~95-100 °C. With fan on, ~38 °C headroom. The N305 is a 15 W TDP part in an all-aluminum chassis with a heatsink mass that absorbs sustained 100% × 8-thread CPU load just fine — STH's review of this exact SKU explicitly labels it "fanless", which lines up with the measurements. Stock fans exist as a safety margin for sustained 10G symmetric NAT loads, not for typical router workloads.

**Practical paths to reduce noise** (none require Linux work):

1. **Physical disconnect.** Unplug the JST MX 1.25 fan connector from the board. Project router workload (1–10% CPU average, AWG tunnel) settles around 50–60 °C package with passive cooling alone — well below throttle. If the chassis has a separate SFP-cage fan and 10G is in use, leave that one connected (82599ES has ~6 W TDP and benefits from active airflow under symmetric 10G NAT); disconnect only the main chassis fan.
2. **Voltage drop hack.** Two 1N4007 diodes in series in the +12 V wire of the fan drop ~1.4 V, fan sees ~10.6 V instead of 12 V, RPM (and noise) drops measurably. Cheapest no-tooling option.
3. **PWM-to-DC converter** (e.g. **Noctua NA-FC1**, ~$20). Requires the board header to actually be 4-pin PWM (CWWK marketing says "JST MX 1.25 4-pin"; verify physically by counting pins) AND BIOS Smart Fan switched from `DC mode` to `PWM mode`. Converter reads PWM duty from the board, low-pass-filters it through an internal MOSFET regulator, outputs proportional 0-12 V to the existing 3-pin fan. Tach passes through. JST MX 1.25 ↔ standard-4-pin and standard-3-pin ↔ JST MX 1.25 adapters needed on both sides (AliExpress, ~$3 each).
4. **Standalone thermistor-driven controller** (~$5-10, AliExpress search `automatic temperature fan speed controller`). NTC 10k on the heatsink, board reads it, drives fan voltage on its own curve. Independent of the motherboard entirely — useful if the header turns out to be physically 3-pin (no PWM signal source). Will likely keep the fan stopped under typical router workload, spin it up only under sustained load.
5. **Heatsink-only / quieter fan swap** via a community-designed 3D-printed adapter. The Thingiverse model `topton/cwwk fan replacement for heatsink` is the closest published precedent, but it targets a different CWWK SKU; this 2×SFP+ board may need a custom design.

Recommendation for this build: disconnect the chassis fan, keep SFP fan only if 10G is in use. The thermal numbers above support this. Re-evaluate if planning sustained 10G symmetric workloads.

## Prerequisites

- A CWWK N305 4-port appliance (or any of the rebrand SKUs sold under Topton / Kingnovy / etc. with identical board layout — Intel 82599ES SFP+ + i226-V 2.5GbE pairing).
- An M.2 2280 NVMe (any size ≥ 16 GB; smaller is fine — OpenWrt's overlay grows on demand into the unallocated tail). A USB-NVMe adapter for flashing the image off the appliance, OR a spare Linux liveUSB to flash in-place.
- A wired ISP uplink (router / switch with DHCP) for the appliance's WAN port.
- The AmneziaWG v2 server config file from your provider — `.conf` with `[Interface]` (PrivateKey, Address, MTU, Jc, Jmin, Jmax, S1..S4, H1..H4) and `[Peer]` (PublicKey, Endpoint, AllowedIPs, PersistentKeepalive).
- (Optional) A UniFi UDR7 + USW Flex Mini if you want the downstream Wi-Fi + L2 split described in this README's positioning. Without them, plug any switch / AP cluster you prefer into the trunk port.

## Installation walkthrough

### 1. Flash OpenWrt 25.12.4 to the NVMe

OpenWrt for x86_64 ships a `combined-efi.img.gz` image that contains a GPT, an EFI System Partition with GRUB, and a squashfs rootfs — written via `dd` to the raw block device. Two ways to get it onto the NVMe:

**Option A — USB-NVMe adapter on a separate host** (easiest):

```sh
# Download + verify on the helper host (Linux or macOS).
curl --silent --location --remote-name \
    https://downloads.openwrt.org/releases/25.12.4/targets/x86/64/openwrt-25.12.4-x86-64-generic-squashfs-combined-efi.img.gz
echo '013d5f6df2d33c9ca75c5059a0fe759cca0271572006c02ea877299966e1dff6  openwrt-25.12.4-x86-64-generic-squashfs-combined-efi.img.gz' | sha256sum --check

# Identify the NVMe via diskutil (macOS) or lsblk (Linux). Triple-check
# you've got the right device — dd is unforgiving.
diskutil list external physical                  # macOS
# OR
lsblk --output NAME,SIZE,TRAN,MODEL              # Linux

# Unmount (not eject — eject disconnects the device entirely on macOS).
diskutil unmountDisk /dev/diskN                  # macOS
# OR
sudo umount /dev/sdX*                            # Linux

# Write — use the raw device on macOS (/dev/rdiskN), faster by an order
# of magnitude. On Linux /dev/sdX directly.
gunzip --stdout openwrt-25.12.4-x86-64-generic-squashfs-combined-efi.img.gz \
    | sudo dd of=/dev/rdiskN bs=4m conv=fsync status=progress     # macOS
# OR
gunzip --stdout openwrt-25.12.4-x86-64-generic-squashfs-combined-efi.img.gz \
    | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress         # Linux

diskutil eject /dev/diskN                        # macOS, after dd
```

**Option B — liveUSB on the appliance itself**: boot Alpine / Ubuntu / OpenWrt-installer from a USB stick, attach the NVMe internally, run the same `dd` from the live environment. Slower but no adapter needed.

After `dd`, the NVMe has two partitions visible (`disk2s1` 67 MB FAT32 boot, `disk2s2` 109 MB Linux rootfs squashfs) and ~99% of the device unallocated. Overlay grows into the tail on first mount.

### 2. BIOS / UEFI settings

Press the BIOS hotkey at boot (typically `Del` or `F2`). Set:

- **Boot mode** = UEFI only. Disable CSM / Legacy boot.
- **Secure Boot** = Disabled. OpenWrt's bootloader is not signed by a Microsoft-trusted CA.
- **Above 4G Decoding** = Enabled. Lets PCIe BARs map cleanly; some 82599ES revisions silently fail without it.
- **ASPM** = Disabled on the 82599ES root port. Recurring packet-loss reports on idle traffic when ASPM is on. The setting may be exposed as "PCH PCIe ASPM" or per-slot; safe default is "Disabled" for all slots if you can't tell.
- **CPU C-states** = leave on. The N305 in idle drops to ~7 W with C-states active; off, it sits at ~15 W for no benefit.
- **Restore on AC Power Loss** = Power On. So a power blip doesn't leave the gateway down until you press a button.
- **Boot order** — NVMe first.

Save, reboot. The first boot brings up OpenWrt on `192.168.1.1/24`. The bridge starts as br-lan over all physical ethernet ports (default), so you can plug a laptop into any non-SFP+ port for initial access — DHCP will hand you an address.

### 3. First-boot bootstrap: SSH key + password

```sh
ssh -o PreferredAuthentications=password -o StrictHostKeyChecking=no root@192.168.1.1
# (press enter on the password prompt — empty by default)
```

Add your SSH pubkey (YubiKey-backed or whatever you trust) so you can disable password auth in a later step:

```sh
mkdir -p /etc/dropbear
cat > /etc/dropbear/authorized_keys <<'EOF'
ssh-ed25519 AAAA... your-pubkey-here
EOF
chmod 600 /etc/dropbear/authorized_keys
```

Set a root password as a fallback if you want it (optional — if you're confident in the key, leave it empty and the password-auth disable in step 11 makes the shadow file irrelevant anyway):

```sh
passwd
```

### 4. Identify physical port → interface mapping

Run on the appliance:

```sh
for i in /sys/class/net/eth*; do
    [ -d "$i" ] || continue
    iface=$(basename "$i")
    drv=$(ethtool --driver "$iface" 2>/dev/null | awk '/^driver:/ {print $2}')
    speed=$(cat "$i/speed" 2>/dev/null || echo "unknown")
    echo "$iface  driver=$drv  speed=${speed}Mb/s"
done
```

You'll get something like:

```text
eth0  driver=ixgbe  speed=10000Mb/s    # SFP+ port 1
eth1  driver=ixgbe  speed=10000Mb/s    # SFP+ port 2
eth2  driver=igc    speed=2500Mb/s     # 2.5G RJ45 #1
eth3  driver=igc    speed=2500Mb/s     # 2.5G RJ45 #2
```

Note which physical port (looking at the chassis face) corresponds to each `eth*` — unplug cables one at a time and watch `ip link show` for `state DOWN` to ground-truth the mapping. Decide which port is `<WAN_PORT>` (facing the ISP) and which is `<TRUNK_PORT>` (facing the UDR7 / downstream switch). Suggested role assignment in `configs/network.example` is a starting point, not a requirement.

### 5. AmneziaWG packages

OpenWrt 25.12.4 ships kernel 6.12.87. Slava-Shchipunov maintains pre-built AWG packages for both aarch64 and x86_64 targets; for our box the ARCH string is `x86_64`, and the published artefact filenames carry it twice (e.g. `kmod-amneziawg_v25.12.4_x86_64_x86_64.apk`). Verify before downloading:

```sh
curl --silent --location 'https://api.github.com/repos/Slava-Shchipunov/awg-openwrt/releases/tags/v25.12.4' \
    | grep --extended-regexp '"name":\s*"(kmod-amneziawg|amneziawg-tools|luci-proto-amneziawg)_v25\.12\.4_x86_64'
```

If those three lines show up, you're set. If they don't, fall back to v25.12.3 (kernel 6.12.85, last known-good AWG-published OpenWrt minor on this branch) — `post-upgrade.sh` has `VERSION` as a top-of-file constant, change one line.

```sh
VERSION="v25.12.4"
ARCH="x86_64"
URL="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/${VERSION}"

# Deps from the base feed (apk doesn't auto-resolve transitive deps
# of locally-installed .apk files).
apk add kmod-udptunnel4 kmod-udptunnel6 \
        kmod-crypto-lib-chacha20poly1305 kmod-crypto-lib-curve25519

# Then the three AWG packages.
for pkg in kmod-amneziawg amneziawg-tools luci-proto-amneziawg; do
    f="${pkg}_${VERSION}_${ARCH}_${ARCH}.apk"
    wget -q -O "/tmp/${f}" "${URL}/${f}"
done
apk add --allow-untrusted \
    /tmp/kmod-amneziawg_*.apk \
    /tmp/amneziawg-tools_*.apk \
    /tmp/luci-proto-amneziawg_*.apk

modprobe amneziawg
awg --version
```

`luci-proto-amneziawg` is installed but then immediately removed in step 11 (LuCI removal) — it's only needed transiently to register the proto handler with netifd. The kernel module + userspace tools stay.

### 6. DNS, full-iproute2, watchdog packages

```sh
# Base dnsmasq lacks nftset support — replace with dnsmasq-full.
apk del dnsmasq
apk add dnsmasq-full

# DoH proxy.
apk add https-dns-proxy

# Full iproute2 — BusyBox ip applet does NOT implement multipath syntax,
# so the ECMP route in /etc/hotplug.d/iface/90-split-vpn silently produces
# an empty table 100 without this.
apk add ip-full

# Optional but recommended: /etc git tracking.
apk add git

# Diagnostic tools.
apk add tcpdump-mini ethtool

# Traffic accounting.
apk add vnstat2
```

### 7. Drop in the configs

All of these are templates. Replace `<PLACEHOLDER>` slots from your AWG `.conf` and decide on port names / VLAN IDs:

```sh
cp configs/network.example  /etc/config/network
$EDITOR /etc/config/network  # <WAN_PORT>, <TRUNK_PORT>, AWG keys, Jc/Jmin/etc.

cp configs/firewall          /etc/config/firewall
cp configs/dhcp              /etc/config/dhcp
cp configs/https-dns-proxy   /etc/config/https-dns-proxy
cp configs/dropbear.example  /etc/config/dropbear

# nftables files (auto-included by fw4 from /etc/nftables.d/)
mkdir -p /etc/nftables.d
cp configs/nftables/50-allow-domains.nft /etc/nftables.d/

# IMPORTANT: configs/https-dns-proxy uses `resolver_url
# 'https://1.1.1.1/dns-query'` (IP literal, not the hostname
# 'cloudflare-dns.com'). Documented for the Hopper LTE-CGNAT scenario;
# the IP-literal form is strictly more robust and worth keeping here
# even though wired ISPs typically don't block plain DNS.

# Hotplug script (split-VPN router).
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

`post-upgrade.sh` re-applies this on every boot if a sysupgrade resets the init script.

### 9. Drop in the scripts + crontab

```sh
mkdir -p /usr/share/piwrt
cp scripts/post-upgrade.sh /usr/share/piwrt/post-upgrade.sh
chmod +x /usr/share/piwrt/post-upgrade.sh

for s in awg-watchdog update-bypass-list.sh etc-autocommit; do
    cp scripts/$s /usr/bin/${s%.sh}
    chmod +x /usr/bin/${s%.sh}
done

# rc.local hook — calls post-upgrade.sh on every boot (idempotent).
# Insert before the final `exit 0`. See configs/rc.local.append.
$EDITOR /etc/rc.local

# Crontab — watchdog + weekly bypass-list refresh + hourly autocommit.
cat >> /etc/crontabs/root <<'EOF'
*/2 * * * * /usr/bin/awg-watchdog
0 6 * * 0   /usr/bin/update-bypass-list
30 * * * *  /usr/bin/etc-autocommit
EOF
/etc/init.d/cron enable
/etc/init.d/cron restart
```

No wifi-watchdog — there's no on-board Wi-Fi to watch.

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

# Populate the bypass list.
/usr/bin/update-bypass-list
```

### 11. Verify

```sh
# AWG up and handshaking.
awg show awg0
# expect "latest handshake: Xs ago" where X is small.

# Default route in main table.
ip -4 route show default
# expect:  default dev awg0 proto static scope link
# plus     default via $wan_gw  ... metric 10

# Table 100 (split-VPN bypass).
ip -4 route show table 100
# single-WAN default:  default via $gw dev $dev

# Egress location — should match the AWG server country, not your ISP.
curl https://1.1.1.1/cdn-cgi/trace

# Bypass-set populated.
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

After this the router has no web UI and no password fallback. SSH key auth is the only way in. If you lose your key, recovery is "reflash NVMe via the same `dd` procedure" — losing all state.

## Dual-WAN, if and when

The hotplug script defaults to `WAN_IFACES='wan'`. If you add a second uplink (a backup ISP, a 5G hotspot via tethered ethernet, a second wired line on a different physical port), the additions are:

1. `/etc/config/network` — add the second WAN interface with a higher metric (e.g. `metric '20'`).
2. `/etc/config/firewall` — `list network 'wan2'` under the existing `wan` zone (or add a new zone if you want different forward semantics).
3. `/etc/hotplug.d/iface/90-split-vpn` — append the new interface name to `WAN_IFACES`. Restart `/etc/init.d/firewall` and bounce the new interface to trigger the hotplug rebuild.

ECMP across multiple WANs uses kernel-native multipath — no `mwan3`, by design (see "Why no mwan3" below).

### Why no mwan3

mwan3 is the obvious tool for dual-WAN failover on OpenWrt, but it is **incompatible with the piwrt killswitch architecture** where AWG is the default route in the main routing table.

The mechanism of the conflict:

1. mwan3's `mangle_hook` (output) sets fwmark `0x200` (or similar, in range `0x3f00`) on every locally-originated packet.
2. mwan3's `ip rule pref 2002 from all fwmark 0x200/0x3f00 lookup 2` sends marked packets into mwan3's `table 2`.
3. mwan3's `table 2` contains its own `default via <gw>` route built from the active mwan3 members — which is wan or wan2 directly, not awg0.
4. So every locally-originated packet from the router (including AWG's own outer UDP, our curl tests, NTP, apk, anything) skips the `default dev awg0` route in main table and exits straight out the WAN.

The symptom: `awg show awg0` reports a fresh handshake (because keepalive packets are riding the same WAN-bypass path that everything else does), `ip route get 1.1.1.1` says `dev awg0` (because route lookup without mark uses main table), but `curl https://1.1.1.1/cdn-cgi/trace` returns the operator's IP and the AWG server's country is nowhere in sight. Tunnel up, tunnel unused.

The resolution: don't run mwan3. Use kernel-native ECMP via the hotplug script + ip-full, and let the AWG `default` route in main table sit on top of everything else. Failover is handled by `awg-watchdog` (every 2 minutes — bounces `awg0` if last handshake is older than 180 s).

### Table 100 ECMP

`/etc/hotplug.d/iface/90-split-vpn` runs on every iface up/down event and rebuilds table 100 from scratch:

- **0 WANs up** — table flushed, no leak.
- **1 WAN up** — `ip route add default via $gw dev $dev table 100`. Single nexthop.
- **2+ WANs up** — `ip route add table 100 default nexthop via $w1 dev $d1 weight 1 nexthop via $w2 dev $d2 weight 1`. Per-flow hash distribution.

The Russian-DNS resolver (`77.88.8.8` Yandex) is pinned alongside in main table with the same ECMP shape so dnsmasq's lookups for bypass domains don't accidentally leak through the AWG tunnel.

**Critical gotcha: BusyBox `ip` does not support multipath.** OpenWrt's default `ip` is a BusyBox applet (`/sbin/ip -> /bin/busybox`). It silently rejects the `nexthop via X dev Y weight N` syntax. `apk add ip-full` installs the real iproute2 which actually implements multipath. `post-upgrade.sh` ensures this on every boot.

iproute2-full quirk: the `table N` argument must come **before** the nexthop chain. `ip route add default nexthop ... nexthop ... table 100` fails with `'nexthop' or end of line is expected instead of 'table'`. Correct order: `ip route add table 100 default nexthop ... nexthop ...`. The hotplug script writes it correctly; if you reorder, expect breakage.

## DNS chicken-and-egg at boot

A subtle deadlock that bit the first reboot test, and the reason `configs/network.example` ships with `option auto '0'` on awg0 and recommends an IP-literal `endpoint_host` rather than a hostname.

The deadlock chain on cold boot, when the AmneziaWG tunnel is the default route in main routing table:

1. `/etc/init.d/network start` runs early in boot.
2. netifd picks up awg0 (`option auto '1'` would mean "bring this up now") and calls the amneziawg proto handler.
3. The proto handler calls `awg setconf` with the peer block, which includes `Endpoint=<hostname>:<port>`. The userspace tool resolves `<hostname>` via glibc → `/etc/resolv.conf` → `127.0.0.1` → dnsmasq → `127.0.0.1:5053` (https-dns-proxy) → DoH to `1.1.1.1`.
4. At this point in boot, https-dns-proxy may not have completed its initial bootstrap, OR dnsmasq may not have accepted its first query yet, OR the route to `1.1.1.1` does not exist (because the default route is *supposed* to come from awg0, which has not come up yet).
5. The hostname lookup fails. The proto handler enters its retry-with-backoff loop: 1.00s, 1.20s, 1.44s, 1.73s, 2.07s, ... about 12 attempts.
6. After ~30 seconds of retries the handler gives up. netifd marks awg0 DOWN. No more automatic retry.
7. awg-watchdog (in cron, runs every 2 minutes) eventually detects the missing handshake and runs `ifdown awg0 && ifup awg0`. By then DNS works and the second attempt succeeds.

Symptom: 2+ minute delay between cold boot and tunnel coming up. Until awg-watchdog rescues, the box has no default route at all (main table is empty), `wait_for_wan` in `post-upgrade.sh` blocks waiting for DNS, and locally-originated outbound from the router returns EPERM.

**Two fixes applied together; either alone is insufficient.**

### Fix 1: `option auto '0'` on awg0

In `/etc/config/network`:

```text
config interface 'awg0'
    option proto 'amneziawg'
    option auto '0'
    ...
```

netifd skips awg0 at boot entirely. The interface is brought up later, explicitly, by `/usr/share/piwrt/post-upgrade.sh` after `wait_for_wan()` has confirmed `ping 1.1.1.1` AND `nslookup downloads.openwrt.org` both succeed. By the time `ifup awg0` is called, the DNS chain is verified working.

Manual `ifup awg0` from the CLI continues to work regardless of the `auto` flag — `auto` only governs boot-time behaviour.

### Fix 2: IP-literal `endpoint_host`

In `/etc/config/network`:

```text
config amneziawg_awg0
    option endpoint_host '<SERVER_IP>'
    ...
```

The proto handler still calls `getaddrinfo("<SERVER_IP>")`, but with a literal IP the glibc resolver returns immediately from the numeric-address path — no DNS query, no chain, no chicken-and-egg. AWG comes up even if dnsmasq is dead.

Combined with `/etc/hosts` entry mapping the provider hostname to the IP, any other tooling that queries the name resolves it locally:

```text
echo "136.0.175.197	po.34298r2894ru8934r984328u.online" >> /etc/hosts
```

### Why both fixes together

- Without Fix 1 (`auto='1'`): netifd still tries to ifup awg0 too early in boot, before `post-upgrade.sh` has even fired. With IP-literal endpoint, this would *probably* succeed since DNS is not needed, but you're racing the kernel-module load order and any other early-boot weirdness — Fix 1 makes the timing deterministic.
- Without Fix 2 (hostname endpoint): even with Fix 1, `post-upgrade.sh`'s `ifup awg0` runs right after `/etc/init.d/dnsmasq restart`, which briefly tears down the DNS chain. The 3-second sleep added to `post-upgrade.sh` covers most of this, but a sluggish https-dns-proxy bootstrap could still cause the retry loop to exhaust on a slow disk or under load.

With both fixes, the tunnel is up and handshaking within ~10 seconds of `eth1` getting DHCP at boot.

### IP rotation risk

AWG providers occasionally rotate endpoint IPs. If `<SERVER_IP>` becomes stale:

- AWG won't come up after a reboot; existing connections won't survive an endpoint-key-rotation handshake.
- Recovery: update `option endpoint_host` in `/etc/config/network` AND `/etc/hosts` entry, then `ifdown awg0 && ifup awg0`.
- A long-term hardening would be a periodic refresh of both files from a known-good source. Out of scope for this README.

In practice, most AWG providers keep endpoint IPs stable for months. If yours doesn't, switch back to the hostname form (accept the slower boot convergence via awg-watchdog rescue) and rely on awg-watchdog as the failover mechanism instead.

## SSH hardening

### Why disable password auth

Dropbear out of the box on OpenWrt accepts an empty root password during initial setup, then any password matching `/etc/shadow`. The shadow file is part of `sysupgrade.conf`'s default keep list, so a previously-set password survives upgrades — but it's also brute-forceable from the WAN side if `SSH-WAN` is open (and we want it open). The only safe configuration is **no password auth at all**, key-only.

`uci set dropbear.@dropbear[0].PasswordAuth='off'` and `uci set ... RootPasswordAuth='off'` accomplish that. The shadow file becomes irrelevant for SSH; even an empty password no longer grants access.

The only risk is locking yourself out by disabling password auth before verifying a working key. Mitigation:

1. Add your primary key first.
2. Test from a separate session: `ssh -o PasswordAuthentication=no root@router 'echo ok'`. If it greets you, you're safe.
3. Add a secondary fallback key (e.g. a deployment-tooling key) so a single lost key doesn't lock you out.
4. Only then flip password auth off.

### LuCI removal

LuCI is OpenWrt's web admin UI. We're admin-by-SSH-only, so it's dead weight: 24 packages (luci-base, luci-mod-*, luci-app-*, rpcd-mod-luci, themes, lib-uqr, ...) plus `uhttpd` and `uhttpd-mod-ubus` and `libustream-mbedtls`. Removing them frees about 5 MiB of squashfs overlay and silences a network service nobody talks to. The dependency `rpcd` (without the LuCI module) stays — it backs ubus, which other things use.

Removal command in step 12 of the walkthrough above. `post-upgrade.sh` does **not** re-install any of these on sysupgrade — the comments in the script call out the omission explicitly.

## Track changes to /etc

OpenWrt has no native `etckeeper`. The CWWK uses the same lightweight cron-based approach as the Pi and Hopper:

```sh
apk add git
cd /etc
git config --global user.email 'piwrt-etc@cwwk.local'
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
git commit -m "initial commit on CWWK $(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

The `etc-autocommit` cron job (in `scripts/`) runs hourly and commits any drift with a UTC timestamp message. `cd /etc && git log` answers "what changed yesterday at 03:00".

`/etc/.git/` and `/etc/.gitignore` are added to `sysupgrade.conf` so history survives upgrades.

## Sysupgrade resilience

OpenWrt sysupgrade preserves `/etc/config/*` and whatever's in `/etc/sysupgrade.conf`. Everything else — including all custom-installed packages — gets wiped. `/usr/share/piwrt/post-upgrade.sh` re-installs them on every boot, idempotently. Same script structure as the Hopper version, minus the modem-package block, plus the x86_64-specific AWG filename pattern (doubled arch suffix in the release artefact name).

The script is invoked from `/etc/rc.local` on every boot (backgrounded so boot isn't held up). Steady state: ~1 second of apk metadata work, no-ops everywhere. First boot after sysupgrade: 30–90 seconds to download the AWG kmod and apply patches.

## Watchdogs

- **`awg-watchdog`** — runs every 2 minutes from cron. Reads `awg show awg0 latest-handshakes`, checks how long ago the last handshake was. If older than 180 s (twice the keepalive interval), it bounces `awg0` with `ifdown` + `ifup`. This also serves as failover trigger when the WAN endpoint route goes stale.

Skips the first 90 seconds of uptime — NTP needs to bring system time into sync before the AWG handshake age can be evaluated, and netifd is still racing during early boot.

## Operations

```sh
# Egress sanity check (should match AWG server country)
curl --silent https://1.1.1.1/cdn-cgi/trace | grep --extended-regexp '^(ip|loc|colo)='

# AWG tunnel status (handshake age + counters)
awg show awg0

# Routing tables
ip -4 route show default               # main table — awg0 + WAN fallback
ip -4 route show table 100             # split-VPN bypass — ECMP or single

# WAN state
ifstatus wan | jsonfilter -e '@.up'

# nftables sets (populated by dnsmasq from bypass list)
nft list set inet fw4 allow_domains_v4 | head -n 30

# Refresh the bypass list on demand (cron does this weekly anyway)
/usr/bin/update-bypass-list

# Driver / link sanity for the 82599ES SFP+ and i226 RJ45 ports
ethtool eth0
ethtool eth2

# Last commits to /etc
cd /etc && git log --oneline --max-count 20
```

## License

Same as the parent repo. See top-level `LICENSE` if present; otherwise the contents are released as-is with no warranty.
