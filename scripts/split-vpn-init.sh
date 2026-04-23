#!/bin/sh
# /etc/hotplug.d/iface/90-split-vpn
#
# Maintains split-VPN routing across any uplink listed in WAN_IFACES
# (default eth-backed `wan` and USB-backed `wwan`). On ifup/ifdown of
# any member, picks the active uplink with the lowest metric, rebuilds
# table 100 to go through it, and pins the Russian DNS resolver
# (77.88.8.8) to the same uplink so it never leaks through awg0.
#
# To add a new uplink (say a 4G dongle as `wwan2`): add it to
# WAN_IFACES below, put it into firewall zone `wan`, and set a higher
# `option metric` than the primary uplink so failover picks it last.

WAN_IFACES='wan wwan'
TABLE_ID=100
FWMARK='0x100'
RULE_PREF=100
RU_RESOLVER='77.88.8.8'

# Quick exit if this hotplug event isn't for one of our WAN members.
in_wan_group=0
for i in $WAN_IFACES; do
    [ "$INTERFACE" = "$i" ] && in_wan_group=1 && break
done
[ "$in_wan_group" = '1' ] || exit 0

# Returns "<gateway> <device>" for the lowest-metric up WAN, or empty.
pick_primary_wan() {
    best_metric=999999
    best_gw=''
    best_dev=''
    for iface in $WAN_IFACES; do
        status=$(ifstatus "$iface" 2>/dev/null)
        [ -z "$status" ] && continue
        [ "$(echo "$status" | jsonfilter -e '@.up' 2>/dev/null)" = 'true' ] || continue
        metric=$(echo "$status" | jsonfilter -e '@.metric' 2>/dev/null)
        [ -z "$metric" ] && metric=0
        gw=$(echo "$status" | jsonfilter -e '@.route[0].nexthop' 2>/dev/null)
        dev=$(echo "$status" | jsonfilter -e '@.l3_device' 2>/dev/null)
        [ -n "$gw" ] && [ -n "$dev" ] || continue
        if [ "$metric" -lt "$best_metric" ]; then
            best_metric=$metric
            best_gw=$gw
            best_dev=$dev
        fi
    done
    [ -n "$best_gw" ] && echo "$best_gw $best_dev"
}

apply_routes() {
    gw="$1"
    dev="$2"
    ip rule del fwmark "$FWMARK" lookup "$TABLE_ID" 2>/dev/null
    ip rule add fwmark "$FWMARK" lookup "$TABLE_ID" pref "$RULE_PREF"
    ip route flush table "$TABLE_ID" 2>/dev/null
    ip route add default via "$gw" dev "$dev" table "$TABLE_ID"
    ip route replace "$RU_RESOLVER/32" via "$gw" dev "$dev"
    logger -t split-vpn "$ACTION $INTERFACE: primary WAN = $dev ($gw); table $TABLE_ID + $RU_RESOLVER pinned"
}

clear_routes() {
    ip route flush table "$TABLE_ID" 2>/dev/null
    ip route del "$RU_RESOLVER/32" 2>/dev/null
    logger -t split-vpn "$ACTION $INTERFACE: no active WAN; table $TABLE_ID + $RU_RESOLVER cleared"
}

case "$ACTION" in
    ifup|ifupdate)
        sleep 2   # wait for netifd to install routes
        set -- $(pick_primary_wan)
        if [ -n "$1" ] && [ -n "$2" ]; then
            apply_routes "$1" "$2"
        else
            clear_routes
        fi
        ;;
    ifdown)
        sleep 1
        set -- $(pick_primary_wan)
        if [ -n "$1" ] && [ -n "$2" ]; then
            # Another WAN still up — switch to it
            apply_routes "$1" "$2"
        else
            clear_routes
        fi
        ;;
esac
