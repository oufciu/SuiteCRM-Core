# Legacy Redis cache timeouts

Redis cache autodetection must not block every application request indefinitely
when the extension is installed but its server is unavailable. The legacy
`SugarCacheRedis` adapter uses a 0.1-second connect timeout and a 1-second read
timeout. Set positive values in seconds in `public/legacy/config_override.php`
when a configured server needs different limits:

```php
$sugar_config['external_cache']['redis']['connect_timeout'] = 0.25;
$sugar_config['external_cache']['redis']['read_timeout'] = 1.0;
```

Zero, negative and non-finite values fall back to the bounded defaults, because
zero means unlimited in phpredis. Failed connections are not retained as though
connected. These limits apply on all platforms and before authentication or
database selection. They do not install a Redis server, change cache keys or
disable the extension.

On Windows, a closed localhost port can incur a TCP retry for both IPv6 and
IPv4, rather than an immediate refusal. An unbounded localhost:6379 probe took
4.13 seconds on the native validation host. Prefer an explicit server address
and disable legacy Redis cache autodetection if the extension is needed for
other functionality but no cache server is configured:

```php
$sugar_config['external_cache_disabled_redis'] = true;
```
