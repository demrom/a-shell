#!/bin/bash
# Enroll only a disposable CA and run the existing relay consumer over loopback.
set -euo pipefail
umask 077
sim=${1:?Pass a Simulator UDID}
bundle=${2:?Pass an app bundle ID}
mode=${3:?Pass true for client certificates or false for tokens only}
case $mode in true|false) ;; *) exit 2 ;; esac
root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
container=$(xcrun simctl get_app_container "$sim" "$bundle" data)
documents="$container/Documents"
account=$(mktemp -d)
trap 'rm -r "$account"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$account/ca.key" -out "$account/ca.pem" \
    -days 1 -subj '/CN=Simulator relay CA' -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' > "$account/certs.log" 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "$account/client.key" -out "$account/client.csr" \
    -subj '/CN=Simulator relay client' >> "$account/certs.log" 2>&1
printf 'basicConstraints=critical,CA:FALSE\nextendedKeyUsage=clientAuth\nkeyUsage=critical,digitalSignature\n' > "$account/client.ext"
openssl x509 -req -in "$account/client.csr" -CA "$account/ca.pem" -CAkey "$account/ca.key" -CAcreateserial \
    -out "$account/client.pem" -days 1 -extfile "$account/client.ext" >> "$account/certs.log" 2>&1
openssl x509 -in "$account/ca.pem" -outform DER -out "$documents/.relay-client-ca.der"
export RELAY_TOKEN
RELAY_TOKEN=$(openssl rand -hex 32)
export RELAY_CA="$documents/.relay-cert.pem"
export RELAY_CLIENT_CERT="$account/client.pem"
export RELAY_CLIENT_KEY="$account/client.key"

bash "$root/url-logging/check.sh" "$sim" "$bundle" --confirm-open
url() {
    local encoded
    encoded=$(jq -nr --arg command "$1" '$command | @uri')
    xcrun simctl openurl "$sim" "ashellmini:$encoded"
}
relay_command() {
    local action=$1 file="$documents/relay-$1.txt" outfile attempt
    printf -v outfile '%q' "$file"
    url "relay $action > $outfile"
    for ((attempt=0; attempt<150; attempt++)); do
        if [[ -s $file ]]; then return 0; fi
        sleep 0.2
    done
    printf 'No relay %s receipt\n' "$action" >&2
    return 1
}
# Supply a generated token without logging it in the URL or the receipt.
jq -n --argjson tls "$mode" '{enabled:false,bind:"127.0.0.1",port:0,mutualTLS:$tls,token:env.RELAY_TOKEN}' \
    > "$documents/.relay.json"
relay_command on
grep -Fq 'listening on 127.0.0.1:' "$documents/relay-on.txt"
relay_command status
port=$(awk '/^port: [1-9][0-9]*$/ {print $2}' "$documents/relay-status.txt")
test -n "$port"
printf 'Checking loopback relay, mutualTLS=%s\n' "$mode"
RELAY_URL="https://localhost:$port" RELAY_MUTUAL_TLS="$mode" sh "$root/relay.sh"
printf 'APP_RELAY_PASS mutualTLS=%s\n' "$mode"
