#!/bin/bash
#
# Sets a simulated location over Wi-Fi (iPhone Personal Hotspot), no cable.
#
#   bash wifi-tunnel.sh setup    <- ONCE, with the cable plugged in
#   bash wifi-tunnel.sh go       <- then unplug and run this
#
# Nothing here re-pairs the phone or touches the system pair record in
# /var/db/lockdown. "setup" only EXPORTS the pairing you already have.

set -u
UDID="00008130-001C39CC0411401C"
PMD=$(command -v pymobiledevice3 || true)
REC="$HOME/.pymobiledevice3/$UDID.plist"
LAT="40.690008"
LON="-74.045843"

line() { printf '\n=== %s ===\n' "$1"; }
[ -z "$PMD" ] && { echo "pymobiledevice3 not in PATH"; exit 1; }

MODE="${1:-}"
[ "$MODE" != "setup" ] && [ "$MODE" != "go" ] && {
    echo "Usage: bash $0 setup    (cable in, once)"
    echo "       bash $0 go       (cable out)"
    exit 1
}

if [ "$MODE" = "setup" ]; then
    line "device on the cable"
    "$PMD" --no-color usbmux list -u 2>&1 | grep -E "UniqueDeviceID|ProductVersion" || {
        echo "No device on USB. Plug the cable in for this step."; exit 1; }

    line "developer mode"
    "$PMD" --no-color amfi developer-mode-status 2>&1 | tail -3 || true

    line "exporting the EXISTING pair record (does not re-pair)"
    mkdir -p "$HOME/.pymobiledevice3"
    "$PMD" --no-color lockdown save-pair-record "$REC" 2>&1 | tail -5
    if [ -f "$REC" ]; then
        echo "wrote $REC"
        echo "WiFiMACAddress currently in it:"
        plutil -extract WiFiMACAddress raw "$REC" 2>/dev/null || echo "  (key absent)"
    else
        echo "FAILED to write the record."
        exit 1
    fi

    line "wifi connections"
    "$PMD" --no-color lockdown wifi-connections --state on 2>&1 | tail -3 || true

    line "next"
    echo "UNPLUG the cable, make sure this Mac is on the phone's hotspot, then:"
    echo "    bash $0 go"
    exit 0
fi

line "0. sanity"
if "$PMD" --no-color usbmux list -u 2>/dev/null | grep -q UniqueDeviceID; then
    echo "A device is on USB. Unplug it - this must be proven cable-free."
    exit 1
fi
echo "no cable, good"
[ -f "$REC" ] || { echo "No pair record at $REC. Run: bash $0 setup"; exit 1; }

STRAY=$(ls "$HOME/.pymobiledevice3"/*.plist 2>/dev/null | grep -v "remote_" | grep -vc "$UDID" || true)
[ "${STRAY:-0}" -gt 0 ] && echo "note: other pair records present; a record missing WiFiMACAddress crashes --mobdev2"

line "1. the MAC the phone advertises over the hotspot"
OUT=$(mktemp)
dns-sd -B _apple-mobdev2._tcp local. > "$OUT" 2>&1 & D=$!
sleep 7; kill $D 2>/dev/null
ADV=$(grep -oE '[0-9a-f]{2}(:[0-9a-f]{2}){5}@' "$OUT" | head -1 | tr -d '@')
rm -f "$OUT"
[ -z "$ADV" ] && { echo "Phone is not advertising. Check hotspot + phone unlocked."; exit 1; }
echo "advertised: $ADV"

HAVE=$(plutil -extract WiFiMACAddress raw "$REC" 2>/dev/null || echo "")
echo "in record : ${HAVE:-（absent）}"

line "2. making the record match"
# The mobdev2 lookup keys pair records purely by WiFiMACAddress and never
# validates it against the device, so correcting it here is legitimate.
# A hotspot AP interface uses a locally administered MAC, which is why this
# almost never matches the hardware address written at pair time.
if [ "$HAVE" = "$ADV" ]; then
    echo "already matches, nothing to do"
else
    cp "$REC" "$REC.backup" && echo "backed up to $REC.backup"
    plutil -replace WiFiMACAddress -string "$ADV" "$REC" && echo "set WiFiMACAddress to $ADV"
fi

line "3. can pymobiledevice3 itself resolve the phone?"
echo "(dns-sd only proves a PTR record; this needs SRV + address too)"
BJ=$("$PMD" --no-color bonjour mobdev2 --timeout 10 2>&1 || true)
echo "$BJ" | head -30
echo "$BJ" | grep -q "$UDID" || {
    echo
    echo "HARD STOP: pymobiledevice3's own browser cannot resolve the phone."
    echo "Everything below depends on this. Nothing further will work."
    exit 1
}
echo "--> resolved"

line "4. Wi-Fi tunnel via tunneld (needs your admin password)"
# start-tunnel stops to ask which lockdown to use, because the phone answers
# on both IPv4 and IPv6 and each address becomes a separate candidate. There
# is no flag to pick one. tunneld has no such prompt: its mobdev2 monitor
# skips any UDID it already holds a tunnel for, so the duplicates collapse to
# one tunnel, and --tunnel <UDID> then selects it by identity.
sudo -v || exit 1

if curl -s --max-time 2 http://127.0.0.1:49151/ > /dev/null 2>&1; then
    echo "a tunneld is already running; using it"
    OWN_TUNNELD=no
else
    TDLOG=$(mktemp)
    sudo "$PMD" remote tunneld > "$TDLOG" 2>&1 &
    TDPID=$!
    OWN_TUNNELD=yes
    echo "started tunneld, waiting up to 60s for it to find the phone..."
fi

FOUND=no
for i in $(seq 1 60); do
    sleep 1
    TUNNELS=$(curl -s --max-time 2 http://127.0.0.1:49151/ 2>/dev/null || true)
    case "$TUNNELS" in *"$UDID"*) FOUND=yes; break;; esac
done

if [ "$FOUND" != "yes" ]; then
    echo "tunneld never produced a tunnel for $UDID."
    echo "last API response: ${TUNNELS:-<none>}"
    [ "${OWN_TUNNELD:-no}" = "yes" ] && { echo "tunneld log (last 30):"; tail -30 "$TDLOG"; sudo kill $TDPID 2>/dev/null; rm -f "$TDLOG"; }
    exit 1
fi
echo "TUNNEL UP for $UDID"
echo "$TUNNELS" | head -c 400; echo

line "5. developer disk image"
"$PMD" --no-color mounter auto-mount --tunnel "$UDID" 2>&1 | tail -5 || true

line "6. setting the location over Wi-Fi"
echo "(this command blocks by design - it holds the location while it runs)"
"$PMD" --no-color developer dvt simulate-location set --tunnel "$UDID" -- "$LAT" "$LON" \
    > /tmp/simloc.log 2>&1 &
SPID=$!
sleep 15
echo "--- output so far ---"; tail -15 /tmp/simloc.log

if kill -0 $SPID 2>/dev/null; then
    echo
    echo "STILL RUNNING - that is the success shape."
    echo "LOOK AT YOUR PHONE in Maps. It should be on Liberty Island, New York."
    echo "Press Return when you have looked."
    read -r _
else
    echo; echo "It exited, which means it failed. See above."
fi

line "cleanup"
kill $SPID 2>/dev/null
if [ "${OWN_TUNNELD:-no}" = "yes" ]; then
    sudo kill $TDPID 2>/dev/null
    rm -f "$TDLOG"
    echo "tunneld stopped"
else
    echo "left the pre-existing tunneld running"
fi
