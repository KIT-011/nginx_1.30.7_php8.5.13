#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
[[ $# == 0 ]] || { echo 'Usage: [NGINX_VERSION=...] [PHP_VERSION=...] [RELEASE=...] bash build.sh' >&2; exit 1; }

nginx_version=${NGINX_VERSION:-1.30.8}
php_version=${PHP_VERSION:-8.5.13}
revision=${RELEASE:-$(date -u +%Y%m%dT%H%M%SZ)}
for version in "$nginx_version" "$php_version"; do
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid version: $version" >&2; exit 1; }
done
[[ $revision =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,39}$ ]] || { echo "Invalid RELEASE" >&2; exit 1; }

release="nginx$nginx_version-php$php_version-amd64-$revision"
nginx_image="offline-nginx:$release"
php_image="offline-php-apache:$release"
archive="$release.tar.gz"
output=../work
mkdir -p "$output"
exec 9>"$output/.container-build.lock"
flock 9
[[ ! -e $output/$archive && ! -e $output/$archive.sha256 ]] ||
    { echo "Release already exists. Choose a different RELEASE." >&2; exit 1; }

docker build --platform linux/amd64 --pull --no-cache --load \
    --build-arg "NGINX_VERSION=$nginx_version" -f Dockerfile.nginx -t "$nginx_image" .
docker build --platform linux/amd64 --pull --no-cache --load \
    --build-arg "PHP_VERSION=$php_version" -f Dockerfile.php -t "$php_image" .

staging=$(mktemp -d "$output/.container-release.XXXXXX")
trap 'rm -rf -- "$staging"' EXIT
bundle="$staging/$release"
mkdir "$bundle"
cp compose.yaml nginx.conf "$bundle/"
printf 'NGINX_IMAGE=%s\nPHP_IMAGE=%s\n' "$nginx_image" "$php_image" > "$bundle/images.env"
docker image save -o "$bundle/images.tar" "$nginx_image" "$php_image"
tar -C "$staging" -czf "$staging/$archive" "$release"
(cd "$staging" && sha256sum "$archive" > "$archive.sha256")
mv -- "$staging/$archive" "$staging/$archive.sha256" "$output/"
printf 'Created work/%s and its SHA-256 file\n' "$archive"
