# Офлайн-развёртывание nginx и Apache с PHP

Соберите два образа Linux amd64 на машине с Docker и интернетом. Из корня проекта запустите:

```bash
bash containers/build.sh
```

Перенесите на сервер `compose.yaml`, `nginx.conf` и оба выходных файла из `work/` — `docker-nginx1.30.8-php8.5.13-amd64.tar.gz` и его файл `.sha256`. На сервере нужны Docker Engine и Docker Compose v2. В каталоге с файлами выполните:

```bash
sha256sum -c docker-nginx1.30.8-php8.5.13-amd64.tar.gz.sha256 &&
docker load -i docker-nginx1.30.8-php8.5.13-amd64.tar.gz
```

Укажите в `.env` абсолютный путь к корню сайта. Путь должен существовать. Пользователю Apache в контейнере нужны права на чтение файлов сайта и запись в каталоги, которые использует приложение.

```dotenv
SITE_DIR=/srv/www/example
HTTP_BIND=127.0.0.1
HTTP_PORT=8080
```

```bash
docker compose up -d --pull never
docker compose ps
docker compose exec nginx nginx -t
docker compose exec php php -v
curl -I http://127.0.0.1:8080/
```

Наружу публикуется только порт nginx. По умолчанию он слушает локальный адрес для проверки рядом с действующим стеком. Перед переключением рабочего сайта перенесите nginx-конфигурацию и TLS, а также настройки Apache, PHP и подключения к БД. Backend nginx внутри Compose доступен по адресу `php:80`. Для БД на хосте укажите доступный из контейнера адрес либо смонтируйте каталог с Unix-сокетом. Внутри контейнера `localhost` указывает на сам контейнер.

Сборка nginx включает GeoIP Legacy, Stream, Brotli, headers-more и mod_zip. Для GeoIP при необходимости отдельно подключите базу `.dat`. PageSpeed для 1.30.8 требует отдельной сборки и проверки совместимости модуля.
