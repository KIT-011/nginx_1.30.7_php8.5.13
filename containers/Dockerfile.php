FROM php:8.5.13-apache-trixie
ARG JOBS=4
RUN set -eux; apt-get update; apt-get install -y --no-install-recommends \
    libbz2-dev libfreetype-dev libgmp-dev libicu-dev libjpeg62-turbo-dev libldap-dev \
    libpng-dev libpq-dev libpspell-dev libsasl2-dev libwebp-dev libxslt1-dev libzip-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-configure ldap --with-libdir="lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)" --with-ldap-sasl; \
    docker-php-ext-install -j"$JOBS" bcmath bz2 calendar exif gd gettext gmp intl ldap mysqli \
        pcntl pdo_mysql pdo_pgsql pgsql shmop sockets sysvmsg sysvsem sysvshm xsl zip; \
    curl -fsSL --retry 3 https://pecl.php.net/get/pspell-1.0.1.tgz -o /tmp/pspell.tgz; \
    tar -xzf /tmp/pspell.tgz -C /tmp; cd /tmp/pspell-1.0.1; phpize; \
    ./configure --with-pspell=/usr --with-libdir="lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)"; \
    make -j"$JOBS"; make install; docker-php-ext-enable pspell; \
    php -r 'exit(PHP_VERSION !== "8.5.13" || !function_exists("mysqli_report") || !extension_loaded("pspell") || !gd_info()["WebP Support"]);'; \
    apache2ctl configtest; rm -rf /var/lib/apt/lists/* /tmp/pspell*
