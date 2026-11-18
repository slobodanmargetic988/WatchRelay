#!/bin/bash
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
switch="$root/Watch Internet.command"
smoke="$root/scripts/test-wide-smoke"
wifi_power() { /usr/sbin/networksetup -getairportpower en0; }
ipv4_interface() { /sbin/route -n get -inet 1.1.1.1 2>/dev/null | /usr/bin/awk '/interface:/{print $2}'; }
wifi_connected() {
    [[ $(wifi_power) == *": On" ]] &&
        /usr/sbin/scutil --nwi | /usr/bin/awk '
            $1 == "en0" && /[(,]IPv4[,)]/ && /[(,]DNS[,)]/ { ready = 1 }
            END { exit !ready }
        '
}
umask 077
/bin/mkdir -p "$root/evidence/wide"
report=$(/usr/bin/mktemp "$root/evidence/wide/offline-trial.XXXXXXXX")
exec > >(/usr/bin/tee "$report") 2>&1
trap 'result=$?; if ((result)); then printf "\nThe offline test stopped. Turn Mac Wi-Fi back on.\n"; fi' EXIT

printf 'Enter your Mac password here and press Return. Terminal hides what you type.\n'
/usr/bin/sudo -v
if [[ $(wifi_power) == *": On" ]]; then
    baseline=$("$smoke" baseline --wifi on --timeout 8 | /usr/bin/tail -1)
fi
printf 'When you are ready, turn off Mac Wi-Fi and leave Bluetooth on.\n'
printf 'The test waits here until Wi-Fi is off. Press Control-C to cancel.\n'
while [[ $(wifi_power) != *": Off" ]]; do
    sleep 1
done

printf '\nMac Wi-Fi is off. Checking the watch connection.\n'
"$smoke" offline --wifi off --timeout 8
"$switch" trial --seconds 210
interface=$(ipv4_interface)
printf 'The watch route is up. Checking DNS and HTTPS while apps reconnect.\n'
if ! "$smoke" active --interface "$interface" --wifi off --ipv6 blocked \
    --require-system-path --retry-refusals --timeout 60; then
    "$switch" off
    exit 1
fi
printf '\nOffline Watch Internet passed. Try normal Chrome, Codex or Claude now.\n'
printf 'Turn Wi-Fi back on when finished. The trial also ends automatically.\n'
for ((attempt=0; attempt<230; attempt++)); do
    if wifi_connected; then
        "$switch" off
        for ((settle=0; settle<20; settle++)); do
            [[ $(ipv4_interface) == en0 ]] && break
            sleep 1
        done
        if [[ -n ${baseline:-} ]]; then
            "$smoke" restored --interface "$interface" --wifi on --against "$baseline"
        else
            "$smoke" restored --interface "$interface" --wifi on
        fi
        exit
    fi
    sleep 1
done
printf 'The restoration test needs the Mac connected to its normal Wi-Fi network.\n' >&2
exit 2
