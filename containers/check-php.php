<?php

$required = [
    'bcmath', 'bz2', 'calendar', 'ctype', 'curl', 'dom', 'exif', 'fileinfo',
    'filter', 'gd', 'gettext', 'gmp', 'iconv', 'intl', 'ldap', 'mbstring',
    'mysqli', 'mysqlnd', 'openssl', 'PDO', 'pdo_mysql', 'pdo_pgsql',
    'pdo_sqlite', 'pgsql', 'Phar', 'posix', 'pspell', 'shmop', 'SimpleXML',
    'sockets', 'sodium', 'sqlite3', 'sysvmsg', 'sysvsem', 'sysvshm',
    'xml', 'xmlreader', 'xmlwriter', 'xsl', 'Zend OPcache', 'zip', 'zlib',
];

if (PHP_SAPI === 'cli') {
    array_push($required, 'pcntl', 'readline');
}

$missing = array_filter($required, static fn (string $name): bool => !extension_loaded($name));
if (extension_loaded('gd')) {
    foreach (['FreeType Support', 'JPEG Support', 'WebP Support'] as $feature) {
        if (empty(gd_info()[$feature])) {
            $missing[] = "GD $feature";
        }
    }
}

if ($missing || !function_exists('mysqli_report')) {
    http_response_code(500);
    echo 'Missing PHP features: ', implode(', ', $missing), "\n";
    exit(1);
}

echo PHP_SAPI, ' ', PHP_VERSION, "\n";
