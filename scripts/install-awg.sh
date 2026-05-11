#!/bin/sh
# Install AmneziaWG v2 on OpenWrt 25.12.x for RPi5 (bcm27xx/bcm2712).
#
# OpenWrt 25.x uses apk-tools instead of opkg. Slava-Shchipunov ships
# pre-built .apk files for the bcm2712 target; this script downloads
# the three we need and installs them with apk.
#
# Run on the router after the WAN has a default route and DNS works.
#
#   sh /tmp/install-awg.sh
#
# Or directly over ssh from your workstation:
#
#   ssh root@<WAN_IP> 'sh -s' < scripts/install-awg.sh

set -eu

VERSION="v25.12.3"
ARCH="aarch64_cortex-a76_bcm27xx_bcm2712"
URL="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/${VERSION}"

cd /tmp

for pkg in kmod-amneziawg amneziawg-tools luci-proto-amneziawg; do
    f="${pkg}_${VERSION}_${ARCH}.apk"
    echo "Downloading ${f}"
    wget -q -O "/tmp/${f}" "${URL}/${f}"
done

apk update

apk add --allow-untrusted \
    /tmp/kmod-amneziawg_*.apk \
    /tmp/amneziawg-tools_*.apk \
    /tmp/luci-proto-amneziawg_*.apk

modprobe amneziawg
awg --version

# netifd needs a restart so it picks up the freshly-installed
# amneziawg proto handler at /lib/netifd/proto/amneziawg.sh
/etc/init.d/network restart

echo
echo "AmneziaWG installed. Next:"
echo "  1. Fill in /etc/config/network with the awg0 interface + peer"
echo "     (see configs/network in this repo). UCI keys use the awg_ prefix."
echo "  2. uci commit network && ifup awg0"
echo "  3. awg show awg0   # verify handshake and obfuscation params"
