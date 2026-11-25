<?php
// Keep the Redis extension available without probing an unconfigured server on every request.
$directory = $argv[1] ?? '';
$config = $directory . '/config.php';
$override = $directory . '/config_override.php';
try {
    if (!is_file($config)) {
        echo "uninstalled\n";
        exit(0);
    }
    $sugar_config = [];
    ob_start();
    try {
        require $config;
        if (is_file($override)) {
            require $override;
        }
    } finally {
        ob_end_clean();
    }
    if (array_key_exists('external_cache_disabled_redis', $sugar_config)) {
        echo "operator-value-preserved\n";
        exit(0);
    }
    if (!empty($sugar_config['external_cache']['redis'])) {
        echo "configured-redis-preserved\n";
        exit(0);
    }
    $existing = is_file($override) ? file_get_contents($override) : '';
    if ($existing === false) {
        throw new RuntimeException('Cannot read override.');
    }
    $insidePhp = false;
    foreach (token_get_all($existing) as $token) {
        if (is_array($token) && $token[0] === T_OPEN_TAG) {
            $insidePhp = true;
        } elseif (is_array($token) && $token[0] === T_CLOSE_TAG) {
            $insidePhp = false;
        }
    }
    $guard = <<<'PHP'
// Windows packaging default; explicit operator values or Redis server configuration win.
if (!array_key_exists('external_cache_disabled_redis', $sugar_config)
    && empty($sugar_config['external_cache']['redis'])) {
    $sugar_config['external_cache_disabled_redis'] = true;
}
PHP;
    $suffix = ($insidePhp ? "\n" : "<?php\n") . $guard . "\n";
    if (file_put_contents($override, $suffix, FILE_APPEND | LOCK_EX) !== strlen($suffix)) {
        throw new RuntimeException('Cannot write override.');
    }
    echo "unconfigured-redis-disabled\n";
} catch (Throwable $error) {
    // Operator config may contain secrets, so do not echo exception text or content.
    fwrite(STDERR, "Legacy cache configuration failed.\n");
    exit(1);
}
