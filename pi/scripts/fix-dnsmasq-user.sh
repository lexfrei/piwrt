#!/bin/sh
# /usr/bin/fix-dnsmasq-user
#
# Patch /etc/init.d/dnsmasq so that dnsmasq runs as root instead of the
# default `dnsmasq` user. Needed because `nftset=/domain/...` directives
# from /etc/dnsmasq.d/allow-domains.conf require CAP_NET_ADMIN to
# actually write into the nft set — the default `dnsmasq` user inside
# the ujail sandbox doesn't have that capability.
#
# Symptom without this fix: dnsmasq log shows a successful resolve,
# nftset directive is syntactically correct in the generated config,
# but `nft list set inet fw4 allow_domains_v4` stays empty.
#
# Apply once after install and after every apk upgrade that replaces
# /etc/init.d/dnsmasq. Idempotent — running it twice is harmless.
#
# Proper long-term fix (upstream): create /etc/capabilities/dnsmasq.json
# granting cap_net_admin and add `procd_set_param capabilities ...` in
# the init script. OpenWrt 25.12 dnsmasq-full does not ship this.

set -eu

INIT=/etc/init.d/dnsmasq

if ! grep -q 'xappend "--user=dnsmasq"' "$INIT" && grep -q 'xappend "--user=root"' "$INIT"; then
    echo "Already patched."
    exit 0
fi

sed -i \
    -e 's|xappend "--user=dnsmasq"|xappend "--user=root"|' \
    -e 's|xappend "--group=dnsmasq"|xappend "--group=root"|' \
    "$INIT"

echo "Patched $INIT: dnsmasq will now run as root."
echo "Restart dnsmasq for the change to take effect:"
echo "    /etc/init.d/dnsmasq restart"
