# piwrt

Raspberry Pi 5 + OpenWrt 25.12.3: Wi-Fi access point that tunnels all client traffic through an AmneziaWG v2 VPN, with DoH upstream, a DNS-level kill switch, and a domain-based split-tunnel that bypasses the VPN for Russian services (Ozon, Avito, Yandex, banks, gov services) so their anti-fraud doesn't trip on a foreign exit IP.

## Architecture

```text
[upstream router] ── eth0 (WAN, DHCP) ── RPi5 ── phy0-ap0 (AP 5 GHz, br-lan) ── clients (192.168.1.0/24)
                                          │
                                          ├── awg0 (AmneziaWG v2) ── default route ── [VPN server]
                                          │
                                          ├── 127.0.0.1:5053 (https-dns-proxy, DoH Cloudflare via awg0)
                                          │
                                          └── fwmark 0x100 → table 100 (default via eth0)
                                              ↑
                                              nftables sets allow_domains_v4/v6
                                              populated by dnsmasq-full when clients
                                              resolve domains from
                                              itdoginfo/allow-domains (Russia/inside-raw)
```

Firewall forwards `lan → awg` for all traffic, and `lan → wan` only when a packet carries fwmark 0x100. No generic `lan → wan` rule → if the tunnel drops, non-bypassed clients still lose internet (kill switch intact for anything not in the bypass list).

## Scope, explicitly

Does exactly one thing: receive internet over ethernet, broadcast Wi-Fi, shove client traffic through a VPN tunnel. That's the whole feature list. No AdGuard Home, no SQM, no policy-based routing, no incoming WireGuard server, no Samba, no mini-NAS, no UPnP, no monitoring exporter. The Pi5 has plenty of headroom for any of those, but each one is another piece that can break independently and turn the "just reboot it" troubleshooting doctrine into an hour of log-reading. If you need those features, add them on top and keep your own branch — the README won't guide you there.

## Hardware caveats learned the hard way

### NVMe

- **Samsung SSD 990 EVO 1TB — do not use.** Controller hangs in D3cold power state under Linux 6.6/6.12 on RPi5 even with every known PCIe power-saving workaround. Gets `nvme nvme0: controller is down; will reset: CSTS=0xffffffff, PCI_STATUS=0xffff` → `failed to allocate host memory buffer` → `Unable to change power state from D3cold to D0, device inaccessible` → ext4 journal aborts → rootfs read-only → `Failed to execute /usr/libexec/login.sh`. All Samsung 9x0 consumer NVMes have this reputation on Pi5; swap for a different brand.
- **WD Green SN350 500 GB** works fine at PCIe Gen2 (default) with `nvme_core.default_ps_max_latency_us=0` in cmdline. Zero I/O errors over multi-hour uptime.
- **Do not force `dtparam=pciex1_gen=3`** unless you specifically tested your NVMe at Gen3. Gen2 is the default and is more forgiving.

### Wi-Fi

- **2.4 GHz AP mode is broken** on the built-in BCM43455 of at least one RPi5 unit after a few `wifi down; wifi up` cycles — beacon goes out (clients see SSID at 100% signal), but RX packets counter on `phy0-ap0` stays at **0** and no STA auth/assoc events appear in hostapd log. Clients silently cannot associate. A `reboot`, `rmmod brcmfmac`, full power-cycle, OpenWrt bump 24.10 → 25.12, and CMDline tweaks do not revive 2.4 GHz RX. **5 GHz AP mode works fine** on the same chip at the same moment — we confirmed RX by putting the chip in STA mode and associating with an upstream 5 GHz AP.
- **Use 5 GHz. Fix a channel explicitly** (`brcmfmac` doesn't support ACS — `hostapd` fails with `ACS: Unable to collect survey data` on 'auto'). Channel 36, HT20 is a safe default.
- **The `@`/`.`-in-SSID warning has been retracted.** Original observation on this Pi (2026-04-21) was that hostapd's `utf8_ssid=1` emits `ssid2="..."` and macOS / Nintendo Switch fail to associate. Re-tested 2026-05-14 on a Netcraze Hopper (MT7976 / mt76 driver) with `f@lex.la-liberated` — hostapd emits the SAME `ssid2="quoted-string"` form (because `@` and `.` are printable ASCII, hostapd quotes rather than hex-encodes), and Switch + macOS associate cleanly and reach the internet (confirmed end-to-end). So the original Pi symptom was either BCM43455-specific, an older hostapd version, or a misdiagnosis. The hex form `ssid2=HEX...` is only emitted for non-printable or non-ASCII codepoints — that's likely what trips strict clients, not the quoted-string form. Plain ASCII remains the conservative default on this Pi if symptoms recur, but there's no longer a blanket reason to avoid `@`/`.`.
- **Do not overwrite `/lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,4-model-b.txt`.** This is the NVRAM blob that `brcmfmac` loads into the chip at probe time — a stray `echo something > file` or a misfired script that truncates it to a few bytes leaves the chip uninitialised, `dmesg` shows `brcmfmac: brcmf_sdio_htclk: HT Avail timeout (1000000): clkctl 0x50`, and `iw dev` is empty. No amount of `reboot`/`rmmod brcmfmac`/power-cycle recovers it, because the file content is wrong on disk. Fix: `wget -O <path> https://raw.githubusercontent.com/RPi-Distro/firmware-nonfree/bookworm/debian/config/brcm80211/brcm/brcmfmac43455-sdio.txt` (this is the upstream source used by the `brcmfmac-nvram-43455-sdio` apk in OpenWrt). Note that `apk fix` / `apk add --reinstall` do **not** restore the file — OpenWrt's apk-tools build does not implement `--reinstall`, and `apk fix` no-ops if the package DB thinks the file is fine. Direct `wget` is the reliable path.

### PSU

- 27 W USB-C PSU is mandatory. Lower wattage throttles PCIe and can manifest as NVMe flakiness.

## Prerequisites

- RPi5 + official M.2 HAT + NVMe (avoid Samsung 990 EVO family).
- 27 W USB-C PSU.
- microSD (one-off, to set EEPROM boot order).
- USB-to-M.2 adapter for flashing NVMe from a workstation.
- HDMI monitor + USB keyboard (one-off, for WAN bootstrap — macOS has no ethernet).
- AmneziaWG v2 `.conf` from your server (`Jc/Jmin/Jmax/S1-S4/H1-H4` parameters).

## 1. EEPROM boot order

Boot Raspberry Pi OS from SD once:

```bash
sudo rpi-eeprom-config --edit
# set BOOT_ORDER=0xf416
sudo rpi-eeprom-update --apply
sudo poweroff
```

## 2. Flash OpenWrt onto NVMe

We use the **ext4-factory** image — simpler overlay model than squashfs-factory, makes `sysupgrade` preserving custom files straightforward.

Detach the NVMe, connect via USB-M.2 adapter to your workstation:

```bash
curl --location --output /tmp/openwrt-rpi5.img.gz \
  https://downloads.openwrt.org/releases/25.12.3/targets/bcm27xx/bcm2712/openwrt-25.12.3-bcm27xx-bcm2712-rpi-5-ext4-factory.img.gz
curl --location --output /tmp/sha256sums \
  https://downloads.openwrt.org/releases/25.12.3/targets/bcm27xx/bcm2712/sha256sums
grep "ext4-factory" /tmp/sha256sums | awk '{print $1"  /tmp/openwrt-rpi5.img.gz"}' | shasum --algorithm 256 --check

diskutil list external physical
# Identify the correct /dev/diskN for your NVMe — not your Mac's internal SSD
diskutil unmountDisk /dev/diskN
gunzip --stdout /tmp/openwrt-rpi5.img.gz | sudo dd of=/dev/rdiskN bs=4m
# Ctrl+T during dd sends SIGINFO for progress
sync
diskutil eject /dev/diskN
```

Reinstall the NVMe. Don't plug ethernet into the upstream router yet.

## 3. First contact via HDMI + keyboard

OpenWrt's default is `br-lan 192.168.1.1/24` spanning every interface (including eth0) — if you plug it into your upstream that uses the same subnet, chaos. On modern Macs there's also no built-in ethernet, so the HDMI/USB-keyboard path is simpler than finding a USB-ethernet adapter.

At the Pi5 console:

```sh
passwd
# set a throwaway password — we'll lock password login later once ssh-key is in place

uci del_list network.@device[0].ports='eth0'
uci set network.wan=interface
uci set network.wan.device='eth0'
uci set network.wan.proto='dhcp'
uci set network.wan6=interface
uci set network.wan6.device='eth0'
uci set network.wan6.proto='dhcpv6'
uci commit network
/etc/init.d/network restart
ip link set eth0 up   # netifd sometimes doesn't auto-up after a profile change
sleep 3
ifstatus wan | grep '"address"'
```

Plug ethernet into the upstream router. Note the IP from `ifstatus wan`.

Open SSH via WAN temporarily:

```sh
uci add firewall rule
uci set firewall.@rule[-1].name='SSH-WAN'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].dest_port='22'
uci set firewall.@rule[-1].target='ACCEPT'
uci commit firewall
/etc/init.d/firewall restart
```

If the upstream LAN is trusted (behind your main router), leave `SSH-WAN` in place permanently — that's how you'll administer the box from your Mac. Otherwise remove it once you've joined the AP via Wi-Fi.

From the workstation, push your public key:

```bash
cat ~/.ssh/id_ed25519.pub | ssh root@<WAN_IP> 'cat >> /etc/dropbear/authorized_keys && chmod 600 /etc/dropbear/authorized_keys'
```

Lock the password and rely only on the key:

```bash
ssh root@<WAN_IP> 'passwd -l root; grep ^root: /etc/shadow'
# Expect the hash to start with `!$` — that's "locked, key auth still works"
```

HDMI + keyboard can be disconnected.

## 4. NVMe safety kernel param

```sh
grep -q 'default_ps_max_latency_us' /boot/cmdline.txt || \
  sed -i 's|$| nvme_core.default_ps_max_latency_us=0|' /boot/cmdline.txt
cat /boot/cmdline.txt
```

If you got stuck with a Samsung 990 EVO (see "Hardware caveats"), **also** add `pcie_aspm=off pcie_port_pm=off` — but these are not enough to save the 990 EVO, they just delay the first hang. The right fix is swapping the SSD.

## 5. Preserve cmdline/opkg-arch across future sysupgrades

OpenWrt's default sysupgrade keep-list covers `/etc/config/*`, SSH keys, and a handful of other files, but **not** `/boot/cmdline.txt`. Add our custom paths:

```sh
cat >> /etc/sysupgrade.conf <<EOF
/boot/cmdline.txt
EOF
```

After the next `sysupgrade`, our NVMe params survive.

## 6. Wi-Fi AP on 5 GHz

```sh
uci set wireless.radio0.band='5g'
uci set wireless.radio0.channel='36'          # fixed; brcmfmac has no ACS
uci set wireless.radio0.htmode='HT20'
uci set wireless.radio0.country='RU'          # passed to hostapd as metadata; phy0 itself reports country 99 because brcmfmac wiphy is self-managed — harmless
uci set wireless.radio0.legacy_rates='1'
uci set wireless.radio0.disabled='0'
uci set wireless.default_radio0.ssid='piwrt'  # see hostapd/ssid2 caveat above; @/. now known to be fine in practice
uci set wireless.default_radio0.hidden='0'    # optional; 'hidden 1' works, but clients see the AP faster when broadcast
uci set wireless.default_radio0.encryption='sae-mixed'  # WPA3-SAE with WPA2-PSK fallback for older clients
uci set wireless.default_radio0.wps_pushbutton='0'      # disable WPS — PIN brute-force is a known vector
uci set wireless.default_radio0.key='<WIFI_PASSWORD_MIN_8_CHARS>'
uci commit wireless
wifi
sleep 5
iw dev phy0-ap0 info | grep -E 'ssid|channel|txpower'
cat /sys/class/net/phy0-ap0/statistics/tx_packets
cat /sys/class/net/phy0-ap0/statistics/rx_packets
```

After a client connects, `rx_packets` should climb. If it stays at 0 → you have the 2.4 GHz RX brickening problem. Confirm 5 GHz is in use and re-check.

`sae-mixed` advertises both SAE (WPA3) and PSK2 (WPA2) on the same SSID with a shared passphrase. New clients negotiate SAE automatically, older ones fall back to PSK2 — no separate SSID needed. If every client you own supports WPA3, use plain `sae` instead.

## 7. Install AmneziaWG v2

OpenWrt 25.x uses **apk** (Alpine Package Kit) instead of opkg. Packages are `.apk`, the repo index is in `/etc/apk/repositories.d/`.

Slava-Shchipunov's builds target the `aarch64_cortex-a76_bcm27xx_bcm2712` architecture and end up in `.apk` format. Standard apk arch (`/etc/apk/arch`) is `aarch64_cortex-a76`, which is a superset match and accepts these packages.

`kmod-amneziawg` declares dependencies on four kernel modules (`kmod-udptunnel4`, `kmod-udptunnel6`, `kmod-crypto-lib-chacha20poly1305`, `kmod-crypto-lib-curve25519`) that live in the standard OpenWrt feeds. Install them from the base repo first, then the three Slava-Shchipunov apks. `apk add` with the local file path doesn't auto-resolve transitive deps, so deps go first as a separate `apk add`.

```sh
cd /tmp
apk update
apk add kmod-udptunnel4 kmod-udptunnel6 \
        kmod-crypto-lib-chacha20poly1305 kmod-crypto-lib-curve25519

URL='https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v25.12.3'
for f in kmod-amneziawg amneziawg-tools luci-proto-amneziawg; do
  wget -O "${f}.apk" "$URL/${f}_v25.12.3_aarch64_cortex-a76_bcm27xx_bcm2712.apk"
done
apk add --allow-untrusted /tmp/kmod-amneziawg.apk /tmp/amneziawg-tools.apk /tmp/luci-proto-amneziawg.apk
modprobe amneziawg
awg --version
/etc/init.d/network restart   # so netifd picks up the new 'amneziawg' proto handler
```

The package is named `luci-proto-amneziawg` (adds the network-page proto option); there is no separate `luci-app-amneziawg`.

Or run [scripts/install-awg.sh](scripts/install-awg.sh) which does the above in one shot.

## 8. Configure awg0 from your `.conf`

UCI keys for AWG v2 parameters use the **`awg_` prefix** (`awg_jc`, `awg_s1`, `awg_h1`, …). Without the prefix, `/lib/netifd/proto/amneziawg.sh` silently falls back to defaults (`H1=1, H2=2, H3=3, H4=4`, others 0) — tunnel comes up, server drops every packet.

See [configs/network](configs/network) and [configs/amneziawg_awg0.example](configs/amneziawg_awg0.example).

Bring up:

```sh
uci commit network
ifup awg0
sleep 4
awg show awg0         # peer, handshake, all obfuscation params populated
ip route              # default via awg0
wget -qO- --timeout=5 http://api.ipify.org   # VPN server's public IP
```

If `awg show awg0` shows `h1: 1, h2: 2, h3: 3, h4: 4` — the `awg_` prefix is missing somewhere.

## 9. Firewall: full-tunnel + kill switch

See [configs/firewall](configs/firewall). Deploy via ssh pipe (BusyBox ash mangles multi-quote heredocs):

```bash
cat configs/firewall | ssh root@<WAN_IP> 'cat > /etc/config/firewall'
ssh root@<WAN_IP> '/etc/init.d/firewall restart'
```

Zones: `lan`, `wan`, `awg`. Only forwarding rule is `lan → awg`. The `SSH-WAN` rule stays — that's how you keep administering the box.

Verify kill switch:

```bash
# client on Wi-Fi pings something
ssh root@<WAN_IP> 'ifdown awg0'   # pings freeze
ssh root@<WAN_IP> 'ifup awg0'     # pings recover in ~10s
```

## 10. DoH via https-dns-proxy (Cloudflare)

```sh
apk add https-dns-proxy luci-app-https-dns-proxy
uci delete https-dns-proxy.@https-dns-proxy[1]   # drop the default Google instance
uci commit https-dns-proxy
/etc/init.d/https-dns-proxy enable
/etc/init.d/https-dns-proxy restart
```

`https-dns-proxy` auto-rewrites dnsmasq upstream to `127.0.0.1:5053`. Clients still speak plain Do53 to `192.168.1.1`; only the Pi-to-Cloudflare hop is encrypted.

**Bootstrap gotcha**: on first install right after a factory flash or sysupgrade, apk can't fetch dependencies over HTTPS because dnsmasq has stale references to the (not-yet-running) DoH proxy. Break the circle by pointing dnsmasq at a public resolver via the WAN directly, install, then let `https-dns-proxy` take over:

```sh
uci -q delete dhcp.@dnsmasq[0].server
uci -q delete dhcp.@dnsmasq[0].doh_server
uci -q delete dhcp.@dnsmasq[0].doh_backup_server
uci set dhcp.@dnsmasq[0].noresolv='1'
uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'
uci commit dhcp
/etc/init.d/dnsmasq restart
# now apk works; install DoH packages, then /etc/init.d/https-dns-proxy restart
# the proxy rewrites dnsmasq for you
```

## 11. MTU for VPN path

AWG MTU is 1280. Announce MTU 1280 to LAN clients via DHCP option 26 so they set it themselves — avoids fragmentation failures (classic Nintendo Switch `2124-8006`):

```sh
uci add_list dhcp.lan.dhcp_option='26,1280'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

**Do not** set `network.lan.mtu='1280'` on the interface — it causes `DEVICE_CLAIM_FAILED` on `br-lan` because the wireless port `phy0-ap0` stays at 1500 and a bridge cannot span mixed MTUs. Client-side DHCP announcement is enough.

Reconnect existing clients (Forget + rejoin) to pick up the new lease.

## 12. Split-VPN: bypass for Russian services

Russian services (Ozon, Avito, Yandex, Sber, Госуслуги, такси, доставки) have aggressive anti-fraud that sees a Polish exit IP as suspicious and reacts with captchas, SMS verification, or outright API rejection. Solution: route traffic to a whitelist of Russian domains through eth0 (real home ISP IP) while keeping everything else in the AWG tunnel.

Design: dnsmasq-full resolves whitelisted domains and feeds the resolved IPs into nft dynamic sets `allow_domains_v4/v6`. A prerouting hook marks every packet to those IPs with fwmark 0x100. `ip rule` routes fwmark 0x100 into a dedicated table whose default goes via eth0. Firewall allows `lan → wan` forward only for marked packets — the kill switch stays intact for everything else.

Domain list is pulled from community-maintained [itdoginfo/allow-domains](https://github.com/itdoginfo/allow-domains) (`Russia/outside-raw.lst` — Russian domestic domains that geo-block foreign IPs: Ozon, Gosuslugi, RZhD, Pochta, Nalog, Mos.ru, Yandex.net, Leroy Merlin, etc.). Note the counter-intuitive naming: `outside-raw.lst` is for users *outside* Russia who need to reach Russian services — our case. `inside-raw.lst` is the opposite list (RKN-blocked foreign sites) which should stay inside the VPN.

DNS for these domains is forced through Yandex DNS `77.88.8.8` over eth0 (NOT over the VPN) so we get Russian CDN edge IPs — otherwise a Polish-DoH resolver would return Polish Cloudflare IPs, defeating the bypass.

### Install

```sh
# 1. Replace stock dnsmasq with dnsmasq-full (needed for nftset directive)
#    AND run dnsmasq as root (default `dnsmasq` user has no CAP_NET_ADMIN
#    inside the ujail sandbox, so nftset= directives silently never
#    populate the set even though dnsmasq-full is compiled with nftset).
apk update
apk add dnsmasq-full

# If apk refuses due to conflict with base `dnsmasq`, drop it first:
# apk del dnsmasq && apk add dnsmasq-full

# 2. Stop any stale mwan3 from earlier experiments
/etc/init.d/mwan3 stop 2>/dev/null
/etc/init.d/mwan3 disable 2>/dev/null

# 3. Drop nft rules, hotplug, and the update script
install -m 644 configs/nftables/50-allow-domains.nft /etc/nftables.d/50-allow-domains.nft
install -m 755 scripts/split-vpn-init.sh              /etc/hotplug.d/iface/90-split-vpn
install -m 755 scripts/update-bypass-list.sh          /usr/bin/update-bypass-list

# 4. Merge firewall + dhcp changes (or copy configs/firewall and configs/dhcp
#    wholesale if this is a fresh install):
fw4 reload

# 4b. Patch dnsmasq init script to run as root (mandatory — otherwise nftset
#     won't populate). Idempotent; re-run after every dnsmasq-full apk upgrade.
install -m 755 scripts/fix-dnsmasq-user.sh /usr/bin/fix-dnsmasq-user
/usr/bin/fix-dnsmasq-user
/etc/init.d/dnsmasq restart

# 5. First-run the update script to populate /etc/dnsmasq.d/allow-domains.conf
update-bypass-list

# 6. Trigger the hotplug to install ip rule + ip route
ifdown wan && ifup wan

# 7. Schedule weekly refresh
echo '0 6 * * 0 /usr/bin/update-bypass-list' >> /etc/crontabs/root
/etc/init.d/cron reload
```

### Verify

```sh
# nft set is populated after a client resolves a bypass domain
nft list set inet fw4 allow_domains_v4 | head -10

# ip rule shows the fwmark lookup
ip rule list | grep 0x100

# routing table 100 has eth0 default
ip route show table 100

# From a Wi-Fi client:
curl --silent https://api.ipify.org        # → VPN exit IP (Poland)
curl --silent https://ipv4.ozon.ru/health  # → works, no captcha
ssh root@pi5 ifdown awg0
curl --max-time 3 https://api.ipify.org    # times out (kill switch)
curl --max-time 3 https://ozon.ru/         # still works (bypass keeps going)
ssh root@pi5 ifup awg0
```

### User overrides

itdoginfo `outside-raw.lst` is deliberately minimal (~37 Russian-only domains) and does not include Avito, Wildberries, Sberbank, yandex.ru root, or most banks. Add them in `/etc/allow-domains-user.lst` — one domain per line, `#`-prefixed comments allowed. `update-bypass-list.sh` picks it up automatically: every domain from the user file gets the same three `nftset=`/`server=` directives appended to `/etc/dnsmasq.d/allow-domains.conf`. See `configs/allow-domains-user.lst.example` for a starter set covering common marketplaces, banks, telecom self-service portals, and yandex.ru root.

```sh
cp configs/allow-domains-user.lst.example /etc/allow-domains-user.lst   # or write your own
# edit /etc/allow-domains-user.lst as needed
update-bypass-list
```

### Caveats
- Clients using their own DoH/DoT (iOS Private Relay, Firefox DoH) bypass our dnsmasq → `allow_domains_*` sets never get populated → their Russian-site traffic stays in the VPN. Either disable encrypted DNS on clients or accept the limitation.
- CDN-IP collisions: if a Russian site shares a Cloudflare edge IP with a VPN-only site, the bypass will also let the other site out. Mitigated by 1 h dynamic timeout on the sets.
- When the VPN is down, bypassed domains keep working through the real WAN — this is by design, but worth knowing: the kill switch is only for non-bypassed traffic.

### Dual-WAN ready

`scripts/split-vpn-init.sh` watches every interface listed in its `WAN_IFACES` variable (default: `wan wwan`). On any `ifup`/`ifdown` it picks the lowest-metric live uplink and rebuilds routing table 100 + the `77.88.8.8` pinned route through it. So when you later add a USB Wi-Fi dongle for travel:

1. Wire the radio as `wifi-iface mode sta` pointing at `network 'wwan'` in `/etc/config/wireless`.
2. Uncomment the `config interface 'wwan'` block in `/etc/config/network` (metric `20` keeps ethernet as primary; USB takes over when ethernet is down).
3. Add `wwan` to the `wan` firewall zone: `uci add_list firewall.@zone[1].network='wwan'`, commit, `fw4 reload`.
4. Reboot or `ifup wwan` — hotplug will discover it automatically, no script edits needed.

## 13. After-install hardening

A clean install gets the tunnel and the AP running. The bits below survive reboots and sysupgrades, catch the failure modes documented above before they need manual intervention, and make the box pleasant to debug six months from now.

### Survive sysupgrade

OpenWrt's default sysupgrade keep-list preserves `/etc/config/*` and SSH host keys, but nothing else. Our installer lives at `/usr/share/piwrt/install-awg.sh` and the watchdog scripts at `/usr/bin/awg-watchdog`, `/usr/bin/wifi-watchdog`, etc. — without explicit entries they all vanish on every kernel bump. Append [configs/sysupgrade.conf](configs/sysupgrade.conf) to `/etc/sysupgrade.conf` once; the list is idempotent.

Then drop the installer into its surviving location and wire it to rc.local so that a fresh kernel ABI does not leave you tunnel-less:

```sh
mkdir -p /usr/share/piwrt
install -m 755 scripts/install-awg.sh /usr/share/piwrt/install-awg.sh
```

Append the contents of [configs/rc.local.append](configs/rc.local.append) to `/etc/rc.local` (before the final `exit 0`). On every boot the hook checks `awg --version`; if AWG is missing — fresh sysupgrade, ABI mismatch, whatever — it runs the installer asynchronously so boot continues normally and the tunnel comes up a few seconds later in the background.

### Watchdogs

Two small cron jobs catch the failures we have already paid for:

```sh
install -m 755 scripts/awg-watchdog  /usr/bin/awg-watchdog
install -m 755 scripts/wifi-watchdog /usr/bin/wifi-watchdog
cat >> /etc/crontabs/root <<'EOF'
*/2 * * * * /usr/bin/awg-watchdog
*/5 * * * * /usr/bin/wifi-watchdog
EOF
/etc/init.d/cron restart
```

`awg-watchdog` restarts `awg0` if the last handshake is older than 180 seconds (a stale obfuscation state or upstream key rotation). `wifi-watchdog` brings `phy0-ap0` back if it has gone missing, escalating to `rmmod brcmfmac && modprobe brcmfmac` if `wifi up` alone is not enough. Both skip the first 90 seconds of uptime — NTP needs time to sync, and racing wifi-scripts during early boot just produces log noise.

### Track changes to /etc

OpenWrt has no native `etckeeper`, but `git` is in the feeds and a one-liner cron job suffices:

```sh
apk add git
cd /etc
git init
git config user.email "root@piwrt"
git config user.name  "piwrt root"
cat > /etc/.gitignore <<'EOF'
config-shadow/
shadow
shadow.bak
shadow-
gshadow
gshadow-
dropbear/dropbear_*_host_key
ssh/ssh_host_*_key*
resolv.conf
resolv.conf.d/
*.pid
*.swp
*.bak
EOF
git add -A
git -c commit.gpgsign=false commit -m "baseline"

cat > /usr/bin/etc-autocommit <<'EOF'
#!/bin/sh
cd /etc
git add -A
if ! git diff --cached --quiet; then
    git -c commit.gpgsign=false commit -m "autocommit $(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1
    logger -t etc-autocommit "committed /etc drift"
fi
EOF
chmod +x /usr/bin/etc-autocommit
echo '17 * * * * /usr/bin/etc-autocommit' >> /etc/crontabs/root
/etc/init.d/cron reload
```

Now `cd /etc && git log` answers "what changed yesterday at 03:00". With `/etc/.git/` and `/etc/.gitignore` in the sysupgrade keep-list (above), the history survives upgrades too.

### Optional: vnstat traffic accounting

If the uplink has a quota (cellular failover, leased line) it helps to see how many bytes go where:

```sh
apk add vnstat2
/etc/init.d/vnstat enable
/etc/init.d/vnstat start
```

Per-interface byte counters persist across reboots. Inspect with `vnstat --interface awg0` (or eth0, br-lan, phy0-ap0). No exporter, no dashboard — just numbers in the terminal.

## 14. End-to-end tests

1. Client on Wi-Fi → `curl https://api.ipify.org` returns the VPN server's public IP, not the upstream WAN.
2. `ifdown awg0` on the Pi → non-bypass internet dies → `ifup awg0` → recovers in ~10s.
3. `curl https://ozon.ru/` with Wi-Fi client continues to work after `ifdown awg0` — bypass is active.
4. `dnsleaktest.com` shows only the Cloudflare DoH resolver for non-bypassed queries.
5. `reboot` the Pi → everything comes back on its own within ~60 s.
6. Gaming consoles: check NAT type via Test Connection. Commercial VPN providers often rate-limit gaming UDP — `2306-0332` on Switch with correct MTU and DNS probably means the VPN exit blocks game traffic. Try a different `.conf` from another country.

## Known gotchas — one-line cheatsheet

- Samsung 990 EVO on RPi5 → swap the SSD
- `nvme_core.default_ps_max_latency_us=0` in `/boot/cmdline.txt` → add to `/etc/sysupgrade.conf` too
- brcmfmac ACS unsupported → fix channel; 2.4 GHz AP-mode brittle → prefer 5 GHz
- ~~SSID with `@`/`.` → hostapd uses `ssid2=`, breaks macOS/Switch → ASCII only~~ (retracted 2026-05-14 — re-test on Hopper showed clients associate fine with `ssid2="quoted"` form; original Pi symptom likely BCM-specific or misdiagnosed)
- 25.x uses apk, not opkg → `apk add --allow-untrusted <file.apk>`
- AWG UCI keys need `awg_` prefix (`awg_jc`, `awg_s1`, `awg_h1` …)
- Package is `luci-proto-amneziawg`, not `luci-app-amneziawg`
- DHCP option 26 for MTU 1280, **never** `network.lan.mtu`
- DoH bootstrap chicken-and-egg → point dnsmasq at `1.1.1.1` temporarily
- Root password → `passwd -l root` after ssh key is in place
- Split-VPN → `dnsmasq-full` (base lacks `nftset`), nft sets + fwmark + ip rule, `lan → wan` forward only with `option mark '0x100/0x100'` to preserve kill switch
- RU resolver in allow-domains.conf MUST be reachable via eth0 (not awg0) — hotplug pins `77.88.8.8/32` to wan gateway

## Repository layout

```text
piwrt/
├── README.md
├── configs/
│   ├── network                          UCI: br-lan, wan, wan6, awg0 + peer
│   ├── wireless                         UCI: BCM43455 AP on 5 GHz channel 36
│   ├── firewall                         UCI: full-tunnel + kill switch + SSH-WAN + split-VPN marked
│   ├── dhcp                             UCI: DHCP option 26 MTU 1280, DoH-ready dnsmasq, confdir
│   ├── amneziawg_awg0.example           /etc/amneziawg/awg0.conf template
│   ├── allow-domains-user.lst.example   /etc/allow-domains-user.lst starter — extra bypass domains
│   ├── sysupgrade.conf                  /etc/sysupgrade.conf additions — keep helpers across upgrades
│   ├── rc.local.append                  fragment to append to /etc/rc.local — Pi5 fan + AWG-ensure hook
│   └── nftables/
│       └── 50-allow-domains.nft         nft sets + mangle hook for split-VPN marking
├── scripts/
│   ├── install-awg.sh                   downloads + installs the AWG apks for 25.12.3
│   ├── split-vpn-init.sh                /etc/hotplug.d/iface/90-split-vpn — ip rule + table 100 on wan up
│   ├── update-bypass-list.sh            /usr/bin/update-bypass-list — pulls itdoginfo list, regens dnsmasq conf
│   ├── fix-dnsmasq-user.sh              /usr/bin/fix-dnsmasq-user — patch dnsmasq init to run as root (nftset needs CAP_NET_ADMIN)
│   ├── awg-watchdog                     /usr/bin/awg-watchdog — restart awg0 if handshake stale
│   └── wifi-watchdog                    /usr/bin/wifi-watchdog — restore phy0-ap0, reload brcmfmac on hard fail
└── .gitignore
```
