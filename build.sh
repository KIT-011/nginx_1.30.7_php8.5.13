#!/usr/bin/env bash
set -Eeuo pipefail
readonly PHP=8.5.13 NGINX=1.30.7 PSPELL=1.0.1
readonly PHP_PREFIX=/opt/php-8.5.13 NGINX_PREFIX=/opt/nginx-1.30.7
readonly GEOIP_VERSION=1.6.12 GEOIP_SHA=1dfb748003c5e4b7fd56ba8c4cd786633d5d6f409547584f6910398389636f80
readonly GEOIP_LIBDIR="$NGINX_PREFIX/lib/geoip"
readonly PHP_SHA=607602acaf0c3061818e9916ec44a058e8b3d43959a83862b9cd3ec7bf5b785f
export LC_ALL=C

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
fetch() { curl --fail --location --retry 3 --silent --show-error --output "$2" "$1"; }

profile_info() {
    family=deb
    case "$1" in
        ubuntu22) base=ubuntu:22.04; os_id=ubuntu; os_version=22.04; pagespeed=jammy ;;
        ubuntu24) base=ubuntu:24.04; os_id=ubuntu; os_version=24.04; pagespeed=noble ;;
        debian12) base=debian:12; os_id=debian; os_version=12; pagespeed=bookworm ;;
        debian13) base=debian:13; os_id=debian; os_version=13; pagespeed=trixie ;;
        astra17|astra18)
            os_id=astra
            astra_apt_list="/etc/apt/offline-stack-$1.list"
            pagespeed=none
            if [[ $1 == astra17 ]]; then
                base=${ASTRA_IMAGE:-registry.astralinux.ru/library/alse:1.7.4}
                os_version=1.7_x86-64
            else
                base=${ASTRA_IMAGE:-registry.astralinux.ru/library/astra/ubi18:latest}
                os_version=1.8_x86-64
            fi
            ;;
        redos73|redos8)
            family=rpm
            os_id=redos
            os_version=${1#redos}
            if [[ $1 == redos73 ]]; then os_version=7.3; fi
            base=${REDOS_IMAGE:-}
            pagespeed=none
            ;;
        almalinux9)
            family=rpm
            os_id=almalinux
            os_version=9
            base=almalinux:9
            pagespeed=el9
            ;;
        *) die "Unknown profile '$1'. Use ubuntu22, ubuntu24, debian12, debian13, astra17, astra18, redos73, redos8 or almalinux9." ;;
    esac
}

check_os() {
    local ID= VERSION_ID= ID_LIKE=
    . /etc/os-release
    [[ $(uname -m) == x86_64 ]] || die "Expected x86_64"
    [[ $ID == "$os_id" ]] || die "Expected $os_id, found $ID"
    case "$VERSION_ID" in
        "$os_version"|"$os_version".*) ;;
        8.*) [[ $os_version == 8 ]] || die "Unexpected VERSION_ID=$VERSION_ID" ;;
        *) die "Expected $os_version, found $VERSION_ID" ;;
    esac
}

prepare_sources() (
    local dest=$1 tmp key module staging
    if [[ -d $dest ]]; then
        (cd "$dest" && sha256sum --quiet -c SHA256SUMS)
        return
    fi
    tmp=$(mktemp -d "$work/sources.XXXXXX")
    trap 'rm -rf -- "$tmp"' EXIT
    cd "$tmp"
    fetch "https://www.php.net/distributions/php-$PHP.tar.xz" "php-$PHP.tar.xz"
    printf '%s  %s\n' "$PHP_SHA" "php-$PHP.tar.xz" | sha256sum --check
    fetch "https://nginx.org/download/nginx-$NGINX.tar.gz" "nginx-$NGINX.tar.gz"
    fetch "https://nginx.org/download/nginx-$NGINX.tar.gz.asc" "nginx-$NGINX.tar.gz.asc"
    mkdir -m 700 gnupg
    for key in arut pluknet sb thresh nginx_signing; do
        fetch "https://nginx.org/keys/$key.key" "$key.key"
        gpg --batch --homedir "$tmp/gnupg" --import "$key.key"
    done
    gpg --batch --homedir "$tmp/gnupg" --verify "nginx-$NGINX.tar.gz.asc" "nginx-$NGINX.tar.gz"
    fetch "https://pecl.php.net/get/pspell-$PSPELL.tgz" "pspell-$PSPELL.tgz"

    git clone --recurse-submodules https://github.com/google/ngx_brotli.git brotli
    git clone https://github.com/openresty/headers-more-nginx-module.git headers-more
    git clone https://github.com/evanmiller/mod_zip.git mod_zip
    for module in brotli headers-more mod_zip; do
        printf '%s %s\n' "$module" "$(git -C "$module" rev-parse HEAD)"
        git -C "$module" submodule status --recursive
    done > MODULES.txt
    tar --exclude=.git -czf nginx-modules.tar.gz brotli headers-more mod_zip

    staging=$(mktemp -d "$work/verified-sources.XXXXXX")
    cp ./*.tar.* ./*.tgz MODULES.txt "$staging/"
    (cd "$staging" && sha256sum -- * > SHA256SUMS)
    mv -T -- "$staging" "$dest"
)

prepare_image() {
    local tag=$1 apt_setup= apt_options= install_command geoip_setup=
    local ldap_dev=libldap-dev freetype_dev=libfreetype-dev
    local -a pull_options=(--pull)
    if [[ $os_id == astra ]]; then
        local repo_root=${ASTRA_REPO_ROOT:-https://dl.astralinux.ru/astra/stable/$os_version}
        local components='main contrib non-free' repos='repository-main repository-update repository-base repository-extended'
        [[ $repo_root =~ ^https://[a-zA-Z0-9._:/-]+$ ]] ||
            die "ASTRA_REPO_ROOT must be an HTTPS URL without credentials"
        if [[ $profile == astra17 ]]; then
            ldap_dev=libldap2-dev
            freetype_dev=libfreetype6-dev
        else
            repos='main-repository extended-repository'
            components+=' non-free-firmware'
        fi
        apt_setup="RUN for repo in $repos; do printf 'deb %s/%s %s %s\n' '${repo_root%/}' \"\$repo\" '$os_version' '$components'; done > '$astra_apt_list'"
        apt_options="-o Dir::Etc::sourcelist=$astra_apt_list -o Dir::Etc::sourceparts=-"
    fi
    if [[ $os_id == redos || ( $os_id == astra && -n ${ASTRA_IMAGE:-} ) ]] &&
        docker image inspect "$base" >/dev/null 2>&1; then
        pull_options=()
    fi

    if [[ $family == deb ]]; then
        local -a packages=(
            build-essential pkg-config autoconf libtool bison re2c cmake ca-certificates curl
            apache2-dev apache2 file binutils dpkg-dev xz-utils util-linux libgeoip-dev
            libbz2-dev libcurl4-openssl-dev "$freetype_dev" libgmp-dev libicu-dev
            libjpeg-dev "$ldap_dev" libsasl2-dev libonig-dev libpng-dev libpcre2-dev
            libpq-dev libreadline-dev libsodium-dev libsqlite3-dev libssl-dev
            libwebp-dev libxml2-dev libxslt1-dev libzip-dev zlib1g-dev libaspell-dev libpspell-dev
        )
        if [[ $os_id == astra ]]; then
            # Astra's Apache initializes its audit event list even with the smoke-test config.
            packages+=(syslog-ng-mod-astra)
        fi
        install_command="apt-get $apt_options update && DEBIAN_FRONTEND=noninteractive apt-get $apt_options install -y --no-install-recommends ${packages[*]}"
    else
        install_command='dnf -y install gcc gcc-c++ make pkgconf-pkg-config autoconf libtool bison \
        re2c cmake ca-certificates /usr/bin/curl /usr/bin/setsid httpd httpd-devel file binutils tar xz \
        dnf-plugins-core createrepo_c bzip2-devel libcurl-devel freetype-devel gmp-devel \
        libicu-devel libjpeg-turbo-devel openldap-devel cyrus-sasl-devel oniguruma-devel \
        libpng-devel pcre2-devel "pkgconfig(libpq)" readline-devel libsodium-devel \
        sqlite-devel openssl-devel libwebp-devel libxml2-devel libxslt-devel libzip-devel \
        zlib-devel aspell-devel'
        if [[ $profile == redos73 ]]; then
            install_command+=' GeoIP-devel'
        else
            # Use the upstream release where the distro GeoIP Legacy package is unavailable.
            geoip_setup="RUN mkdir /tmp/geoip-build && cd /tmp/geoip-build \\
                && curl -fsSL --retry 3 -o GeoIP.tar.gz 'https://github.com/maxmind/geoip-api-c/releases/download/v$GEOIP_VERSION/GeoIP-$GEOIP_VERSION.tar.gz' \\
                && printf '%s  %s\n' '$GEOIP_SHA' GeoIP.tar.gz | sha256sum -c - \\
                && tar -xzf GeoIP.tar.gz --strip-components=1 \\
                && ./configure --prefix=/opt/geoip-legacy --libdir='$GEOIP_LIBDIR' --disable-static \\
                && make -j2 && make install \\
                && rm -f '$GEOIP_LIBDIR/libGeoIP.la' \\
                && install -Dm644 GeoIP.tar.gz '$NGINX_PREFIX/share/geoip/GeoIP-$GEOIP_VERSION.tar.gz' \\
                && cd / && rm -rf /tmp/geoip-build"
        fi
        if [[ $profile == almalinux9 ]]; then
            install_command="dnf -y install dnf-plugins-core && dnf config-manager --set-enabled crb && dnf -y install epel-release && $install_command"
        fi
    fi
    docker build --platform linux/amd64 "${pull_options[@]}" --no-cache --build-arg "BASE=$base" -t "$tag" -f - . <<DOCKERFILE
ARG BASE
FROM \${BASE}
USER root
$apt_setup
RUN $install_command
$geoip_setup
DOCKERFILE
}


check_mod_php() (
    local apxs=$1 target_os=$2 httpd module_dir pid response= attempt
    httpd=$(command -v apache2 || command -v httpd)
    module_dir=$("$apxs" -q LIBEXECDIR)
    mkdir -p /build/apache-check/htdocs
    cat > /build/apache-check/test.conf <<CONF
ServerRoot "/build/apache-check"
ServerName localhost
Listen 127.0.0.1:19085
PidFile "/build/apache-check/httpd.pid"
ErrorLog "/build/apache-check/error.log"
LoadModule mpm_prefork_module "$module_dir/mod_mpm_prefork.so"
LoadModule authz_core_module "$module_dir/mod_authz_core.so"
LoadModule php_module "$PHP_PREFIX/lib/apache/libphp.so"
PHPIniDir "$PHP_PREFIX/etc"
User nobody
Group $(id -gn nobody)
DocumentRoot "/build/apache-check/htdocs"
<Directory "/build/apache-check/htdocs">
    Require all granted
</Directory>
<Files "check.php">
    SetHandler application/x-httpd-php
</Files>
CONF
    if [[ $target_os == astra ]]; then
        # The loopback smoke test runs without PAM or PARSEC in the build container.
        printf '%s\n' 'AstraMode off' >> /build/apache-check/test.conf
    fi
    cat > /build/apache-check/htdocs/check.php <<'PHPTEST'
<?php
if (!extension_loaded('pspell') || !function_exists('mysqli_report')) {
    http_response_code(500);
    exit;
}
echo PHP_SAPI, " ", PHP_VERSION;
PHPTEST
    "$httpd" -t -f /build/apache-check/test.conf
    # Prefork sends SIGTERM to its process group when it shuts down.
    set +m
    setsid "$httpd" -D FOREGROUND -f /build/apache-check/test.conf &
    pid=$!
    trap 'kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
    for attempt in 1 2 3 4 5; do
        response=$(curl --noproxy '*' --fail --silent --max-time 3 http://127.0.0.1:19085/check.php || true)
        if [[ $response == "apache2handler $PHP" ]]; then
            printf 'PHP HTTP check passed: %s\n' "$response"
            return 0
        fi
        sleep 1
    done
    cat /build/apache-check/error.log >&2
    die "Apache did not run the new PHP module"
)

build_pagespeed() (
    [[ $pagespeed != none ]] || die "No documented PageSpeed build target for $profile"
    local checkout=${1:-} result sha tmp
    [[ -n $checkout ]] || die 'Pass the prepared We-Amp mod_pagespeed checkout path'
    checkout=$(cd -- "$checkout" && pwd -P)
    [[ -d $checkout/vendor && -f $checkout/install/nginx/build_module_in_container.sh ]] ||
        die "Prepare the We-Amp checkout and vendor directory first"
    [[ -f $sources/SHA256SUMS ]] || die 'Run prepare first'
    [[ -z $(git -C "$checkout" status --porcelain --untracked-files=no) ]] ||
        die "We-Amp checkout has modified tracked files"
    sha=$(sha256sum "$sources/nginx-$NGINX.tar.gz")
    result="$work/pagespeed/$profile"
    mkdir -p "$result"
    tmp=$(mktemp -d "$result/.staging.XXXXXX")
    trap 'rm -rf -- "$tmp"' EXIT
    docker run --rm --platform linux/amd64 \
        --mount "type=bind,src=$checkout,dst=/src" \
        --mount "type=bind,src=$tmp,dst=/ps-out" --workdir /src \
        --env "NGINX_SRC_VERSION=$NGINX" --env "NGINX_SRC_SHA256=${sha%% *}" \
        --entrypoint bash "$base" -ec '
            bash install/nginx/build_module_in_container.sh "$1"
            install -m 0644 bazel-bin/pagespeed/nginx/ngx_pagespeed_module.so /ps-out/
            chown "$2" /ps-out/ngx_pagespeed_module.so
        ' bash "$pagespeed" "$(id -u):$(id -g)"
    {
        printf 'Target: %s\n' "$pagespeed"
        printf 'Source: %s\n' "$(git -C "$checkout" rev-parse HEAD)"
        printf 'Nginx: %s\n' "$NGINX"
        printf 'Nginx tarball SHA256: %s\n' "${sha%% *}"
        printf 'Module SHA256: '
        sha256sum "$tmp/ngx_pagespeed_module.so" | cut -d ' ' -f1
    } > "$tmp/BUILD.txt"
    mv -fT -- "$tmp/ngx_pagespeed_module.so" "$result/ngx_pagespeed_module.so"
    mv -fT -- "$tmp/BUILD.txt" "$result/BUILD.txt"
    printf 'Created %s\n' "$result/ngx_pagespeed_module.so"
)

compile_inside() {
    local profile=$1 jobs=$2 apxs
    profile_info "$profile"
    check_os
    command -v setsid >/dev/null || die "setsid is missing from the builder image. Run: bash build.sh prepare $profile"
    if [[ $os_id == astra && ! -s /etc/astra-syslog.conf ]]; then
        die "Missing /etc/astra-syslog.conf in the builder image. Run: bash build.sh prepare $profile"
    fi
    local -a geoip_args=()
    if [[ $family == deb ]]; then
        dpkg-query -W -f='${Status}\n' libgeoip-dev 2>/dev/null | grep -Fxq 'install ok installed' ||
            die "GeoIP development files are missing. Run: bash build.sh prepare $profile"
    elif [[ $profile == redos73 ]]; then
        rpm -q GeoIP-devel >/dev/null || die "GeoIP development files are missing. Run: bash build.sh prepare $profile"
    else
        [[ -r /opt/geoip-legacy/include/GeoIP.h && -e $GEOIP_LIBDIR/libGeoIP.so ]] ||
            die "GeoIP development files are missing. Run: bash build.sh prepare $profile"
        geoip_args+=(--with-cc-opt=-I/opt/geoip-legacy/include
            "--with-ld-opt=-L$GEOIP_LIBDIR -Wl,-rpath,$GEOIP_LIBDIR")
    fi
    umask 022
    (cd /sources && sha256sum --quiet -c SHA256SUMS)
    mkdir -p /build /out/payload/opt
    cd /build
    tar -xf "/sources/php-$PHP.tar.xz"
    tar -xf "/sources/nginx-$NGINX.tar.gz"
    tar -xf /sources/nginx-modules.tar.gz
    tar -xf "/sources/pspell-$PSPELL.tgz"

    local -a php_library_args=()
    if [[ $os_id == astra ]]; then
        php_library_args+=(--with-libdir=lib/x86_64-linux-gnu)
        cp /etc/astra_version /out/astra-version.txt
    elif [[ $family == rpm ]]; then
        php_library_args+=(--with-libdir=lib64)
    fi
    apxs=$(command -v apxs2 || command -v apxs)
    cd "/build/php-$PHP"
    ./configure \
        --prefix="$PHP_PREFIX" \
        --with-config-file-path="$PHP_PREFIX/etc" \
        --with-config-file-scan-dir="$PHP_PREFIX/etc/conf.d" \
        --with-apxs2="$apxs" --enable-cli --enable-fpm --disable-cgi --disable-phpdbg --without-pear \
        --enable-bcmath --enable-calendar --enable-ctype --enable-dom --enable-exif \
        --enable-fileinfo --enable-filter --enable-gd --enable-intl --enable-mbstring \
        --enable-mysqlnd --enable-pcntl --enable-phar --enable-posix --enable-shmop \
        --enable-simplexml --enable-sockets --enable-sysvmsg --enable-sysvsem \
        --enable-sysvshm --enable-xml --enable-xmlreader --enable-xmlwriter \
        --with-bz2 --with-curl --with-freetype --with-gettext --with-gmp --with-iconv \
        --with-jpeg --with-ldap --with-ldap-sasl --with-mysqli=mysqlnd --with-openssl \
        --with-pdo-mysql=mysqlnd --with-pdo-pgsql --with-pdo-sqlite --with-pgsql \
        --with-readline --with-sodium --with-sqlite3 --with-webp --with-xsl \
        --with-zip --with-zlib "${php_library_args[@]}"
    make -j"$jobs"
    make install
    install -D -m 0755 "$("$apxs" -q LIBEXECDIR)/libphp.so" "$PHP_PREFIX/lib/apache/libphp.so"
    install -m 0644 php.ini-production "$PHP_PREFIX/etc/php.ini"
    install -d "$PHP_PREFIX/etc/conf.d"

    cd "/build/pspell-$PSPELL"
    "$PHP_PREFIX/bin/phpize"
    local -a pspell_args=(--with-pspell=/usr)
    if [[ $family == deb ]]; then
        local multiarch
        multiarch=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
        pspell_args+=("--with-libdir=lib/$multiarch")
    else
        pspell_args+=(--with-libdir=lib64)
    fi
    ./configure --with-php-config="$PHP_PREFIX/bin/php-config" "${pspell_args[@]}"
    make -j"$jobs"
    make install
    printf '%s\n' 'extension=pspell.so' > "$PHP_PREFIX/etc/conf.d/20-pspell.ini"
    "$PHP_PREFIX/bin/php" -r '
        $required = explode(" ", "bcmath bz2 calendar ctype curl dom exif fileinfo filter gd gettext gmp iconv intl ldap mbstring mysqli mysqlnd openssl pcntl PDO pdo_mysql pdo_pgsql pdo_sqlite pgsql Phar posix pspell readline shmop SimpleXML sockets sodium sqlite3 sysvmsg sysvsem sysvshm xml xmlreader xmlwriter xsl " . "Zend-OPcache zip zlib");
        foreach ($required as $name) {
            $name = str_replace("Zend-OPcache", "Zend OPcache", $name);
            if (!extension_loaded($name)) {
                fwrite(STDERR, "Missing PHP extension: $name\n");
                exit(1);
            }
        }
        foreach (["JPEG Support", "WebP Support", "FreeType Support"] as $feature) {
            if (empty(gd_info()[$feature])) {
                fwrite(STDERR, "Missing GD feature: $feature\n");
                exit(1);
            }
        }
        if (!function_exists("mysqli_report") || !function_exists("ldap_sasl_bind")) {
            fwrite(STDERR, "Missing MySQLi or LDAP SASL support\n");
            exit(1);
        }'
    "$PHP_PREFIX/sbin/php-fpm" -v
    printf '== Check PHP through Apache ==\n'
    check_mod_php "$apxs" "$os_id"

    printf '== Build nginx and Brotli ==\n'
    # The nginx build itself never needs to fetch Brotli or any other sources.
    # Shared modules are compiled with the same configure run as the binary.
    local nginx_args=(
        "--prefix=$NGINX_PREFIX"
        "--sbin-path=$NGINX_PREFIX/sbin/nginx"
        "--modules-path=$NGINX_PREFIX/modules"
        "--conf-path=$NGINX_PREFIX/conf/nginx.conf"
        "--pid-path=/run/nginx-1.30.7/nginx.pid"
        --with-compat --with-threads --with-file-aio --with-pcre-jit
        --with-http_ssl_module --with-http_v2_module --with-http_realip_module
        --with-http_addition_module --with-http_sub_module --with-http_dav_module
        --with-http_flv_module --with-http_mp4_module --with-http_gunzip_module
        --with-http_gzip_static_module --with-http_auth_request_module
        --with-http_random_index_module --with-http_secure_link_module
        --with-http_degradation_module --with-http_slice_module --with-http_stub_status_module
        --with-http_xslt_module=dynamic --with-http_geoip_module=dynamic
        --with-stream=dynamic --with-stream_ssl_module --with-stream_realip_module
        --with-stream_ssl_preread_module --with-mail --with-mail_ssl_module
        --add-dynamic-module=/build/mod_zip --add-dynamic-module=/build/headers-more
        --add-dynamic-module=/build/brotli
    )
    cd "/build/nginx-$NGINX"
    if [[ $pagespeed != none ]]; then
        [[ -s /pagespeed/ngx_pagespeed_module.so ]] || die "Missing native PageSpeed module for $profile"
    fi
    # Use the architecture baseline of the target distro rather than the builder CPU.
    cmake -S /build/brotli/deps/brotli -B /build/brotli/deps/brotli/out \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    cmake --build /build/brotli/deps/brotli/out --parallel "$jobs"
    ./configure "${nginx_args[@]}" "${geoip_args[@]}"
    make -j"$jobs"
    make install
    if [[ $pagespeed != none ]]; then
        install -m 0644 /pagespeed/ngx_pagespeed_module.so "$NGINX_PREFIX/modules/"
    fi

    # Test loading every dynamic module together using the built executable.
    mkdir -p /run/nginx-1.30.7
    local so
    for so in ngx_http_geoip_module.so ngx_stream_module.so; do
        [[ -s $NGINX_PREFIX/modules/$so ]] || die "Missing nginx module: $so"
    done
    {
        for so in "$NGINX_PREFIX"/modules/*.so; do
            printf 'load_module "%s";\n' "$so"
        done
        printf 'error_log stderr;\nevents {}\nhttp { access_log off; }\nstream {}\n'
    } > /build/modules.conf
    "$NGINX_PREFIX/sbin/nginx" -t -c /build/modules.conf

    local ID VERSION_ID package library
    . /etc/os-release
    printf '%s\n' "$profile" "$ID" "$VERSION_ID" "$family" > /out/target
    cp -a "$PHP_PREFIX" "$NGINX_PREFIX" /out/payload/opt/
    cp /sources/MODULES.txt /sources/SHA256SUMS /out/
    "$NGINX_PREFIX/sbin/nginx" -V > /out/nginx-build.txt 2>&1
    { "$PHP_PREFIX/bin/php" -v; "$PHP_PREFIX/bin/php" -m; "$PHP_PREFIX/bin/php" --ri gd; } > /out/php-build.txt
    printf '== Identify runtime library packages ==\n'
    # Capture owners of both direct and transitive shared libraries.
    {
        for binary in "$(command -v curl)" "$PHP_PREFIX/bin/php" "$PHP_PREFIX/sbin/php-fpm" \
            "$PHP_PREFIX/lib/apache/libphp.so" "$("$PHP_PREFIX/bin/php-config" --extension-dir)"/*.so \
            "$NGINX_PREFIX/sbin/nginx" "$NGINX_PREFIX/modules/"*.so
        do
            ldd "$binary" > /build/ldd.txt
            if grep -q 'not found' /build/ldd.txt; then
                cat /build/ldd.txt >&2
                die "Unresolved ELF dependency in $binary"
            fi
            awk '$2=="=>" && $3~/^\// {print $3} $1~/^\// {print $1}' /build/ldd.txt
        done
    } | sort -u > /build/libraries.txt
    {
        printf '%s\n' ca-certificates
        if [[ $family == deb ]]; then
            printf '%s\n' curl
        else
            rpm -qf --queryformat '%{NAME}\n' "$(command -v curl)"
        fi
        while IFS= read -r library; do
            # Source-built libGeoIP is shipped in the nginx prefix.
            [[ $library == "$GEOIP_LIBDIR"/libGeoIP.so.* ]] && continue
            if [[ $family == deb ]]; then
                package=$(dpkg-query -S "$library" 2>/dev/null ||
                    dpkg-query -S "$(readlink -f "$library")" 2>/dev/null ||
                    dpkg-query -S "${library#/usr}" 2>/dev/null ||
                    dpkg-query -S "/usr$library" 2>/dev/null ||
                    die "Could not identify the package providing $library")
                printf '%s\n' "${package%%: /*}"
            else
                rpm -qf --queryformat '%{NAME}\n' "$(readlink -f "$library")"
            fi
        done < /build/libraries.txt
    } | sort -u > /out/runtime-packages.txt
}

collect_packages() {
    profile_info "$1"
    check_os
    local packages=()
    mapfile -t packages < /out/runtime-packages.txt
    (("${#packages[@]}")) || die "Empty list of runtime packages"
    mkdir -p /out/packages
    if [[ $family == deb ]]; then
        local -a apt_options=()
        if [[ $os_id == astra ]]; then
            apt_options=(-o "Dir::Etc::sourcelist=$astra_apt_list" -o Dir::Etc::sourceparts=-)
        fi
        mkdir -p /out/packages/partial
        apt-get "${apt_options[@]}" -y --download-only --no-install-recommends \
            -o Dir::State::status=/dev/null -o Dir::Cache::archives=/out/packages \
            install "${packages[@]}"
        cd /out/packages
        dpkg-scanpackages . /dev/null | gzip -n > Packages.gz
        rm -f lock
        rmdir partial
    else
        dnf -y download --resolve --alldeps --destdir /out/packages "${packages[@]}"
        createrepo_c /out/packages
    fi
}

case "${1:-}" in
    __compile|__packages)
        [[ ${BUILD_OUTPUT_OWNER:-} =~ ^[0-9]+:[0-9]+$ ]] || die 'Run via the host build command'
        trap 'chown -hR "$BUILD_OUTPUT_OWNER" /out' EXIT
        if [[ $1 == __compile ]]; then compile_inside "$2" "$3"; else collect_packages "$2"; fi
        exit
        ;;
    prepare|pagespeed|build) ;;
    *) die "Usage: bash build.sh {prepare|pagespeed|build} PROFILE [PAGESPEED_CHECKOUT]" ;;
esac

action=$1
profile=${2:-}
profile_info "$profile"
[[ $(uname -m) == x86_64 ]] || die "Use an x86_64 builder"
docker info >/dev/null || die "Docker is unavailable in this session"
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
work=${BUILD_WORK:-"$project/work"}
mkdir -p "$work"
work=$(cd -- "$work" && pwd -P)
exec 9>"$work/.build.lock"
flock 9
cd "$project"
tag="offline-stack-build:$profile"
sources="$work/sources"

if [[ $action == prepare ]]; then
    [[ -n $base ]] || die "Set REDOS_IMAGE to an image for $profile (ID=redos, VERSION_ID=$os_version or a matching point release)"
    prepare_sources "$sources"
    prepare_image "$tag"
    exit
fi

if [[ $action == pagespeed ]]; then
    build_pagespeed "${3:-}"
    exit
fi

[[ -f $sources/SHA256SUMS ]] || die "Run prepare first"
docker image inspect "$tag" >/dev/null || die "Prepare the builder image first"
jobs=${JOBS:-$(nproc)}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer"
tmp=$(mktemp -d "$work/$profile.XXXXXX")
build_log="$work/$profile-build.log"
trap '
    status=$?
    if (( status == 0 )); then
        rm -rf -- "$tmp"
    else
        printf "Build failed (exit %d).\nLog: %s\nWork files: %s\n" "$status" "$build_log" "$tmp" >&2
    fi
' EXIT
printf 'Build log: %s\n' "$build_log"
out="$tmp/stack"
mkdir "$out"
mounts=(
    --mount "type=bind,src=$project,dst=/project,readonly"
    --mount "type=bind,src=$sources,dst=/sources,readonly"
    --mount "type=bind,src=$out,dst=/out"
    --env "BUILD_OUTPUT_OWNER=$(id -u):$(id -g)"
)
if [[ $pagespeed != none ]]; then
    ps_dir=${PAGESPEED_DIR:-"$work/pagespeed/$profile"}
    [[ -s $ps_dir/ngx_pagespeed_module.so && -s $ps_dir/BUILD.txt ]] ||
        die "Prepare PageSpeed for $profile following README.md (target: $pagespeed)"
    ps_dir=$(cd -- "$ps_dir" && pwd -P)
    mounts+=(--mount "type=bind,src=$ps_dir,dst=/pagespeed,readonly")
    cp "$ps_dir/BUILD.txt" "$out/pagespeed-build.txt"
fi
(
    printf '== Compile %s ==\n' "$profile"
    docker run --rm --network none "${mounts[@]}" --entrypoint bash "$tag" \
        /project/build.sh __compile "$profile" "$jobs"
    printf '== Download runtime packages ==\n'
    docker run --rm "${mounts[@]}" --entrypoint bash "$tag" \
        /project/build.sh __packages "$profile"
    printf '== Create the transfer archive ==\n'
    docker image inspect --format '{{.Id}}' "$tag" > "$out/builder-image.txt"
    install -m 0755 "$project/deploy.sh" "$out/deploy.sh"
    install -m 0644 "$project/README.md" "$out/README.md"
    (
        cd "$out"
        find . -type f ! -path './MANIFEST.sha256' -print0 | sort -z | xargs -0 sha256sum > MANIFEST.sha256
    )
    archive="$work/stack-php$PHP-nginx$NGINX-$profile-x86_64.tar.gz"
    tar --owner=0 --group=0 --numeric-owner -C "$out" -czf "$tmp/stack.tar.gz" .
    mv -T -- "$tmp/stack.tar.gz" "$archive"
    (cd "$work" && sha256sum "$(basename -- "$archive")") > "$archive.sha256"
    printf 'Created %s\n' "$archive"
) 2>&1 | tee "$build_log"
