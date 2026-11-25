<?php

namespace App\Tests\unit\core\src\Cache;

use PHPUnit\Framework\TestCase;

class LegacyRedisTimeoutTest extends TestCase
{
    private string $includePath;
    private mixed $originalConfig;

    protected function setUp(): void
    {
        if (!extension_loaded('redis')) {
            self::markTestSkipped('The pinned Redis extension is required.');
        }
        if (!defined('sugarEntry')) {
            define('sugarEntry', true);
        }
        $legacy = dirname(__DIR__, 5) . '/public/legacy';
        $this->includePath = get_include_path();
        set_include_path($legacy . PATH_SEPARATOR . $this->includePath);
        require_once $legacy . '/include/utils/array_utils.php';
        require_once $legacy . '/include/SugarObjects/SugarConfig.php';
        require_once $legacy . '/include/SugarCache/SugarCacheRedis.php';
        $this->originalConfig = $GLOBALS['sugar_config'] ?? null;
        $GLOBALS['sugar_config'] = [];
        \SugarConfig::getInstance()->clearCache();
    }

    protected function tearDown(): void
    {
        if (isset($this->includePath)) {
            set_include_path($this->includePath);
            $GLOBALS['sugar_config'] = $this->originalConfig;
            \SugarConfig::getInstance()->clearCache();
        }
    }

    private function cache(\Redis $client): \SugarCacheRedis
    {
        return new class($client) extends \SugarCacheRedis {
            public function __construct(private \Redis $client) { parent::__construct(); }
            protected function createRedisClient() { return $this->client; }
            public function connectForTest() { return $this->_getRedisObject(); }
        };
    }

    public function testMissingServerUsesBoundedConnectAndReadTimeouts(): void
    {
        $client = $this->createMock(\Redis::class);
        $client->expects(self::once())->method('connect')
            ->with('localhost', 6379, 0.1, null, 0, 1.0)->willReturn(false);
        self::assertFalse($this->cache($client)->connectForTest());
    }

    public function testConfiguredTimeoutsApplyBeforeAuthenticationAndDatabaseSelection(): void
    {
        $GLOBALS['sugar_config']['external_cache']['redis'] = [
            'host' => '127.0.0.1', 'port' => 6380, 'password' => 'synthetic-test',
            'database' => 2, 'connect_timeout' => 0.25, 'read_timeout' => 0.5,
        ];
        $client = $this->createMock(\Redis::class);
        $client->expects(self::once())->method('connect')
            ->with('127.0.0.1', 6380, 0.25, null, 0, 0.5)->willReturn(true);
        $client->expects(self::once())->method('auth')->with('synthetic-test')->willReturn(true);
        $client->expects(self::once())->method('select')->with(2)->willReturn(true);
        $cache = $this->cache($client);
        self::assertSame($client, $cache->connectForTest());
        self::assertSame($client, $cache->connectForTest());
    }

    public function testUnlimitedAndNegativeSettingsFallBackToBoundedDefaults(): void
    {
        $GLOBALS['sugar_config']['external_cache']['redis'] = ['connect_timeout' => 0, 'read_timeout' => -1];
        $client = $this->createMock(\Redis::class);
        $client->expects(self::once())->method('connect')
            ->with('localhost', 6379, 0.1, null, 0, 1.0)->willReturn(false);
        self::assertFalse($this->cache($client)->connectForTest());
    }

    public function testFailedConnectionIsNotReusedAsAConnectedClient(): void
    {
        $client = $this->createMock(\Redis::class);
        $client->expects(self::exactly(2))->method('connect')->willReturn(false);
        $cache = $this->cache($client);
        self::assertFalse($cache->connectForTest());
        self::assertFalse($cache->connectForTest());
    }

    public function testConnectionExceptionDoesNotLeaveAConnectedClient(): void
    {
        $client = $this->createMock(\Redis::class);
        $client->expects(self::exactly(2))->method('connect')->willThrowException(new \RedisException('Synthetic refusal'));
        $cache = $this->cache($client);
        self::assertFalse($cache->connectForTest());
        self::assertFalse($cache->connectForTest());
    }
}
