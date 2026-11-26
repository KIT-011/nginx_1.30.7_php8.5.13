#!/bin/sh
set -eu
export APACHE_CONFDIR=/etc/apache2
# Debian and host-provided envvars may refer to optional unset variables.
set +u
. "$APACHE_CONFDIR/envvars"
set -u
mkdir -p "$APACHE_RUN_DIR" "$APACHE_LOCK_DIR"
if [ -n "${PHPRC:-}" ] && [ ! -r "$PHPRC" ]; then
    printf 'Cannot read PHP configuration: %s\n' "$PHPRC" >&2
    exit 1
fi
modules=$(/usr/sbin/apache2 -M)
if ! printf '%s\n' "$modules" | grep -q ' php_module '; then
    printf 'Enable mod_php in the mounted Apache configuration\n' >&2
    exit 1
fi
rm -f "$APACHE_PID_FILE"
exec /usr/sbin/apache2 -D FOREGROUND
