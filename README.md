# Офлайн-сборка PHP 8.5.13 и nginx 1.30.7

Сборочная машина — Ubuntu 24.04 x86_64 с Docker и доступом к Интернету. Сборки выполняются в контейнерах целевых ОС. На целевом сервере нужны systemd и установленный Apache соответствующей ОС. Готовый архив включает PHP (CLI, FPM, модуль Apache), nginx с модулями, локальный репозиторий зависимостей и скрипт установки.

| Профиль | ОС | PageSpeed |
| --- | --- | --- |
| `ubuntu22` | Ubuntu 22.04 | `jammy` |
| `ubuntu24` | Ubuntu 24.04 | `noble` |
| `debian12` | Debian 12 | `bookworm` |
| `debian13` | Debian 13 | `trixie` |
| `redos73` | РЕД ОС 7.3 | — |
| `redos8` | РЕД ОС 8 | — |

Профили CentOS 7, CentOS Stream 9 и AlmaLinux 9 с BitrixEnv/BitrixVM относятся к отдельному этапу.

## 1. Сборочная машина

Понадобятся `docker`, `docker compose`, `curl`, `git`, `gpg` и GNU coreutils. Установите и запустите Docker на сборочной Ubuntu. Доступ к Docker нужен пользователю, который запускает команды. Поместите `build.sh`, `deploy.sh` и `README.md` в один каталог.

Начните с `ubuntu24`. Команда `prepare` получает исходники, проверяет SHA-256 PHP и подпись nginx, запоминает коммиты внешних модулей, затем ставит инструменты сборки в образ.

```bash
bash build.sh prepare ubuntu24
```

Каталог `work/sources` общий для всех профилей. Сохраните его для повторных сборок с теми же ревизиями `ngx_brotli`, `headers-more` и `mod_zip`. Ревизии и хеши попадут в каждый архив. Для полной повторяемости сохраните также образ сборки и архивы пакетов, так как состав репозиториев ОС со временем меняется.

### PageSpeed для Ubuntu и Debian

Подготовьте зависимости Bazel один раз. Используйте исходники нативного модуля We-Amp и зафиксируйте конкретный тег. При переходе между профилями запускайте сборки PageSpeed последовательно в одном checkout.

```bash
git clone https://github.com/We-Amp/mod_pagespeed.git pagespeed-src
tag=$(git -C pagespeed-src tag --list 'v*' --sort=-v:refname | head -n 1)
test -n "$tag" && git -C pagespeed-src checkout --detach "$tag"

(
    cd pagespeed-src
    docker compose up -d dev
    trap 'docker compose down' EXIT
    docker compose exec -T dev tools/vendor-deps.sh
)
bash build.sh pagespeed ubuntu24 ./pagespeed-src
```

`build.sh pagespeed` передаёт upstream-скрипту версию nginx 1.30.7 и SHA-256 проверенного архива. Он сохраняет модуль в `work/pagespeed/ubuntu24` с данными сборки. Скрипт `build` проверяет загрузку этого модуля вместе с другими модулями в собранный nginx. Если версия upstream требует отдельного шага, выполните его по [инструкции сборки PageSpeed](https://ngxpagespeed.com/install/from-source/). Внешний результат можно указать через `PAGESPEED_DIR`, в каталоге должны быть `ngx_pagespeed_module.so` и `BUILD.txt`.

### Сборка пакета

```bash
JOBS=4 bash build.sh build ubuntu24
```

PHP и nginx компилируются в контейнере с `--network none`. Скрипт проверяет PHP-модули, JPEG/WebP/FreeType, обработку PHP запросом в тестовом Apache и загрузку модулей nginx. Затем отдельный контейнер скачивает пакеты, владеющие нужными библиотеками, и их зависимости. Готовый архив и его SHA-256 лежат в `work/`.

Когда первый комплект пройдёт установку на тестовом сервере, соберите остальные Ubuntu/Debian:

```bash
for profile in ubuntu22 debian12 debian13; do
    bash build.sh prepare "$profile" &&
    bash build.sh pagespeed "$profile" ./pagespeed-src &&
    JOBS=4 bash build.sh build "$profile" || break
done
```

Для РЕД ОС выберите образ той же версии и редакции, что у сервера, с доступом к соответствующим RPM-репозиториям на сборочной машине. Если у вас свой подготовленный образ, передайте его тег. Пример поиска стандартных образов:

```bash
docker search registry.red-soft.ru/ubi7
docker search registry.red-soft.ru/ubi8
```

Задайте `REDOS_IMAGE` фактическим тегом или digest выбранного образа для каждого профиля:

```bash
REDOS_IMAGE="$redos73_image" bash build.sh prepare redos73
JOBS=4 bash build.sh build redos73

REDOS_IMAGE="$redos8_image" bash build.sh prepare redos8
JOBS=4 bash build.sh build redos8
```

На РЕД ОС проверьте, что выбранные репозитории включают пакеты разработки и версии библиотек, требуемые PHP 8.5. Наиболее вероятные расхождения между редакциями — OpenSSL ≥ 1.1.1, libcurl ≥ 7.61.0 и пакеты `libzip-devel` и `oniguruma-devel`. Ошибка разрешения зависимостей или `configure` означает, что для этой редакции требуется уточнить репозиторий или профиль сборки. Используйте репозитории вашей редакции РЕД ОС. [Документация РЕД ОС 7.3](https://redos.red-soft.ru/base/redos-7_3/7_3-administation/7_3-containers/7_3-docker-install/) · [Документация РЕД ОС 8](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-containers/8_0-docker-install/) · [Требования PHP к OpenSSL](https://www.php.net/manual/en/openssl.requirements.php) · [Требования PHP к cURL](https://www.php.net/manual/en/curl.requirements.php).

## 2. Установка на целевом сервере

Перенесите архив нужного профиля и файл `.sha256` по доверенному каналу. Выполните в каталоге с обоими файлами. В примере Ubuntu 24.04:

```bash
archive=stack-php8.5.13-nginx1.30.7-ubuntu24-x86_64.tar.gz
sha256sum -c "$archive.sha256"
mkdir offline-stack
tar -xzf "$archive" -C offline-stack
cd offline-stack
bash deploy.sh verify
sudo bash deploy.sh stage
```

`stage` размещает сборки в `/opt/php-8.5.13` и `/opt/nginx-1.30.7`. Если нужные библиотеки уже стоят, можно сразу перейти к настройке конфигов. Для установки недостающих пакетов сначала проверьте транзакцию:

```bash
sudo bash deploy.sh deps --plan
sudo bash deploy.sh deps --install
```

`deps` использует локальный репозиторий из архива. На RPM-системах `dnf --assumeno` в режиме просмотра может завершиться с ненулевым кодом после показа транзакции. Установка зависимостей может затронуть общие системные библиотеки. Сверьте предложенные обновления и удаления с вашей процедурой обслуживания перед подтверждением. Откат служб восстанавливает их состояние и использует эти же установленные библиотеки.

### Отдельные конфиги

Скопируйте деревья конфигурации в новые каталоги. Для nginx:

```bash
sudo cp -an /etc/nginx/. /etc/opt/nginx-1.30.7/
```

Для Apache на Ubuntu/Debian:

```bash
sudo cp -an /etc/apache2/. /etc/opt/apache-php85/
sudo cp -n /etc/opt/apache-php85/apache2.conf /etc/opt/apache-php85/httpd.conf
```

Для Apache на РЕД ОС:

```bash
sudo cp -an /etc/httpd/. /etc/opt/apache-php85/
sudo cp -n /etc/opt/apache-php85/conf/httpd.conf /etc/opt/apache-php85/httpd.conf
```

Проверьте `ServerRoot`, абсолютные `Include` и ссылки. Они должны указывать на копию там, где новый конфиг выбирает модули и обработчики. Для RPM сохраните доступ к системному каталогу модулей Apache. Например, при относительном `LoadModule ... modules/...` проверьте ссылку `modules` в новой копии или используйте фактический абсолютный путь. Сохраните параметры виртуальных хостов, порты, сертификаты и права на каталоги, которые обслуживает сайт.

- В конфиге Apache оставьте один MPM `prefork`. Подключите `LoadModule php_module "/opt/php-8.5.13/lib/apache/libphp.so"` на месте старой загрузки PHP. Укажите `PHPIniDir "/opt/php-8.5.13/etc"` и сохраните правила обработки PHP текущего сайта. При переходе с FPM отключите в копии обработчик `proxy_fcgi` для PHP и задействуйте `SetHandler application/x-httpd-php` там, где сайт должен исполнять PHP. Сохраните ограничения исполнения в `upload` и других каталогах.
- В копии PHP перенесите настройки сайта в `/opt/php-8.5.13/etc/php.ini` и `conf.d/`, включая сокеты БД, сессии и почту. Расширения PHP из системных путей требуют проверки совместимости с ABI новой сборки. `pspell.so` уже загружается. Параметры `opcache.*` можно перенести, а строка `zend_extension=opcache.so` для PHP 8.5 лишняя. [Документация OPcache](https://www.php.net/opcache.installation).
- В копии nginx загрузите нужные `.so` из `/opt/nginx-1.30.7/modules` директивами `load_module` в главном контексте до `events`. Имена файлов покажет `ls /opt/nginx-1.30.7/modules/`. Уберите из копии подключения дублирующих системных модулей. Служба передаёт `daemon off;` сама. Проверьте уникальные PID и правильные пути журналов, кэша и временных файлов.
- При использовании PageSpeed укажите `pagespeed on;` в нужном контексте и `pagespeed FileCachePath /путь/к/кэшу;`. Дайте рабочему пользователю nginx права записи на этот каталог. Функции нативного модуля доступны без отдельного optimizer worker. [Документация нативного модуля](https://modpagespeed.com/docs/installation-module/).

### Проверка, переключение и откат

```bash
sudo bash deploy.sh units
sudo bash deploy.sh check
```

Создайте проверочный PHP-файл с таким содержимым и сделайте его доступным через новую связку nginx → Apache по HTTP на `127.0.0.1`. Используйте закрытый от внешнего доступа путь или отдельный локальный виртуальный хост.

```php
<?php
echo PHP_SAPI, " ", PHP_VERSION;
```

Укажите фактический URL и при необходимости `Host`. `switch` останавливает старые службы, запускает новые, проверяет ответ `apache2handler 8.5.13` и только после успеха включает автозапуск. При ошибке скрипт пытается восстановить прежние службы. Предусмотрите короткое окно обслуживания и сохраните проверенный архив на время эксплуатации.

```bash
sudo bash deploy.sh switch http://127.0.0.1:19085/runtime-check.php example.ru
systemctl status nginx-1.30.7.service apache-php85.service
```

После проверки удалите временный PHP-файл. Проверьте ротацию журналов и скрипты обслуживания, которые раньше вызывали reload по имени штатной службы.

Для возврата к ранее записанным активным службам и их автозапуску:

```bash
sudo bash deploy.sh rollback
```

