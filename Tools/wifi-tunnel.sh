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

line "4. Wi-Fi tunnel (needs your admin password)"
sudo -v || exit 1
TOUT=$(mktemp); TERR=$(mktemp)
# stdin from /dev/null: if it tries to prompt for which device, fail loudly
# rather than hang forever waiting on a keypress.
sudo "$PMD" lockdown start-tunnel --mobdev2 --udid "$UDID" --script-mode \
    < /dev/null > "$TOUT" 2>"$TERR" &
TPID=$!
echo "waiting up to 40s..."
RSD=""
for i in $(seq 1 40); do
    sleep 1
    RSD=$(grep -oE '^[0-9a-fA-F:.%]+[[:space:]]+[0-9]{2,5}$' "$TOUT" | head -1 || true)
    [ -n "$RSD" ] && break
    kill -0 $TPID 2>/dev/null || break
done

if [ -z "$RSD" ]; then
    echo "No tunnel. stdout:"; cat "$TOUT"
    echo "stderr (last 25):"; tail -25 "$TERR"
    sudo kill $TPID 2>/dev/null
    rm -f "$TOUT" "$TERR"
    exit 1
fi
HOST=$(echo "$RSD" | awk '{print $1}')
PORT=$(echo "$RSD" | awk '{print $2}')
echo "TUNNEL UP: host=$HOST port=$PORT"

line "5. developer disk image"
"$PMD" --no-color mounter auto-mount --rsd "$HOST" "$PORT" 2>&1 | tail -5 || true

line "6. setting the location over Wi-Fi"
echo "(this command blocks by design - it holds the location while it runs)"
"$PMD" --no-color developer dvt simulate-location set --rsd "$HOST" "$PORT" -- "$LAT" "$LON" \
    > /tmp/simloc.log 2>&1 &
SPID=$!
sleep 12
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
sudo kill $TPID 2>/dev/null
rm -f "$TOUT" "$TERR"
echo "tunnel closed"
