#!/bin/sh
# /etc/hotplug.d/iface/90-split-vpn
#
# On wan up: install the ip rule / ip route that carries fwmark-0x100
# traffic (matched by 50-allow-domains.nft) out via eth0 instead of
# the default awg0 tunnel.
#
# Also pin the Russian DNS resolver (77.88.8.8) to eth0 so that
# `server=/domain/77.88.8.8` directives from allow-domains.conf do
# not accidentally tunnel through awg0.

TABLE_ID=100
FWMARK='0x100'
RULE_PREF=100
RU_RESOLVER='77.88.8.8'

if [ "$INTERFACE" != 'wan' ]; then
    exit 0
fi

case "$ACTION" in
    ifup)
        WAN_GW=$(ip -4 route show dev eth0 | awk '/^default/ {print $3; exit} /proto dhcp/ {print $3; exit}')
        if [ -z "$WAN_GW" ]; then
            # netifd stores the router hop separately during dhcp
            WAN_GW=$(ifstatus wan 2>/dev/null | awk -F'"' '/"nexthop":/ {print $4; exit}')
        fi
        if [ -z "$WAN_GW" ]; then
            logger -t split-vpn "ifup wan: cannot determine WAN gateway, skipping"
            exit 0
        fi

        ip rule del fwmark "$FWMARK" lookup "$TABLE_ID" 2>/dev/null
        ip rule add fwmark "$FWMARK" lookup "$TABLE_ID" pref "$RULE_PREF"

        ip route flush table "$TABLE_ID" 2>/dev/null
        ip route add default via "$WAN_GW" dev eth0 table "$TABLE_ID"
        ip route replace "$RU_RESOLVER/32" via "$WAN_GW" dev eth0

        logger -t split-vpn "ifup wan: fwmark $FWMARK → table $TABLE_ID via $WAN_GW dev eth0"
        ;;
    ifdown)
        ip rule del fwmark "$FWMARK" lookup "$TABLE_ID" 2>/dev/null
        ip route flush table "$TABLE_ID" 2>/dev/null
        ip route del "$RU_RESOLVER/32" 2>/dev/null
        logger -t split-vpn "ifdown wan: split-VPN routes cleared"
        ;;
esac
