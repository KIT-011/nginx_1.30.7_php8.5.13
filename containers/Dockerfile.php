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
    for ext in cli common bcmath bz2 curl gd gmp intl ldap mbstring mysql pgsql readline sqlite3 xml zip; do \
        set -- "$@" "php$series-$ext=$version"; \
    done; \
    apt-get install -y --no-install-recommends apache2 "$@" "php$series-pspell"; \
    a2dismod mpm_event mpm_worker; \
    a2enmod mpm_prefork "php$series" rewrite headers; \
    printf '%s\n' 'ServerName localhost' '<Directory /var/www/html>' '    AllowOverride All' \
        '    Options -Indexes' '</Directory>' > /etc/apache2/conf-available/site.conf; \
    a2enconf site; \
    apache2ctl configtest; \
    rm -rf /var/lib/apt/lists/* /tmp/sury-keyring.deb
COPY --chmod=0755 apache-foreground.sh /usr/local/bin/apache-foreground
COPY check-php.php /tmp/check-php.php
RUN set -eu; \
    result=$(php /tmp/check-php.php) || { printf '%s\n' "$result" >&2; exit 1; }; \
    test "$result" = "cli $PHP_VERSION"; \
    install -m 0644 /tmp/check-php.php /var/www/html/check-php.php; \
    apache-foreground & pid=$!; \
    trap 'kill "$pid" 2>/dev/null || true; wait "$pid" || true' EXIT; \
    for attempt in 1 2 3 4 5; do \
        if result=$(curl --noproxy '*' --silent --max-time 3 http://127.0.0.1/check-php.php); then break; fi; \
        sleep 1; \
    done; \
    if [ "$result" != "apache2handler $PHP_VERSION" ]; then printf 'Apache check: %s\n' "$result" >&2; exit 1; fi; \
    rm -f /tmp/check-php.php /var/www/html/check-php.php
EXPOSE 80
STOPSIGNAL SIGWINCH
CMD ["apache-foreground"]
