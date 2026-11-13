#!/bin/sh
set -eu

ca=/home/emulator/.aws/emulator/9297/ca.pem
cert=/etc/aws-emulator/tls/tls.crt
key=/etc/aws-emulator/tls/tls.key
config=/etc/aws-emulator/config/nginx.conf

while [ ! -r "$ca" ] || [ ! -r "$cert" ] || [ ! -r "$key" ]; do
    sleep 1
done

fingerprint() {
    sha256sum "$ca" "$cert" "$key"
}

current=$(fingerprint)
(
    while sleep 5; do
        if next=$(fingerprint 2>/dev/null) && [ "$current" != "$next" ]; then
            if nginx -t -c "$config" && nginx -s reload -c "$config"; then
                current=$next
            fi
        fi
    done
) &

exec nginx -c "$config" -g 'daemon off;'
