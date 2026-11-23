#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
readonly PHP_ROOT=/opt/php-8.5.13 NGINX_ROOT=/opt/nginx-1.30.7
readonly PHP_CONF=/etc/opt/apache-php85 NGINX_CONF=/etc/opt/nginx-1.30.7
readonly NEW_APACHE=apache-php85.service NEW_NGINX=nginx-1.30.7.service
readonly OLD_NGINX=nginx.service STATE_DIR=/var/lib/offline-web-stack
readonly STATE_FILE="$STATE_DIR/previous-services"
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

check_target() {
    local ID= VERSION_ID=
    . /etc/os-release
    mapfile -t target < "$here/target"
    (("${#target[@]}" == 4)) || die "Invalid bundle target metadata"
    [[ $(uname -m) == x86_64 && $ID == "${target[1]}" ]] ||
        die "This archive targets ${target[1]} ${target[2]} x86_64"
    case "${target[0]}:$VERSION_ID" in
        redos73:7.3|redos73:7.3.*|redos8:8|redos8:8.*) ;;
        almalinux9:9|almalinux9:9.*) ;;
        *) [[ $VERSION_ID == "${target[2]}" ]] || die "Unexpected release $VERSION_ID" ;;
    esac
    family=${target[3]}
    case "$family" in
        deb) old_apache=apache2.service; apache_binary=/usr/sbin/apache2 ;;
        rpm) old_apache=httpd.service; apache_binary=/usr/sbin/httpd ;;
        *) die "Invalid package family $family" ;;
    esac
}

verify_bundle() {
    (cd "$here" && sha256sum --quiet -c MANIFEST.sha256)
}

stage_prefix() (
    local path=$1 marker=$2 staging
    if [[ -e $path || -L $path ]]; then
        [[ -f $path/.offline-build-id && $(< "$path/.offline-build-id") == "$marker" ]] ||
            die "$path already exists and belongs to another installation"
        return
    fi
    staging=$(mktemp -d /opt/.offline-stack.XXXXXX)
    trap 'rm -rf -- "$staging"' EXIT
    cp -a "$here/payload$path/." "$staging/"
    printf '%s\n' "$marker" > "$staging/.offline-build-id"
    chown -hR 0:0 "$staging"
    chmod -R go-w "$staging"
    chmod 0755 "$staging"
    mv -T -- "$staging" "$path"
)

stage() {
    local marker
    marker=$(sha256sum "$here/MANIFEST.sha256" | cut -d ' ' -f1)
    stage_prefix "$PHP_ROOT" "$marker"
    stage_prefix "$NGINX_ROOT" "$marker"
    install -d -m 0750 "$PHP_CONF" "$NGINX_CONF"
    printf 'Staged %s and %s\n' "$PHP_ROOT" "$NGINX_ROOT"
}

deps() (
    local packages=()
    mapfile -t packages < "$here/runtime-packages.txt"
    (("${#packages[@]}")) || die "Empty runtime package list"
    case "${1:-}" in --plan|--install) ;; *) die 'Specify --plan or --install' ;; esac

    if [[ $family == deb ]]; then
        local tmp args=()
        tmp=$(mktemp -d)
        trap 'rm -rf -- "$tmp"' EXIT
        chmod 0755 "$tmp"
        install -d -m 0700 "$tmp/lists/partial"
        printf 'deb [trusted=yes] file:%s/packages ./\n' "$here" > "$tmp/sources.list"
        args=(-o "Dir::Etc::sourcelist=$tmp/sources.list" -o 'Dir::Etc::sourceparts=-'
            -o "Dir::State::lists=$tmp/lists" -o 'Acquire::Languages=none')
        apt-get "${args[@]}" update
        if [[ $1 == --plan ]]; then args+=(-s); fi
        apt-get "${args[@]}" install --no-install-recommends --no-remove "${packages[@]}"
    else
        local args=(
            '--disablerepo=*' '--disableplugin=*'
            "--repofrompath=offline-web-stack,file://$here/packages"
            --enablerepo=offline-web-stack --setopt=offline-web-stack.gpgcheck=0
            --setopt=install_weak_deps=0
        )
        if [[ $1 == --plan ]]; then args+=(--assumeno); fi
        dnf "${args[@]}" install "${packages[@]}"
    fi
)

install_new_file() {
    local mode=$1 path=$2 tmp
    tmp=$(mktemp)
    cat > "$tmp"
    if [[ -e $path || -L $path ]]; then
        if ! cmp -s "$tmp" "$path"; then
            rm -f -- "$tmp"
            die "Existing file $path differs from the generated file"
        fi
    else
        install -m "$mode" "$tmp" "$path"
    fi
    rm -f -- "$tmp"
}

register_units() {
    [[ -x $PHP_ROOT/bin/php && -x $NGINX_ROOT/sbin/nginx ]] || die 'Run stage first'
    [[ -x $apache_binary ]] || die "Apache is required at $apache_binary"
    install_new_file 0755 "$PHP_ROOT/sbin/apache-php85" <<WRAPPER
#!/usr/bin/env bash
set -e
if [[ '$family' == deb ]]; then
    . /etc/apache2/envvars
    export APACHE_RUN_DIR=/run/apache-php85
    export APACHE_LOCK_DIR=/run/apache-php85
    export APACHE_PID_FILE=/run/apache-php85/apache.pid
fi
export PHPRC='$PHP_ROOT/etc'
export PHP_INI_SCAN_DIR='$PHP_ROOT/etc/conf.d'
exec '$apache_binary' -d '$PHP_CONF' -f '$PHP_CONF/httpd.conf' "\$@"
WRAPPER

    install_new_file 0644 "/etc/systemd/system/$NEW_APACHE" <<UNIT
[Unit]
Description=Apache with PHP 8.5.13
After=network.target

[Service]
Type=simple
RuntimeDirectory=apache-php85
ExecStartPre=$PHP_ROOT/sbin/apache-php85 -t
ExecStart=$PHP_ROOT/sbin/apache-php85 -D FOREGROUND
ExecReload=$PHP_ROOT/sbin/apache-php85 -t
ExecReload=/bin/kill -USR1 \$MAINPID
KillSignal=SIGWINCH
KillMode=mixed
TimeoutStopSec=90s

[Install]
WantedBy=multi-user.target
UNIT

    install_new_file 0644 "/etc/systemd/system/$NEW_NGINX" <<UNIT
[Unit]
Description=nginx 1.30.7
After=network.target $NEW_APACHE

[Service]
Type=simple
RuntimeDirectory=nginx-1.30.7
ExecStartPre=$NGINX_ROOT/sbin/nginx -t -p $NGINX_CONF/ -c $NGINX_CONF/nginx.conf -g "daemon off;"
ExecStart=$NGINX_ROOT/sbin/nginx -p $NGINX_CONF/ -c $NGINX_CONF/nginx.conf -g "daemon off;"
ExecReload=$NGINX_ROOT/sbin/nginx -t -p $NGINX_CONF/ -c $NGINX_CONF/nginx.conf -g "daemon off;"
ExecReload=/bin/kill -HUP \$MAINPID
KillSignal=SIGQUIT
KillMode=mixed
TimeoutStopSec=90s

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
}

check_stack() {
    [[ -f $PHP_CONF/httpd.conf && -f $NGINX_CONF/nginx.conf ]] ||
        die "Prepare $PHP_CONF/httpd.conf and $NGINX_CONF/nginx.conf"
    [[ -x $PHP_ROOT/sbin/apache-php85 ]] || die 'Run units first'
    install -d -m 0755 /run/apache-php85 /run/nginx-1.30.7
    local modules
    "$PHP_ROOT/bin/php" -r 'if (PHP_VERSION !== "8.5.13" || !extension_loaded("mysqli") || !extension_loaded("pspell")) exit(1);'
    modules=$("$PHP_ROOT/sbin/apache-php85" -M)
    printf '%s\n' "$modules"
    grep -Fq 'mpm_prefork_module ' <<< "$modules" || die 'Apache prefork is required'
    grep -Fq 'php_module ' <<< "$modules" || die 'Apache mod_php is required'
    "$PHP_ROOT/sbin/apache-php85" -t
    "$NGINX_ROOT/sbin/nginx" -t -p "$NGINX_CONF/" -c "$NGINX_CONF/nginx.conf" -g 'daemon off;'
}

restore_services() {
    [[ -f $STATE_FILE ]] || die "No saved service state"
    local s seen=0 status=0 unit previous_enabled previous_active
    for s in "$NEW_NGINX" "$NEW_APACHE"; do
        systemctl disable --now "$s" || status=1
    done
    if ((status != 0)); then
        printf 'Stop the new services before restoring the old ones.\n' >&2
        return 1
    fi
    while read -r unit previous_enabled previous_active; do
        [[ $unit == "$old_apache" || $unit == "$OLD_NGINX" ]] || return 1
        case "$previous_enabled" in
            enabled) systemctl enable "$unit" || status=1 ;;
            enabled-runtime) systemctl enable --runtime "$unit" || status=1 ;;
        esac
        if [[ $previous_active == active ]]; then systemctl start "$unit" || status=1; fi
        seen=$((seen + 1))
    done < "$STATE_FILE"
    if ((status != 0 || seen != 2)); then
        printf 'Rollback incomplete. Saved state: %s\n' "$STATE_FILE" >&2
        return 1
    fi
    mv -fT -- "$STATE_FILE" "$STATE_DIR/last-rollback"
}

activate() {
    local url=${1:-} vhost=${2:-} unit previous_enabled previous_active body attempt
    [[ $url =~ ^http://127\.0\.0\.1(:[0-9]{1,5})?/[^[:space:]]*$ ]] ||
        die 'Specify the HTTP canary URL on 127.0.0.1'
    command -v curl >/dev/null || die 'curl is required for the HTTP check'
    [[ ! -e $STATE_FILE ]] || die 'A switch has already been recorded'
    check_stack
    install -d -m 0700 "$STATE_DIR"
    for unit in "$old_apache" "$OLD_NGINX"; do
        [[ $(systemctl show -p LoadState --value "$unit") == loaded ]] ||
            die "Existing service $unit could not be identified"
    done
    for unit in "$NEW_APACHE" "$NEW_NGINX"; do
        [[ $(systemctl show -p LoadState --value "$unit") == loaded ]] ||
            die "Run units to register $unit"
        if systemctl is-active --quiet "$unit" || systemctl is-enabled --quiet "$unit"; then
            die "Stop and disable $unit before using the managed switch"
        fi
    done

    {
        for unit in "$old_apache" "$OLD_NGINX"; do
            previous_enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)
            previous_active=$(systemctl is-active "$unit" 2>/dev/null || true)
            printf '%s %s %s\n' "$unit" "${previous_enabled:-unknown}" "${previous_active:-unknown}"
        done
    } > "$STATE_FILE.tmp"
    mv -T -- "$STATE_FILE.tmp" "$STATE_FILE"
    trap 'status=$?; trap - EXIT; if ((status)); then restore_services || printf "Manual rollback required.\n" >&2; fi; exit "$status"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    systemctl stop "$OLD_NGINX"
    systemctl stop "$old_apache"
    while read -r unit previous_enabled previous_active; do
        case "$previous_enabled" in
            enabled) systemctl disable "$unit" ;;
            enabled-runtime) systemctl disable --runtime "$unit" ;;
        esac
    done < "$STATE_FILE"
    systemctl start "$NEW_APACHE"
    systemctl start "$NEW_NGINX"

    local curl_args=(--noproxy '*' --silent --show-error --fail --max-time 5)
    if [[ -n $vhost ]]; then curl_args+=(-H "Host: $vhost"); fi
    body=
    for attempt in 1 2 3 4 5; do
        body=$(curl "${curl_args[@]}" -- "$url" || true)
        if [[ $body == 'apache2handler 8.5.13' ]]; then break; fi
        sleep 1
    done
    [[ $body == 'apache2handler 8.5.13' ]] || die 'HTTP canary failed to confirm Apache PHP 8.5.13'
    systemctl is-active --quiet "$NEW_APACHE"
    systemctl is-active --quiet "$NEW_NGINX"
    systemctl enable "$NEW_APACHE" "$NEW_NGINX"
    trap - EXIT INT TERM
    printf 'Activated %s and %s\n' "$NEW_APACHE" "$NEW_NGINX"
}

if [[ ${1:-} == verify ]]; then verify_bundle; exit; fi
case "${1:-}" in
    deps|stage|units|check|switch|rollback) ;;
    *) die 'Usage: bash deploy.sh {verify|deps --plan|deps --install|stage|units|check|switch URL [HOST]|rollback}' ;;
esac
((EUID == 0)) || die 'Run this operation with sudo'
check_target
exec 9>/run/lock/offline-web-stack.lock
flock 9
case "$1" in
    deps) verify_bundle; deps "${2:-}" ;;
    stage) verify_bundle; stage ;;
    units) register_units ;;
    check) check_stack ;;
    switch) activate "${2:-}" "${3:-}" ;;
    rollback) restore_services ;;
esac

