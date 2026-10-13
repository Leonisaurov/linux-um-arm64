#!/bin/sh
# Bring up the UML vector NIC in an Alpine guest: DHCP lease and DNS.
#
# This is the file a launcher may drop into the host share as
# <share>/umalpine-net.sh; /umarm-init sources it when it is there, so the DHCP
# logic can change without rebuilding the image. The same logic is inlined in
# /umarm-init as the fallback for boots with no launcher to inject it (the
# Android app).
#
# The interface is vec0 because that is what CONFIG_UML_NET_VECTOR names it;
# the first non-loopback interface is the fallback for a kernel whose NIC has
# another name.

IF=vec0
[ -d "/sys/class/net/$IF" ] || IF=$(ls /sys/class/net 2>/dev/null | grep -v '^lo$' | head -1)
[ -n "$IF" ] || { echo "umalpine-net: no network interface"; exit 0; }

ip link set lo up 2>/dev/null
ip link set "$IF" up 2>/dev/null

i=0
while [ "$i" -lt 3 ]; do
	udhcpc -i "$IF" -q -n -t 5 -T 3 2>&1 && break
	i=$((i + 1)); sleep 1
done

[ -s /etc/resolv.conf ] || echo "nameserver 1.1.1.1" > /etc/resolv.conf
