# Compose для Bitrix с Apache и PHP

По умолчанию Compose запускает nginx и Apache с PHP 8.5.13 из офлайн-комплекта. nginx, Apache и PHP читают конфиги с хоста. Домен, IP и путь сайта задаются на сервере. При сборке образа проверяются версия PHP, расширения для сайта и запуск PHP через Apache. PCNTL и Readline проверяются в CLI.

## Настройка при первом запуске

1. После `docker load` положите рядом `compose.yml`, `site.env.example` и `images.env` из офлайн-комплекта. Создайте `site.env` на основе примера. Укажите существующий абсолютный `SITE_DIR`. Если `root`, `alias` или `DocumentRoot` используют другие пути внутри контейнеров, задайте `NGINX_SITE_DIR` и `APACHE_SITE_DIR`. Для нескольких сайтов можно подключить общий родительский каталог с сохранением структуры.

2. Создайте каталог PHP на хосте. По умолчанию это `php/` рядом с Compose. Его путь можно изменить через `PHP_CONFIG_DIR` в `site.env`.

```bash
mkdir -p php/conf.d
```

Скопируйте свой `php.ini` в `php/php.ini`. Дополнительные настройки поместите в `php/conf.d/*.ini`. PHP сначала читает `php.ini`, затем загружает расширения по настройкам из образа и применяет ваши дополнительные `.ini`. Из старой конфигурации переносите настройки приложения, например лимиты, сессии и часовой пояс. Строки загрузки старых расширений, включая `zend_extension=opcache.so`, удалите. В Apache уберите прежний `PHPIniDir` или укажите `PHPIniDir /etc/offline-php`.

3. Подготовьте копию действующей конфигурации Apache и укажите её через `APACHE_CONFIG_DIR`. Для Apache с Debian-layout проверьте, что в `mods-enabled` подключены `mpm_prefork` и один модуль PHP с директивой:

```apache
LoadModule php_module /usr/lib/apache2/modules/libphp8.5.so
```

Сохраните обработчик `SetHandler application/x-httpd-php` для разрешённых PHP-файлов и ограничения сайта. Если ранее использовался PHP-FPM, уберите обработчик FastCGI для этих файлов в копии конфигурации. Образ использует `/etc/apache2`. Если на хосте дерево `/etc/httpd`, перенесите виртуальные хосты и настройки в конфигурацию совместимого Apache в образе. Укажите `Listen` на прежнем локальном порту backend, например `127.0.0.1:8090`. При использовании Unix-сокета БД подключите его каталог через bind mount. Логи и состояние Apache по умолчанию подключаются из `/var/log/apache2` и `/var/lib/apache2`. Переопределите пути через `APACHE_LOG_DIR` и `APACHE_STATE_DIR`, если на хосте они отличаются.

4. nginx берёт конфигурацию из `/etc/nginx` и через сеть хоста подключается к Apache. Имена `httpd` и `push` указывают на loopback. Пример прежнего backend — `proxy_pass http://httpd:8090;`. Подключите пути к сертификатам и внешним `include`, если они находятся за пределами смонтированных каталогов. Если `/usr/share/nginx/html` отсутствует на хосте, задайте `NGINX_HTML_DIR` или удалите это монтирование, если оно не используется. Лимиты `json-file` действуют на вывод контейнеров. Файловые логи ротируются на хосте.

## Проверка и запуск

В примерах имя проекта — `bitrix-web`. Если nginx уже работает в Compose, используйте его текущее имя проекта. Его можно узнать командой `docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' nginx-web`.

```bash
docker compose -p bitrix-web --env-file site.env --env-file images.env \
  run --rm --no-deps nginx -t &&
docker compose -p bitrix-web --env-file site.env --env-file images.env \
  run --rm --no-deps --entrypoint apache2ctl apache configtest &&
docker compose -p bitrix-web --env-file site.env --env-file images.env \
  run --rm --no-deps --entrypoint php apache --ini
```

При первом переносе Apache в контейнер остановите прежнюю службу `apache2` или `httpd` в окно обслуживания. Если nginx вне этого проекта занимает порты из конфигурации, освободите их и задайте свободное имя через `NGINX_CONTAINER_NAME`. Затем запустите оба сервиса:

```bash
docker compose -p bitrix-web --env-file site.env --env-file images.env up -d --no-build
```

Для запуска только nginx с Apache на хосте добавьте `nginx` в конец команды. PHP в этом режиме обслуживает Apache на хосте.

## Изменение конфигурации

Редактируйте `php/php.ini` или файлы в `php/conf.d/` на хосте. После изменения PHP или Apache перезапустите сервис `apache`:

```bash
docker compose -p bitrix-web --env-file site.env --env-file images.env restart apache
```

Проверьте работу сайта через nginx после запуска и после изменений. Для отката на хостовый Apache остановите сервис `apache` в Compose и запустите прежний `apache2` или `httpd`.
