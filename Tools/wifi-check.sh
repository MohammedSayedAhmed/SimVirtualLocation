#!/bin/bash
#
# Checks whether SimVirtualLocation could drive your iPhone over Wi-Fi
# instead of a USB cable. Read-only by default.
#
#   bash wifi-check.sh            discovery only, no admin password
#   bash wifi-check.sh --tunnel   also tries a real Wi-Fi tunnel (asks for sudo)
#
# Run it with the USB cable UNPLUGGED. That is the whole point: anything it
# finds while plugged in proves nothing about working without the cable.

set -u

PMD=$(command -v pymobiledevice3 || true)
if [ -z "$PMD" ]; then
    echo "pymobiledevice3 not found in PATH."
    echo "The app ships with its own copy; check /opt/homebrew/bin/pymobiledevice3"
    exit 1
fi

line() { printf '\n=== %s ===\n' "$1"; }

line "version"
"$PMD" version 2>&1 | head -3

line "1. all devices usbmuxd can see (USB and Wi-Fi)"
ALL=$("$PMD" --no-color usbmux list 2>&1 || true)
echo "$ALL"

line "2. network-only devices"
NET=$("$PMD" --no-color usbmux list -n 2>&1 || true)
echo "$NET"

line "3. RemoteXPC devices visible over bonjour"
BROWSE=$("$PMD" --no-color remote browse --timeout 5 2>&1 || true)
echo "$BROWSE"

NET_UDID=$(echo "$NET" | sed -n 's/.*"Identifier": *"\([^"]*\)".*/\1/p' | head -1)
if [ -z "$NET_UDID" ]; then
    NET_UDID=$(echo "$NET" | sed -n 's/.*"UniqueDeviceID": *"\([^"]*\)".*/\1/p' | head -1)
fi

line "VERDICT (discovery)"
if [ -n "$NET_UDID" ]; then
    echo "usbmuxd sees your phone over the network. UDID: $NET_UDID"
    echo "This is the piece the app is currently throwing away: it lists"
    echo "devices with 'usbmux list -u', and -u means USB only."
else
    echo "usbmuxd does NOT see the phone over the network."
    echo "Wi-Fi mode needs this, and turning it on normally needs Xcode"
    echo "(Devices and Simulators, Connect via network). Bonjour output in"
    echo "step 3 may still offer a way in without it."
fi

if [ "${1:-}" != "--tunnel" ]; then
    line "next"
    echo "To test an actual Wi-Fi tunnel and a real location set, re-run as:"
    echo "    bash $0 --tunnel"
    echo "That one asks for your admin password, because a kernel tunnel needs root."
    exit 0
fi

line "4. userspace tunnel over bonjour (no root)"
US=$("$PMD" --no-color developer dvt simulate-location set --userspace --mobdev2 -- 25.164536 51.547495 2>&1 || true)
echo "$US" | tail -20

line "5. privileged Wi-Fi tunnel"
echo "Asking for sudo so a kernel tunnel can be created..."
sudo -v || { echo "No sudo, skipping."; exit 0; }

TUNLOG=$(mktemp)
sudo "$PMD" remote start-tunnel -t wifi --script-mode > "$TUNLOG" 2>&1 &
TUNPID=$!
echo "waiting up to 25s for a tunnel address..."
RSD=""
for i in $(seq 1 25); do
    sleep 1
    RSD=$(grep -Eo '[0-9a-fA-F:]+ [0-9]+' "$TUNLOG" | head -1 || true)
    [ -n "$RSD" ] && break
done

if [ -z "$RSD" ]; then
    echo "No tunnel came up. Output was:"
    cat "$TUNLOG"
else
    echo "Tunnel address: $RSD"
    HOST=$(echo "$RSD" | awk '{print $1}')
    PORT=$(echo "$RSD" | awk '{print $2}')
    line "6. setting a location over the Wi-Fi tunnel"
    "$PMD" --no-color developer dvt simulate-location set --rsd "$HOST" "$PORT" -- 25.164536 51.547495 2>&1 | tail -20
    echo
    echo "Look at your phone in Maps now. If it shows Doha, wireless works."
    echo "Press Return when you have looked."
    read -r _
    "$PMD" --no-color developer dvt simulate-location clear --rsd "$HOST" "$PORT" 2>&1 | tail -5
fi

sudo kill "$TUNPID" 2>/dev/null || true
rm -f "$TUNLOG"
line "done"
