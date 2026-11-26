#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
jobs=${JOBS:-4}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { printf 'JOBS must be a positive integer\n' >&2; exit 1; }
docker build --platform linux/amd64 --load --build-arg "JOBS=$jobs" \
    -f Dockerfile.nginx -t offline-nginx:1.30.8 .
docker build --platform linux/amd64 --load --build-arg "JOBS=$jobs" \
    -f Dockerfile.php -t offline-php-apache:8.5.13 .
mkdir -p ../work
cd ../work
archive=docker-nginx1.30.8-php8.5.13-amd64.tar.gz
temporary=$(mktemp "./.$archive.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT
docker save offline-nginx:1.30.8 offline-php-apache:8.5.13 | gzip -n > "$temporary"
mv -f -- "$temporary" "$archive"
sha256sum "$archive" > "$archive.sha256"
printf 'Created work/%s and its SHA-256 file\n' "$archive"
