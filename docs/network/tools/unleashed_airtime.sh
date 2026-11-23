#!/usr/bin/env bash
# Read-only: 2.4 GHz (wifi0) channel and airtime from every Unleashed AP at once.
# usage: UL_USER=... UL_PASS=... unleashed_airtime.sh [radio]   (radio: wifi0 2.4 GHz, wifi1 5 GHz, wifi2 6 GHz)
# Credentials: 1Password item "Ruckus Unleashed" (Infrastructure vault). Needs expect.
# The current master answers SSH with the controller CLI, so it is read through ap-mode.
set -euo pipefail
radio="${1:-wifi0}"
: "${UL_USER:?set UL_USER}" "${UL_PASS:?set UL_PASS}"
declare -A AP=(
  [10.1.99.13]=office [10.1.99.14]=upstairs-hallway [10.1.99.23]=game-room [10.1.99.33]=garage
  [10.1.99.34]=kitchen [10.1.99.35]=rear-driveway [10.1.99.36]=side-yard [10.1.99.37]=side-driveway
)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/read.exp" <<'EXP'
set timeout 15
log_user 1
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 [lindex $argv 0]
expect {
  -re {Please login:} { send "$env(UL_USER)\r"; exp_continue }
  -re {assword ?:}    { send "$env(UL_PASS)\r"; exp_continue }
  -re {rkscli:}       { set mode ap }
  -re {ruckus>}       { send "enable\r"; expect -re {ruckus#}; send "ap-mode\r"; expect -re {ap-mode\)#}; set mode master }
  timeout             { puts "<<no prompt>>"; exit 1 }
}
if {$mode eq "ap"} { set prompt {rkscli:} } else { set prompt {ap-mode\)#} }
foreach c [list "get channel $env(RADIO)" "get airtime $env(RADIO)"] {
  send "$c\r"; expect -re $prompt
}
if {$mode eq "master"} { send "quit\r"; expect -re {ruckus#} }
send "exit\r"; expect eof
EXP

read_ap() {  # $1 ip
  RADIO="$radio" timeout 60 expect "$tmp/read.exp" "$1" 2>&1 | tr -d '\r' > "$tmp/$1" || true
}

for ip in "${!AP[@]}"; do read_ap "$ip" & done; wait

printf '%-17s %-4s %6s %5s %4s %4s\n' AP chan total busy tx rx
for ip in "${!AP[@]}"; do
  f="$tmp/$ip"
  ch=$(grep -o "$radio Channel: [0-9]*" "$f" | awk '{print $3}' || true)
  get() { grep "Chanutil $1%" "$f" | grep -o '[0-9]\+' | tail -1 || true; }
  printf '%-17s %-4s %6s %5s %4s %4s\n' "${AP[$ip]}" "${ch:-?}" "$(get Total)" "$(get Busy)" "$(get Tx)" "$(get Rx)"
done | sort
