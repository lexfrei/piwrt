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

- **82599ES is power-hungry and warm**. ~6.5 W TDP per controller (Intel datasheet). The SFP+ cage gets noticeably hot under sustained load — not a defect, just physics. The stock chassis ships with a chassis fan (see Fan / acoustic noise section below); thermal pads from chip to case do the heavy lifting under typical load. Make sure the thermal pad is intact when reassembling.

### Intel i226-V

- **Linux kernel 6.8+ has all the i226 EEE / TSN fixes**. OpenWrt 25.12.4 ships kernel 6.12.87, so the historical advice to disable EEE on these NICs is no longer required. Leave defaults.
- **Port naming**: `igc` driver. Observed on this build: `eth0..eth3` kernel-ordered (OpenWrt 25.12 x86_64 does not enable systemd-style predictable names by default). On other distros / other OpenWrt builds with custom udev rules, you may see `enp1s0` / `enp2s0` / ... instead. Identify which physical port maps to which interface name after the first boot:

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

The board has an M.2 slot in 2280 form factor (some SKUs may also accept 2230 form-factor cards via additional standoff). It is a **regular PCIe M.2**, not CNVi — confirmed empirically by booting OpenWrt from a WD Green SN350 NVMe SSD installed there. Earlier revisions of CWWK marketing material describe a "Wi-Fi slot", but on this 2×SFP+ N305 board the slot enumerates standard NVMe devices without quirk. Lane width on the Alder Lake-N platform is constrained (total 9 PCIe Gen3 lanes shared across two 82599ES SFP+ controllers, two i226 NICs, and the M.2 slot), so peak NVMe bandwidth here is below a standard x4 desktop slot — fine for a router boot device, take a different board for NAS-class storage where NVMe throughput matters.

Wi-Fi is not provisioned in this setup regardless of what the slot can take — radio coverage comes from a downstream UniFi AP, not from a card on this board.

### PSU

- **12 V brick**, typically 5 A / 60 W stock per CWWK listings. Under sustained load (N305 + both SFP+ active + USB devices) draw climbs significantly — STH's review measured the 2.5GbE-only N305 SKU pulling ~17 W idle and ~28 W under 100% CPU, the 2×SFP+ SKU should be higher due to 82599ES (~6.5 W extra per chip when active). Stock 60 W brick has comfortable headroom for typical router workloads; only tight under simultaneous N305 100% + dual-SFP+ saturated. If the supplied PSU acts unreliably, replace with a 12 V / 6 A barrel-jack adapter (5.5×2.5 mm tip on the CWWK chassis). The connector tends to fail before the brick itself.

### Fan / acoustic noise

Single chassis fan on the CW-AL-(2L+SFP_4L) board. Two 4-pin headers on the PCB labelled **`CPU_FAN0`** and **`CPU_FAN1`** per silkscreen; only `CPU_FAN0` is populated from the factory. Fan cable to the motor body has four conductors (visually confirmed). The fan runs at fixed full speed out of the box and is the dominant source of acoustic noise.

#### What the chip is

`sensors-detect` (lm-sensors 3.6.2) identifies the SuperIO as **ITE IT8625E rev 12** at ISA base **`0xa20`** (confidence 9/9). `isadump -k 0x87,0x01,0x55,0x55 0x2e 0x2f 4` confirms LDN 4 (Environmental Monitor) is active with EC base `0a 20` and secondary base `0a 10`:

```text
LDN 4: active=01  base=0a 20  secondary=0a 10
```

#### Mainline Linux `it87` driver does not support IT8625E

The kernel hwmon `it87` driver in mainline Linux (verified against `v6.12` and current `master`) lists IT8603E, IT8620E, IT8622E, IT8623E, IT8628E, IT87952E and many other ITE parts — but not IT8625E. [Patch v2 `hwmon: (it87) Add support for IT8625E`](https://lore.kernel.org/lkml/b6c2731b-8fac-4e7a-ab0c-2f36e8a64a69@roeck-us.net/T/) (Ai Chao, Oct 2024 for Centerm P410) tried to alias IT8625E to the IT8628E type and was rejected by Guenter Roeck and Frank Crawford because the chips are architecturally different:

- 11 mV ADC scale (vs IT8628E's 12 mV) — voltage readings would be wrong
- No PECI on IT8625E (vs IT8628E has it) — temperature sources differ
- Multiple register banks on IT8625E (vs IT8628E single bank) — requires bank-select logic

The OpenWrt 25.12.4 kernel therefore ships `kmod-hwmon-it87` with **no** IT8625E support out of the box. Loading the stock module with `force_id=0x8625 ignore_resource_conflict=1` makes `__init` exit silently with `-ENODEV` because the chip_type lookup table has no entry for IT8625E.

#### Building `frankcrawford/it87` out-of-tree

The fork at <https://github.com/frankcrawford/it87> has a proper `[it8625]` entry in `it87_devices[]` with the correct feature flags (`FEAT_BANK_SEL`, `FEAT_11MV_ADC`, `FEAT_SIX_FANS`, `FEAT_SIX_PWM`, no `FEAT_TEMP_PECI`) and a dedicated case in the temp-source decoding switch. Building it against the OpenWrt SDK 25.12.4 for kernel 6.12.87:

- Build env: SDK extracted on an x86_64 Linux host (native — faster than emulated Mac/aarch64). Required `apt-get install build-essential libncurses-dev zlib1g-dev libssl-dev libelf-dev git python3 bc bison flex` on a Debian/Ubuntu host.
- The source has Gigabyte-WMI conditional helpers (`gbw_lid`, `mb_is_gigabyte`, `gbw_siv_*`) which compile as unused functions on non-Gigabyte targets. OpenWrt's kernel CFLAGS treat unused functions as errors; build needs `KCFLAGS="-Wno-error=unused-function -Wno-unused-function"`.
- `it87_check_pwm()` calls a one-time BIOS-defaults sanity check on probe. When the BIOS leaves the chip with `FAN_CTL & 0x87 == 0` (which corresponds to `FAN_CTL POLARITY = ACTIVE LOW` in the AMI Setup UI), the check fails and the driver disables the PWM interface entirely. If `POLARITY = ACTIVE HIGH` in BIOS, this trigger does not fire and no patch is needed. (We did patch the function to unconditionally `return 1` during early experimentation; not necessary in the final config.)

Loading the resulting `it87.ko` requires `pnpacpi=off` on the kernel cmdline — without it, ACPI's motherboard PnP pseudo-device claims the `0a20-0a2f` I/O range (`/proc/ioports` shows `0a20-0a2f : pnp 00:00`) and the driver's `request_muxed_region()` is refused.

After load:

```text
[it87] Found IT8625E chip at 0xa20, revision 12
[it87] Beeping is supported
```

`hwmon3` (named `it8625`) appears with **pwm1, pwm2, pwm4, pwm5, pwm6** (the driver skips `pwm3` on this chip), each with `_auto_point1/2/3_temp`, `_auto_slope`, `_auto_start`, `_enable`, `_freq`. Two `fan*_input` files (read 0 RPM continuously — no tach signal), six `in*_input` voltages, three `temp*_input` (temp3 disabled, reads -70 °C).

#### BIOS layout

`Advanced → Hardware Monitor → Smart Fan Function`:

```text
FAN_CTL POLARITY = [ACTIVE LOW | ACTIVE HIGH]   ← must be HIGH; LOW inverts PWM logic
                                                  AND triggers mainline it87 self-disable
Fan 1 Settings:
  Smart Fan 1 Mode = [Software Mode | Automatic | Manual]
  Manual PWM Setting = 0..255
Fan 2 Settings: ... same options
```

"Software Mode" yields chip control to the OS (Linux writes pwm sysfs). "Automatic" runs a BIOS-internal temperature curve. "Manual" pins PWM at the configured value. All three write to chip registers correctly.

#### Empirical behaviour

The chip is fully reachable from Linux. BIOS-side configuration round-trips through the chip into sysfs in one direction:

- BIOS `Fan 1 → Manual Mode, Manual PWM = 69` → sysfs `pwm1 = 69` after boot (round-trip confirmed).
- BIOS `Fan 2 → Manual Mode, Manual PWM = 89` → does NOT appear in any visible chip register; sysfs `pwm2` reads the chip's default (70).

Writing duty cycle 0..255 to **any** of the five exposed PWM channels via sysfs produces **zero audible change** to the physical fan. Direct port writes via `/dev/port` to the chip's PWM control + duty registers (offsets 0x15..0x17, 0x7f, 0xa7, 0xaf and 0x63, 0x6b, 0x73, 0x7b, 0xa3, 0xab from base `0xa20`) produce the same null result. `fan1_input` and `fan2_input` both read 0 RPM continuously. BIOS UI reports `Fan speed N/A` for both fans — the tach pin is also unread.

`isadump` of LDN 7 (GPIO / pin multiplexer) shows the pin-mux registers (0xc0+, 0xe0+) are populated by BIOS but LDN 7's `0x30 = 0x00` — the GPIO interface is not active. Without an IT8625E datasheet (proprietary, ITE NDA) the specific pin → function bindings cannot be decoded from the register contents.

#### What the data says

**Confirmed empirically — fan's PWM input is not electrically connected on this PCB.** Three independent control paths were tested, each writing the same value to the chip and producing the same observed result:

1. **Linux sysfs** — `echo 0 > pwm1` … `echo 255 > pwm1` across all five exposed channels (`pwm1`, `pwm2`, `pwm4`, `pwm5`, `pwm6`).
2. **Direct chip register writes via `/dev/port`** — bypassing the driver, writing to PWM control + duty registers at base+0x15..0x17, 0x7f, 0xa7, 0xaf and 0x63..0x6b..0x73..0x7b..0xa3..0xab.
3. **BIOS Setup Manual PWM Setting** at any value from 0 to 255 — BIOS writes directly into chip registers itself, bypassing the OS entirely.

All three observe the same outcome: the chip register accepts the value (sysfs round-trip from BIOS Fan 1 setting confirmed), and the physical fan RPM does not change. Since path 3 (BIOS) takes Linux out of the equation entirely, every software-side hypothesis is ruled out:

- ❌ Driver bug (Linux not running for path 3)
- ❌ OS-level pinmux / ACPI claim conflict (BIOS sees its own chip cleanly)
- ❌ POLARITY misconfiguration (tested with `ACTIVE HIGH` and `Manual PWM = 0` — fan unchanged)
- ❌ `pwm_mode()` return-value confusion ([issue #97](https://github.com/frankcrawford/it87/issues/97) bug — not applicable; BIOS bypasses our driver)

What's left as the sole explanation: the chip's PWM output pin (and the TACH input pin — `Fan speed N/A` in BIOS, `fan_input = 0` in sysfs) **is not electrically connected to the fan-header pin-3 / pin-4 traces on this PCB revision**. Either the trace is absent, or the chip's relevant pin is muxed to a different function that does not route to the header. The fan receives +12 V continuously regardless of any PWM duty value written anywhere; only the +12 V and GND wires of the header are wired to the chip's power-domain rails, not to its PWM/TACH controller pins.

Frank Crawford's response to a similar null-effect observation in [issue #20](https://github.com/frankcrawford/it87/issues/20) (Intel NUC J3455, same chip + revision) was the diagnostic question *"SuperIO chips implement many hardware low-level functions in the one chip, but nothing says that they all have to be used on every board. Does the board have an onboard fan?"* — in that thread it was asked as a diagnostic because the reporter's board genuinely had no fan attached; in our case the question can be re-applied with a definitive answer: there IS a fan, but it is not wired to the chip's PWM/TACH pins.

**IT8625E itself is not broken** — a separate reporter (amfern) in [issue #20](https://github.com/frankcrawford/it87/issues/20) got the same chip working on a BIOSTAR 650Q Racing board after patching `sensors-detect` to map IT8625E to `it87` (the only blocker there was lm-sensors' chip-table omission). The chip + `frankcrawford/it87` combination is known good when the PCB wiring is.

A diagnostic dump (sysfs hwmon state + `isadump` of LDN 4/5/7 + BIOS metadata + observed behaviour) is saved on the live box at `/root/it8625-diag/dump.txt`, suitable for attaching to a future frankcrawford/it87 issue if anyone with this CWWK SKU wants to chase the PCB trace question (would require oscilloscope or multimeter continuity testing — board schematics are not publicly available).

#### Thermal headroom — empirically safe to disconnect

`stress-ng --cpu 8 --vm 1 --vm-bytes 256M --timeout 300s` against N305 with the stock fan running, package and core temps as measured via `coretemp`:

```text
idle        30 °C
min 1       64 °C
min 2       62 °C
min 3       64 °C
min 4       67 °C   ← steady-state peak under 100% × 8 threads
cooldown    35 °C after 30 s
```

TjMAX on N305 is 105 °C, throttling begins ~95-100 °C. With the fan disconnected and router workload (1–10 % CPU average, AWG tunnel), package temp settles in the 50–60 °C range. Passive cooling is feasible for the intended use case; it does deviate from the manufacturer's intended thermal envelope.

#### Working paths to reduce noise

Each is independent of the OS-side PWM dead end:

1. **Physical disconnect** of the fan header. Box runs passive. Thermal data above supports this for router workload.
2. **Voltage drop** inline in the +12 V conductor of the fan cable — two 1N4007 diodes in series drop ~1.4 V, fan sees ~10.6 V, RPM and noise measurably lower.
3. **Fan replacement** with a quieter motor at the same form factor. The PCB header has no PWM control on this board, so 3-pin and 4-pin fans behave equivalently here (full speed always); pick a fan rated for low noise at +12 V.
4. **Standalone thermistor-driven controller** taking the fan cable out of the +12 V rail and running its own curve (~$5–10 on AliExpress, "automatic temperature fan speed controller").
5. **Accept the noise** if the box is in a closet / rack / non-bedroom location.

The combination most likely to retain "some cooling" without audibility is option 2 (diode drop) or option 4 (thermistor controller). Option 1 (disconnect) is the simplest if you accept passive operation.

### BIOS updates — where to get them

CWWK does not push BIOS updates automatically. To check whether your board has a newer BIOS, you navigate their download portal manually.

**Board identification.** This 2× SFP+ + 2× 2.5GbE N305 SKU is CWWK's internal **`CW-AL-(2L+SFP_4L)`** board, also marketed in Chinese as **「双光双电」** ("dual optical dual electrical"), part of the **AlderLake-N OMW SFP series**. DO NOT confuse with the visually-similar **`CW-WTM-ADLN-NET-4L-PCIe`** which is the 4× RJ45 LAN variant (no SFP+) and has different PCB revisions (V1.0A / V1.0B / V1.0C) with separate BIOS distribution.

**Current BIOS as shipped (verified on this build):**

```text
Vendor:     American Megatrends International, LLC.
Version:    5.27
Date:       06/14/2024
```

Read on the running system from `/sys/class/dmi/id/bios_version` and `/sys/class/dmi/id/bios_date`, or via `dmidecode --type bios`. Board / system DMI fields show `Default string` on this SKU — CWWK doesn't populate them — so DMI-based ID is only useful for the BIOS section.

**Download portal.** CWWK runs an AList-based file browser at **<https://drive.x86pi.com>** (`/BIOS` subtree). The HTTPS certificate has been expired for a long time; use `--insecure` with `curl` or accept the warning in the browser. Path for this board's BIOS:

```text
/BIOS/1.miniPC-BIOS/Alder_Lake-N(N50_N95_N97_N100_N200_i3-N305)/
  7.第12代AlderLake-N-OMW-N100-N305-SFP系列/
    AlderLake-N-OMW-N100-N305-SFP系列_<YYYY-MM-DD>更新/
      CW-AL-(2L+SFP_4L)-(双光双电N100-I3-N305出厂默认原始版本)<YYYY.MM.DD>_NoLogo.iso
```

The "更新" Chinese-suffixed dated subfolders are release pockets — pick the latest. Latest known at time of writing: **2024-09-26**, ISO ~19 MB, `NoLogo` variant (no splash screen, otherwise identical to logo variants of other boards).

**Programmatic listing** (when navigating the JS-rendered AList UI is annoying):

```sh
curl --silent --insecure --max-time 15 \
    --request POST 'https://drive.x86pi.com/api/fs/list' \
    --header 'Content-Type: application/json' \
    --data '{"path":"/BIOS/1.miniPC-BIOS/Alder_Lake-N(N50_N95_N97_N100_N200_i3-N305)/7.第12代AlderLake-N-OMW-N100-N305-SFP系列","page":1,"per_page":300}' \
    | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]["content"]; [print(c["name"], c.get("modified","")[:10]) for c in d]'

# Get raw download URL for a specific file (signed, valid for 4 hours):
curl --silent --insecure \
    --request POST 'https://drive.x86pi.com/api/fs/get' \
    --header 'Content-Type: application/json' \
    --data '{"path":"/BIOS/.../<filename>.iso"}' \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["raw_url"])'
```

The raw URL points at an Aliyun OSS bucket (`cwwp.oss-cn-heyuan.aliyuncs.com`) with a 4-hour-expiry signed query string.

**Flashing.** CWWK distributes BIOS as a bootable ISO. Procedure (not yet exercised on this build — documented from CWWK customer-support guidance):

1. `dd if=BIOS.iso of=/dev/sdX bs=4M conv=fsync` to a USB stick (sacrificial — the ISO is bootable and overwrites the stick).
2. Boot the CWWK with the USB plugged in. Hit BIOS menu, select USB as boot device.
3. ISO contains an `efiflash` autorun script that prompts for confirmation, then writes the new BIOS to flash. ~30-60 s, then auto-reboots.
4. After reboot, check `/sys/class/dmi/id/bios_date` to confirm the new date.

**Risks.** Power loss during flash bricks the board (no dual-BIOS / fallback ROM on this design AFAIK). Only flash when:
- A specific need exists (new fan-curve options, security fix, kernel-side feature like 82599ES quirks, etc.)
- The box is on a stable power source (UPS preferred).
- You have a recovery plan (CWWK customer support can sometimes RMA bricks; community knows USB-prog SPI flash recovery for AMI Aptio chips).

For the current single-pain-point of fan noise — if BIOS Smart Fan is already adequately tunable on the installed 2024-06-14 firmware, no BIOS update needed. Re-evaluate if a specific limitation surfaces.

**Other resources around CWWK:**

- Documentation: <https://doc.x86pi.cn> (Chinese)
- Community forum: <https://bbs.x86pi.com> — Chinese mini-PC enthusiasts, active CWWK section
- Top-level download portal: <https://www.changwang.com/downloads> (English-friendly dropdown, points at the same AList backend)

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

After `dd`, the NVMe has three partitions visible via `parted` on a running system: `p128` ~0.23 MiB `bios_grub`, `p1` 16 MiB FAT16 EFI System Partition, `p2` ~104 MiB Linux rootfs squashfs + overlay loop region. (`diskutil` on macOS reports the EFI partition as ~67 MB Windows_FAT_32; this is a diskutil display quirk, the actual partition is 16 MB FAT16 per parted on the running box.) ~99% of the device is unallocated tail — used in the resize step below.

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

Set a root password as a fallback if you want it (optional — if you're confident in the key, leave it empty and the password-auth disable in step 13 makes the shadow file irrelevant anyway):

```sh
passwd
```

### 4. Expand root partition to fill the NVMe

After `dd`, the partition layout has a ~104 MiB rootfs region and ~99% of the disk as unallocated tail (because the combined-efi image was sized for tiny flash devices). Without expansion, `/overlay` ends up ~86 MB — runs out of room as soon as you `apk add` more than a couple of packages. The expand is online, takes ~20 seconds, no reboot needed:

```sh
# Resize tools are not in the base image.
apk update
apk add parted losetup resize2fs

# Identify the root disk (resolves nvme0n1 / sda / etc.) from the kernel
# cmdline so this snippet works regardless of where OpenWrt was flashed.
ROOT_DISK="/dev/$(awk -F'/dev/' '/root=/{print $2}' /proc/cmdline | cut -d' ' -f1 | sed 's/p\?[0-9]*$//')"
echo "root disk: ${ROOT_DISK}"   # expect /dev/nvme0n1 on this hardware

# Fix the GPT: the combined-efi image's backup-header location was set
# for the image size, not your actual disk. parted detects this and
# offers a Fix prompt when you ask it to print. Auto-answer "Fix":
echo "Fix" | parted ---pretend-input-tty "${ROOT_DISK}" print

# Resize partition 2 (the Linux rootfs region) to use 100% of the disk.
parted --script "${ROOT_DISK}" resizepart 2 100%

# Refresh the kernel's view of the partition table. BusyBox does not
# ship `partprobe`; `partx -u` is in the `partx` binary that landed
# alongside util-linux on x86_64 OpenWrt.
partx -u "${ROOT_DISK}"

# Grow the ext4 filesystem inside /dev/loop0 (which is the overlay
# device, backed by the partition we just resized). resize2fs supports
# online expansion on a mounted filesystem.
#
# Note: busybox `losetup` does NOT support `--capacity` (long flag) to
# tell the loop device about the resized backing. `partx -u` above
# already triggered that refresh implicitly via the partition event.
resize2fs /dev/loop0
```

After this, `df -h | grep /overlay` should report close to the full disk size:

```text
/dev/loop0              438.1G     29.6M    423.0G   0% /overlay
overlayfs:/overlay      438.1G     29.6M    423.0G   0% /
```

Verified empirically on a 500 GB WD Green SN350: from 86 MB to 438 GB overlay, online, ~15 seconds end-to-end.

The resize is permanent — it lives in the GPT on disk, survives reboot and sysupgrade. No further action needed.

### 5. Identify physical port → interface mapping

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

### 6. AmneziaWG packages

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

`luci-proto-amneziawg` is installed but then immediately removed in step 13 (LuCI removal) — it's only needed transiently to register the proto handler with netifd. The kernel module + userspace tools stay.

### 7. DNS, full-iproute2, watchdog packages

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

### 8. Drop in the configs

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

### 9. Patch dnsmasq init to run as root

Required because the `nftset=/domain/...` directives in `/etc/dnsmasq.d/allow-domains.conf` need `CAP_NET_ADMIN` to actually write into the nft sets. The default `dnsmasq` user inside the ujail sandbox does not have that capability — the directives parse silently but `nft list set inet fw4 allow_domains_v4` stays empty.

```sh
sed -i \
    -e 's|xappend "--user=dnsmasq"|xappend "--user=root"|' \
    -e 's|xappend "--group=dnsmasq"|xappend "--group=root"|' \
    /etc/init.d/dnsmasq
/etc/init.d/dnsmasq restart
```

`post-upgrade.sh` re-applies this on every boot if a sysupgrade resets the init script.

### 10. Drop in the scripts + crontab

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

### 11. Activate

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

### 12. Verify

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

### 13. Disable password auth + remove LuCI

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

Removal command in step 13 of the walkthrough above. `post-upgrade.sh` does **not** re-install any of these on sysupgrade — the comments in the script call out the omission explicitly.

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

- **`awg-watchdog`** — runs every 2 minutes from cron. Reads `awg show awg0 latest-handshakes`, checks how long ago the last handshake was. If older than 180 s (6× the 30 s keepalive interval — generous, accounts for transient WAN flaps without false-positive bounces), it bounces `awg0` with `ifdown` + `ifup`. This also serves as failover trigger when the WAN endpoint route goes stale.

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
