#!/bin/bash
#
# Tests whether SimVirtualLocation could drive your iPhone over Wi-Fi
# instead of a USB cable.
#
# Two steps, in this order:
#
#   bash wifi-check.sh enable    <- run this WITH the cable plugged in
#   bash wifi-check.sh test      <- then UNPLUG the cable and run this
#
# "enable" throws the switch Xcode would normally throw (Connect via
# network). Without it usbmuxd never advertises the phone off the cable,
# which is why the first run found nothing.

set -u

PMD=$(command -v pymobiledevice3 || true)
if [ -z "$PMD" ]; then
    echo "pymobiledevice3 not found in PATH."
    exit 1
fi

line() { printf '\n=== %s ===\n' "$1"; }

MODE="${1:-}"
if [ "$MODE" != "enable" ] && [ "$MODE" != "test" ]; then
    echo "Usage:"
    echo "  bash $0 enable    with the cable plugged in"
    echo "  bash $0 test      with the cable unplugged"
    exit 1
fi

line "version"
"$PMD" version 2>&1 | head -2

if [ "$MODE" = "enable" ]; then
    line "devices on the cable"
    "$PMD" --no-color usbmux list -u 2>&1 | head -20

    line "current wifi-connections state"
    "$PMD" --no-color lockdown wifi-connections 2>&1 | tail -5

    line "turning wifi connections ON"
    "$PMD" --no-color lockdown wifi-connections --state on 2>&1 | tail -5

    line "state now"
    "$PMD" --no-color lockdown wifi-connections 2>&1 | tail -5

    line "next"
    echo "Now UNPLUG the cable, wait about ten seconds, then run:"
    echo "    bash $0 test"
    exit 0
fi

line "1. network-visible devices (cable should be unplugged)"
NET=$("$PMD" --no-color usbmux list -n 2>&1 || true)
echo "$NET"

UDID=$(echo "$NET" | sed -n 's/.*"Identifier": *"\([^"]*\)".*/\1/p' | head -1)
[ -z "$UDID" ] && UDID=$(echo "$NET" | sed -n 's/.*"UniqueDeviceID": *"\([^"]*\)".*/\1/p' | head -1)

if [ -z "$UDID" ]; then
    echo
    echo "No network device. Either the cable is still in, the enable step"
    echo "did not take, or the Mac and phone are on different networks."
    echo "Check both are on the same Wi-Fi, then re-run the enable step."
else
    echo
    echo "Found over the network. UDID: $UDID"
fi

line "2. bonjour browse (needs root on this version)"
sudo -v 2>/dev/null || echo "(no sudo; skipping the parts that need it)"
sudo "$PMD" --no-color remote browse --timeout 5 2>&1 | tail -15

line "3. userspace tunnel over bonjour, NO root"
echo "This is the route that would need almost no change to the app."
if [ -n "$UDID" ]; then
    "$PMD" --no-color developer dvt simulate-location set --userspace --mobdev2 --udid "$UDID" -- 25.164536 51.547495 2>&1 | tail -15
else
    "$PMD" --no-color developer dvt simulate-location set --userspace --mobdev2 -- 25.164536 51.547495 2>&1 | tail -15
fi
echo
echo "If that printed no error, LOOK AT YOUR PHONE in Maps now."
echo "Press Return when you have looked."
read -r _

line "4. privileged Wi-Fi tunnel"
TUNLOG=$(mktemp)
sudo "$PMD" remote start-tunnel -t wifi --script-mode > "$TUNLOG" 2>&1 &
TUNPID=$!
echo "waiting up to 30s for a tunnel address..."
RSD=""
for i in $(seq 1 30); do
    sleep 1
    RSD=$(grep -Eo '[0-9a-fA-F:.]+ [0-9]+' "$TUNLOG" | head -1 || true)
    [ -n "$RSD" ] && break
done

if [ -z "$RSD" ]; then
    echo "No tunnel came up. Output was:"
    cat "$TUNLOG"
else
    HOST=$(echo "$RSD" | awk '{print $1}')
    PORT=$(echo "$RSD" | awk '{print $2}')
    echo "Tunnel up at $HOST $PORT"
    line "5. setting a location over that tunnel"
    "$PMD" --no-color developer dvt simulate-location set --rsd "$HOST" "$PORT" -- 25.164536 51.547495 2>&1 | tail -15
    echo
    echo "LOOK AT YOUR PHONE again. Doha means wireless works end to end."
    echo "Those two numbers, $HOST and $PORT, are what go in the app's"
    echo "Manual RSD fields, which means no code change at all."
    echo "Press Return when you have looked."
    read -r _
    "$PMD" --no-color developer dvt simulate-location clear --rsd "$HOST" "$PORT" 2>&1 | tail -3
fi

sudo kill "$TUNPID" 2>/dev/null || true
rm -f "$TUNLOG"
line "done"
