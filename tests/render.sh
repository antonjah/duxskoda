#!/bin/sh
# Renders the plugin headless with the real Dux components against a mock MyŠkoda server.
# Writes PNGs per scene plus quickshell.log to tests/render-output and checks the logged state.
# Needs: dms (or DMS_SHELL_DIR), qs, dbus-run-session, python3, Xvfb (or nix to fetch it). Runs in a
# private X server with temp XDG dirs and its own D-Bus session, so the running shell is untouched.
# Qt's offscreen platform cannot be used: Dux 2.1 needs a PanelWindow backend, which X11 provides.
# Nothing here can hang: every process has a timeout, and the cleanup trap kills what is left.
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
out="${DUXSKODA_OUT:-$repo/tests/render-output}"

shell_dir="${DMS_SHELL_DIR:-}"
if [ -z "$shell_dir" ]; then
    shell_dir="$(dirname "$(dirname "$(readlink -f "$(command -v dms)")")")/share/quickshell/dms"
fi
[ -f "$shell_dir/shell.qml" ] || { echo "Dux shell dir not found; set DMS_SHELL_DIR" >&2; exit 2; }

work=$(mktemp -d)
server_pid=
xvfb_pid=
qs_pid=
cleanup() {
    # Every step must run even when an earlier one fails (set -e would otherwise stop at the first kill).
    for pid in "$qs_pid" "$server_pid" "$xvfb_pid"; do
        [ -n "$pid" ] && { kill "$pid" 2>/dev/null || true; }
    done
    pkill -f "$work/harness" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$out" "$work/harness/Modules/Plugins" "$work/config/dms" "$work/config/skoda" "$work/cache" "$work/state" "$work/data" "$work/runtime" "$work/tokens"
chmod 700 "$work/runtime"
rm -f "$out"/*.png "$out"/*.log

# Harness shell dir: the real one with our shell.qml and a PluginComponent whose layer-shell popout is stubbed.
for e in "$shell_dir"/*; do
    case "${e##*/}" in shell.qml|Modules) ;; *) ln -s "$e" "$work/harness/" ;; esac
done
for e in "$shell_dir"/Modules/*; do
    [ "${e##*/}" = Plugins ] || ln -s "$e" "$work/harness/Modules/"
done
for e in "$shell_dir"/Modules/Plugins/*; do
    [ "${e##*/}" = PluginComponent.qml ] || ln -s "$e" "$work/harness/Modules/Plugins/"
done
awk '
    /^    PluginPopout \{/ { print "    QtObject { id: pluginPopout; property bool shouldBeVisible: false; function toggle() {} function close() {} function setTriggerPosition() {} }"; skip = 1; next }
    skip && /^    \}/ { skip = 0; next }
    !skip
' "$shell_dir/Modules/Plugins/PluginComponent.qml" > "$work/harness/Modules/Plugins/PluginComponent.qml"
grep -q 'id: pluginPopout' "$work/harness/Modules/Plugins/PluginComponent.qml" || { echo "PluginPopout stub failed; PluginComponent changed upstream" >&2; exit 2; }
cp "$repo/tests/render/shell.qml" "$work/harness/shell.qml"

# The key file's content is the mock server's scenario.
for k in heating idle charging plugged lowbat open partial noac expiring lowquota acdisabled acdeclined expired forbidden ratelimit server bogus; do
    printf '%s' "$k" > "$work/tokens/$k"
done
printf 'TMBTEST0123456789\n' > "$work/tokens/vin-ok"
printf 'short' > "$work/tokens/vin-bad"

port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 "$repo/tests/server.py" "$port" "$repo/tests/fixtures/vehicle.json" "$work/requests.log" &
server_pid=$!
sleep 1

xvfb=$(command -v Xvfb || printf '%s/bin/Xvfb' "$(timeout 120 nix build nixpkgs#xvfb --no-link --print-out-paths)")
"$xvfb" -displayfd 3 -screen 0 1280x1300x24 -nolisten tcp 3> "$work/display" 2> /dev/null &
xvfb_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$work/display" ] && break; sleep 0.5; done
[ -s "$work/display" ] || { echo "Xvfb did not start" >&2; exit 2; }
display=":$(cat "$work/display")"

# Reuse the local theme so the images look like the real bar.
cp "${XDG_CONFIG_HOME:-$HOME/.config}/dms/settings.json" "$work/config/dms/" 2>/dev/null || true
cp "${XDG_CACHE_HOME:-$HOME/.cache}/dms/dms-colors.json" "$work/cache/" 2>/dev/null || true
printf '%s\n' '{"duxSkoda":{"enabled":true}}' > "$work/config/dms/plugin_settings.json"

env -u WAYLAND_DISPLAY -u NIRI_SOCKET -u DMS_SOCKET -u QT_QPA_PLATFORMTHEME \
    QT_QPA_PLATFORM=xcb DISPLAY="$display" \
    XDG_RUNTIME_DIR="$work/runtime" XDG_CONFIG_HOME="$work/config" XDG_CACHE_HOME="$work/cache" \
    XDG_STATE_HOME="$work/state" XDG_DATA_HOME="$work/data" \
    DUXSKODA_DIR="$repo" DUXSKODA_SHOTS="$out" DUXSKODA_TOKENS="$work/tokens" DUXSKODA_API="http://127.0.0.1:$port/" \
    timeout --kill-after=5 240 dbus-run-session -- qs --log-rules 'scene.warning=true;qml.warning=true;js.warning=true' -p "$work/harness" \
    > "$out/quickshell.log" 2>&1 &
qs_pid=$!

# Never silent: print each scene as it finishes and a heartbeat every 10 s.
start=$(date +%s)
if [ -n "${DUXSKODA_ONLY:-}" ]; then
    total=$(printf '%s\n' $DUXSKODA_ONLY | wc -l)
else
    total=$(grep -c '^        { name: "' "$repo/tests/render/shell.qml")
fi
seen=0
beat=0
while kill -0 "$qs_pid" 2>/dev/null; do
    done_now=$(grep -c 'SKODA [A-Za-z0-9]* pill=' "$out/quickshell.log" 2>/dev/null || true)
    while [ "$seen" -lt "${done_now:-0}" ]; do
        seen=$((seen + 1))
        name=$(grep 'SKODA [A-Za-z0-9]* pill=' "$out/quickshell.log" | sed -n "${seen}p" | sed 's/.*SKODA \([A-Za-z0-9]*\) pill=.*/\1/')
        printf '[%3ds] %d/%d %s\n' "$(($(date +%s) - start))" "$seen" "$total" "$name"
    done
    beat=$((beat + 1))
    [ $((beat % 10)) -eq 0 ] && printf '[%3ds] still running, %d/%d scenes done\n' "$(($(date +%s) - start))" "$seen" "$total"
    sleep 1
done
wait "$qs_pid" || true
printf 'Render finished in %ds\n' "$(($(date +%s) - start))"
cp "$work/requests.log" "$out/requests.log" 2>/dev/null || true

fail() {
    printf '%s\n' "$1" >&2
    grep -E "SKODA|$repo" "$out/quickshell.log" >&2 || tail -n 20 "$out/quickshell.log" >&2
    exit 1
}

grep -q 'SKODA done' "$out/quickshell.log" || fail 'The render did not finish.'
if grep -E "SKODA ERROR|$repo/[^ ]*: .*(Error|is not defined|Cannot read|Unable to assign|ReferenceError|TypeError)" "$out/quickshell.log" >&2; then
    fail 'QML errors in plugin files.'
fi

# A filtered run only has some scenes, so the full set of assertions does not apply.
if [ -n "${DUXSKODA_ONLY:-}" ]; then
    grep -E 'SKODA [A-Za-z0-9]+ pill=' "$out/quickshell.log" | sed 's/.*SKODA //'
    printf '%s\n' "Filtered run: assertions skipped. Images are in $out."
    exit 0
fi

scene() { sed -n "s/.*SKODA $1 //p" "$out/quickshell.log"; }
check() { scene "$1" | grep -Eq "$2" || fail "$1 scene: expected /$2/ in: $(scene "$1")"; }
posted() { grep -Fxq "$1" "$out/requests.log" || fail "Expected request: $1"; }
# nextIn is seconds until the next fetch, a little below the interval because the scene took a moment.
check heating '^pill=76 % soc=76 status=unplugged error="" ac=HEATING pending=- acfail=- nextIn=(8[89][0-9]|900) keyDays=1[12][0-9] '
check idle '^pill=76 % soc=76 status=unplugged error="" ac=OFF pending=- '
check charging '^pill=61 % soc=61 status=charging error="" ac=OFF '
check plugged '^pill=100 % soc=100 status=plugged error="" '
check lowbat '^pill=12 % soc=12 status=unplugged '
check open '^pill=76 % .* error="" ac=OFF '
check partial '^pill=76 % soc=76 status=plugged error="" ac= pending=- '
check noac '^pill=76 % .* error="" ac=OFF '
check expiring 'error="" ac=OFF .* keyDays=5 '
check lowquota 'error="" .* nextIn=1(7[89][0-9]|80[01]) '
check acstart 'ac=OFF pending=start acfail=- nextIn=(2[0-9]|30) '
check acstop 'ac=HEATING pending=stop acfail=- nextIn=(2[0-9]|30) '
check acdisabled 'pending=- acfail=disabled '
check acdeclined 'pending=- acfail=declined '
check expired '^pill=! soc=none status=none error="expired" ac=none .* nextIn=(29[0-9]|300) '
check stale '^pill=76 % soc=76 .* error="expired" '
check forbidden '^pill=! soc=none status=none error="forbidden" '
check ratelimit '^pill=! soc=none status=none error="ratelimit" .* nextIn=1(19[0-9]|20[01]) '
check server '^pill=! soc=none status=none error="server" .* nextIn=(11[0-9]|12[01]) '
check invalid '^pill=! soc=none status=none error="invalid" '
check nokey '^pill=! soc=none status=none error="nokey" .* nextIn=(5[0-9]|60) '
check novin '^pill=! soc=none status=none error="novin" '
check badvin '^pill=! soc=none status=none error="novin" '
check offline '^pill=! soc=none status=none error="offline" .* nextIn=(5[0-9]|60) '
check twoscreens 'twinSame=true'
check declared 'nextIn=(17[89][0-9]|1800) .* refresh=30 '
posted 'POST start idle {"targetTemperature":{"value":21,"unit":"CELSIUS"},"airConditioningWithoutExternalPower":true}'
posted 'POST stop heating -'
posted 'POST start acdisabled {"targetTemperature":{"value":21,"unit":"CELSIUS"},"airConditioningWithoutExternalPower":true}'

# One GET per scene that reaches the server (stale has two), plus the four A/C commands; scenes with
# a missing key or VIN, and the offline one, send nothing; two screens must share one fetch.
[ "$(wc -l < "$out/requests.log")" = 27 ] || fail "Expected 27 requests, got $(wc -l < "$out/requests.log")"
for n in $(grep -o '^        { name: "[A-Za-z0-9]*"' "$repo/tests/render/shell.qml" | sed 's/.*"\(.*\)"/\1/'); do
    [ -s "$out/$n.png" ] || fail "Missing $n.png"
done
printf '%s\n' "Render checks passed. Images are in $out."
