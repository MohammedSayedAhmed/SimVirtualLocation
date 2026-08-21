#!/bin/bash
#
# Works out WHY the phone is not visible over Wi-Fi.
#
#   bash wifi-diagnose.sh
#
# Run with the cable UNPLUGGED, phone awake and unlocked, on the same
# Wi-Fi as this Mac. Needs no admin password except for one optional step.

set -u
PMD=$(command -v pymobiledevice3 || true)
line() { printf '\n=== %s ===\n' "$1"; }

line "this Mac's network"
for i in en0 en1; do
    IP=$(ipconfig getifaddr $i 2>/dev/null || true)
    [ -n "$IP" ] && echo "$i address: $IP"
done
SSID=$(ipconfig getsummary en0 2>/dev/null | awk -F' SSID : ' '/ SSID : / {print $2; exit}')
[ -n "${SSID:-}" ] && echo "en0 SSID: $SSID" || echo "en0 SSID: (could not read)"

line "is the cable in?"
if [ -n "$PMD" ]; then
    U=$("$PMD" --no-color usbmux list -u 2>/dev/null || echo "[]")
    if echo "$U" | grep -q UniqueDeviceID; then
        echo "YES - a device is on USB. Unplug it, this test is meaningless with the cable in."
    else
        echo "No USB device. Good, that is what we want here."
    fi
fi

line "bonjour: does the phone advertise iTunes-style Wi-Fi sync?"
echo "(service _apple-mobdev2._tcp - this is what usbmuxd looks for)"
OUT1=$(mktemp)
dns-sd -B _apple-mobdev2._tcp local. > "$OUT1" 2>&1 &
D1=$!
sleep 7
kill $D1 2>/dev/null
grep -v "^Browsing\|^DATE\|^Timestamp\|STARTING" "$OUT1" | head -12
if grep -qE "Add.*_apple-mobdev2" "$OUT1"; then
    echo "--> FOUND. The phone is advertising on this network."
else
    echo "--> NOTHING. The phone is not advertising Wi-Fi sync on this network."
fi
rm -f "$OUT1"

line "bonjour: does the phone advertise RemoteXPC (iOS 17+ path)?"
echo "(service _remoted._tcp - this is what remote browse looks for)"
OUT2=$(mktemp)
dns-sd -B _remoted._tcp local. > "$OUT2" 2>&1 &
D2=$!
sleep 7
kill $D2 2>/dev/null
grep -v "^Browsing\|^DATE\|^Timestamp\|STARTING" "$OUT2" | head -12
if grep -qE "Add.*_remoted" "$OUT2"; then
    echo "--> FOUND."
else
    echo "--> NOTHING."
fi
rm -f "$OUT2"

line "any Apple devices at all on this network?"
echo "(if this is also empty, the network is blocking mDNS between clients)"
OUT3=$(mktemp)
dns-sd -B _airplay._tcp local. > "$OUT3" 2>&1 &
D3=$!
sleep 7
kill $D3 2>/dev/null
grep -cE "Add" "$OUT3" | awk '{print "airplay devices seen: " $1}'
rm -f "$OUT3"

line "usbmux network list"
[ -n "$PMD" ] && "$PMD" --no-color usbmux list -n 2>&1 | head -20

line "what this means"
echo "phone advertising + usbmux empty ...... pymobiledevice3 or pairing issue"
echo "phone not advertising, airplay seen ... phone Wi-Fi off, or different network"
echo "nothing at all, airplay 0 ............. router is blocking mDNS (client isolation)"
