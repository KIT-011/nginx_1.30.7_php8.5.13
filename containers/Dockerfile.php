FROM debian:trixie-slim
ARG PHP_VERSION=8.5.13
RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update -o APT::Update::Error-Mode=any; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    curl -fsSL --retry 3 https://packages.sury.org/debsuryorg-archive-keyring.deb -o /tmp/sury-keyring.deb; \
    dpkg -i /tmp/sury-keyring.deb; \
    printf '%s\n' 'deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ trixie main' \
        > /etc/apt/sources.list.d/sury-php.list; \
    apt-get update -o APT::Update::Error-Mode=any; \
    series="${PHP_VERSION%.*}"; \
    version="$(apt-cache madison "libapache2-mod-php$series" | awk -F'|' -v want="$PHP_VERSION" '{ \
        v=$2; gsub(/[[:space:]]/, "", v); upstream=v; sub(/^[0-9]+:/, "", upstream); \
        if (index(upstream, want "-") == 1) { print v; exit } }')"; \
    if [ -z "$version" ]; then echo "PHP $PHP_VERSION is unavailable in the signed repository" >&2; exit 1; fi; \
    set -- "libapache2-mod-php$series=$version"; \
    for ext in cli common bcmath bz2 curl gd gmp intl ldap mbstring mysql pgsql sqlite3 xml zip; do \
        set -- "$@" "php$series-$ext=$version"; \
    done; \
    apt-get install -y --no-install-recommends apache2 "$@" "php$series-pspell"; \
    a2dismod mpm_event mpm_worker; \
    a2enmod mpm_prefork "php$series" rewrite headers; \
    printf '%s\n' 'ServerName localhost' '<Directory /var/www/html>' '    AllowOverride All' \
        '    Options -Indexes' '</Directory>' > /etc/apache2/conf-available/site.conf; \
    a2enconf site; \
    "php$series" -r 'exit(PHP_VERSION !== $argv[1] || !function_exists("mysqli_report") || !extension_loaded("pspell") || !gd_info()["WebP Support"]);' "$PHP_VERSION"; \
    apache2ctl configtest; \
    apache2ctl -M | grep -q 'php_module'; \
    rm -rf /var/lib/apt/lists/* /tmp/sury-keyring.deb
EXPOSE 80
STOPSIGNAL SIGWINCH
CMD ["sh", "-c", ". /etc/apache2/envvars && mkdir -p \"$APACHE_RUN_DIR\" \"$APACHE_LOCK_DIR\" && rm -f \"$APACHE_PID_FILE\" && exec /usr/sbin/apache2 -D FOREGROUND"]
