#!/bin/sh
# /usr/share/piwrt/post-upgrade.sh
#
# Idempotent re-install of every custom package piwrt-on-CWWK needs.
# OpenWrt sysupgrade only preserves /etc/config/* and /etc/sysupgrade.conf
# entries — installed packages are wiped, so we re-add them on every boot
# where they are missing. apk's "already installed" check makes this cheap
# in the steady state (just a metadata read).
#
# Invoked from /etc/rc.local on every boot. Runs async so boot is not held
# up; first run after sysupgrade is the only time it actually does work.

set -eu

VERSION="v25.12.4"
ARCH="x86_64"
AWG_URL="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/${VERSION}"

log() { logger -t piwrt-post-upgrade "$*"; echo "$*"; }

# Wait until WAN has a working route AND working DNS for the OpenWrt
# repo hostname. Ping alone is not enough — `apk update` resolves
# downloads.openwrt.org, and dnsmasq/https-dns-proxy may not be ready yet
# when WAN is technically up.
wait_for_wan() {
	for _ in $(seq 1 60); do
		if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 \
		   && nslookup downloads.openwrt.org >/dev/null 2>&1; then
			return 0
		fi
		sleep 2
	done
	log "WAN+DNS never came up after 120s, aborting"
	return 1
}

wait_for_wan || exit 1

# apk update is a soft requirement — packages we want to install/check are
# already on disk after sysupgrade (or were never wiped on a plain reboot).
# Refreshing the index lets `apk add` pick up newer versions if any, but
# failure here is recoverable: the apk-add steps below operate on whatever
# index is cached.
log "apk update"
apk update >/dev/null 2>&1 || log "apk update failed (continuing with cached index)"

# libustream-mbedtls — provides TLS for OpenWrt's full wget. The LuCI
# cleanup pulls this in via dependency chain on first install, but a
# fresh sysupgrade doesn't keep it. Without it `wget https://...` fails
# with "SSL support not available", which breaks AWG package re-download
# and any other HTTPS curl/wget operation from the router.
log "ensuring libustream-mbedtls (HTTPS for wget)"
apk add libustream-mbedtls >/dev/null 2>&1 || true

# ip-full — BusyBox ip applet has no multipath support, so the
# split-VPN hotplug ECMP route silently fails on default install.
log "ensuring ip-full (multipath route support)"
apk add ip-full >/dev/null 2>&1 || true

# dnsmasq-full — base dnsmasq has no nftset support; split-VPN needs it.
if ! apk list --installed 2>/dev/null | grep -q '^dnsmasq-full '; then
	log "replacing base dnsmasq with dnsmasq-full"
	apk del dnsmasq >/dev/null 2>&1 || true
	apk add dnsmasq-full >/dev/null 2>&1
fi

# mwan3 NOT installed — we use kernel-native ECMP + hotplug for dual-WAN.
# See /etc/hotplug.d/iface/90-split-vpn for the WAN-group logic.

# https-dns-proxy — DoH listener on 127.0.0.1:5053. No LuCI app — we run
# headless (no web UI), all admin via SSH/UCI.
log "ensuring https-dns-proxy"
apk add https-dns-proxy >/dev/null 2>&1 || true

# vnstat2 — traffic accounting per WAN / awg0. Database in
# /var/lib/vnstat/ is preserved across sysupgrade via sysupgrade.conf.
log "ensuring vnstat2"
apk add vnstat2 >/dev/null 2>&1 || true

# AmneziaWG — kmod tied to a specific kernel ABI, so re-download every time.
if ! awg --version >/dev/null 2>&1; then
	log "AWG missing, installing"
	apk add kmod-udptunnel4 kmod-udptunnel6 \
		kmod-crypto-lib-chacha20poly1305 kmod-crypto-lib-curve25519 \
		>/dev/null 2>&1
	cd /tmp
	for pkg in kmod-amneziawg amneziawg-tools luci-proto-amneziawg; do
		# Slava-Shchipunov's x86_64 release artefacts carry the arch
		# twice in the filename: <pkg>_v<ver>_x86_64_x86_64.apk. The
		# extra suffix is the OpenWrt target subarch; on aarch64 it's
		# bare, on x86_64 it doubles up.
		f="${pkg}_${VERSION}_${ARCH}_${ARCH}.apk"
		wget -q -O "/tmp/${f}" "${AWG_URL}/${f}" || { log "AWG download ${f} failed"; exit 1; }
	done
	apk add --allow-untrusted \
		/tmp/kmod-amneziawg_*.apk \
		/tmp/amneziawg-tools_*.apk \
		/tmp/luci-proto-amneziawg_*.apk >/dev/null 2>&1
	modprobe amneziawg
	rm -f /tmp/kmod-amneziawg_*.apk /tmp/amneziawg-tools_*.apk /tmp/luci-proto-amneziawg_*.apk
fi

# Patch /etc/init.d/dnsmasq so dnsmasq runs as root — required because
# nftset directives need CAP_NET_ADMIN to write into nft sets, and the
# default `dnsmasq` user inside the ujail sandbox doesn't have it.
INIT=/etc/init.d/dnsmasq
if grep -q 'xappend "--user=dnsmasq"' "$INIT" 2>/dev/null; then
	log "patching $INIT (user/group → root)"
	sed -i \
		-e 's|xappend "--user=dnsmasq"|xappend "--user=root"|' \
		-e 's|xappend "--group=dnsmasq"|xappend "--group=root"|' \
		"$INIT"
	/etc/init.d/dnsmasq restart
fi

# Regenerate bypass-list if missing (sysupgrade wipes /etc/dnsmasq.d/).
if [ ! -s /etc/dnsmasq.d/allow-domains.conf ] && [ -x /usr/bin/update-bypass-list ]; then
	log "bypass-list missing, regenerating"
	/usr/bin/update-bypass-list >/dev/null 2>&1 || log "update-bypass-list failed (cron will retry weekly)"
fi

log "restarting services"
/etc/init.d/network reload >/dev/null 2>&1 || true
/etc/init.d/firewall reload >/dev/null 2>&1 || true
/etc/init.d/https-dns-proxy enable >/dev/null 2>&1 || true
/etc/init.d/https-dns-proxy restart >/dev/null 2>&1 || true
/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true

# Pause before ifup awg0 — dnsmasq restart above briefly tears down the
# DNS chain (dnsmasq → https-dns-proxy → DoH). The AmneziaWG proto handler
# resolves endpoint_host via that chain; if it queries during the restart
# window, glibc gets connection refused / timeout, the handler enters
# its retry-with-backoff loop (1s, 1.2s, 1.44s, ..., ~12 attempts) and
# eventually gives up with the interface in DOWN state. 3 seconds is
# enough for dnsmasq to bind 127.0.0.1:53 and accept queries again.
#
# Even with this guard, endpoint_host should be an IP literal in
# /etc/config/network for the most robust boot — see the chicken-and-egg
# note in README. The sleep is belt-and-suspenders.
sleep 3
ifup awg0 >/dev/null 2>&1 || true

log "done"
