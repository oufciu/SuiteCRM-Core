<?php
/**
 * SuiteCRM is a customer relationship management program developed by SuiteCRM Ltd.
 * Copyright (C) 2026 SuiteCRM Ltd.
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU Affero General Public License version 3 as published by the
 * Free Software Foundation with the addition of the following permission added
 * to Section 15 as permitted in Section 7(a): FOR ANY PART OF THE COVERED WORK
 * IN WHICH THE COPYRIGHT IS OWNED BY SUITECRM, SUITECRM DISCLAIMS THE
 * WARRANTY OF NON INFRINGEMENT OF THIRD PARTY RIGHTS.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * In accordance with Section 7(b) of the GNU Affero General Public License
 * version 3, these Appropriate Legal Notices must retain the display of the
 * "Supercharged by SuiteCRM" logo. If the display of the logos is not reasonably
 * feasible for technical reasons, the Appropriate Legal Notices must display
 * the words "Supercharged by SuiteCRM".
 */

namespace App\Tests\unit\core\src\Cache;

use App\Engine\Cache\CacheAdapterSelector;
use PHPUnit\Framework\TestCase;
use Symfony\Bundle\FrameworkBundle\DependencyInjection\FrameworkExtension;
use Symfony\Component\Cache\Adapter\AdapterInterface;
use Symfony\Component\Cache\Adapter\FilesystemAdapter;
use Symfony\Component\Cache\Adapter\PhpFilesAdapter;
use Symfony\Component\Config\FileLocator;
use Symfony\Component\DependencyInjection\ContainerBuilder;
use Symfony\Component\DependencyInjection\Loader\PhpFileLoader;

/**
 * Concurrent cold-cache requests on Windows read cache entries that another request
 * is still writing, because Symfony writes them with copy() there instead of rename().
 */
class CacheAdapterSelectorTest extends TestCase
{
    private const KEY = 'isWritable.a:3:{i:0;s:4:"Call";i:1;s:4:"name";i:2;a:0:{}}';

    private string $directory;

    protected function setUp(): void
    {
        $this->directory = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'scrm-cache-test-' . bin2hex(random_bytes(6));
        mkdir($this->directory);
    }

    protected function tearDown(): void
    {
        $this->removeDirectory($this->directory);
    }

    public function testWindowsUsesFilesystemAdapter(): void
    {
        self::assertSame('cache.adapter.filesystem', CacheAdapterSelector::forOsFamily('Windows'));
    }

    public function testOtherPlatformsKeepSystemAdapter(): void
    {
        foreach (['Linux', 'Darwin', 'BSD', 'Solaris', 'Unknown'] as $family) {
            self::assertSame('cache.adapter.system', CacheAdapterSelector::forOsFamily($family), $family);
        }
    }

    public function testCacheConfigurationAppliesSelectorToAppAndSystemPools(): void
    {
        $container = new ContainerBuilder();
        $container->registerExtension(new FrameworkExtension());
        $loader = new PhpFileLoader($container, new FileLocator(dirname(__DIR__, 5) . '/config/packages'));
        $loader->load('cache.php');

        $expected = CacheAdapterSelector::forOsFamily(PHP_OS_FAMILY);
        $cache = array_merge(...array_column($container->getExtensionConfig('framework'), 'cache'));
        self::assertSame(['app' => $expected, 'system' => $expected], $cache);
    }

    public function testWindowsAdapterReadsIncompleteEntriesAsMisses(): void
    {
        $value = ['name', 'id', 'date_entered'];
        $file = $this->saveAndLocate(new FilesystemAdapter('ns', 0, $this->directory), $value);
        $complete = file_get_contents($file);
        $lines = explode("\n", $complete, 3);

        $torn = [
            'empty' => '',
            'expiry only' => $lines[0] . "\n",
            'key without payload' => $lines[0] . "\n" . $lines[1] . "\n",
            'truncated payload' => substr($complete, 0, -5),
        ];
        foreach ($torn as $state => $content) {
            file_put_contents($file, $content);
            // The marshaller reports a truncated payload as a PHP warning before treating it as a miss.
            set_error_handler(static fn (int $type): bool => $type === E_WARNING || $type === E_NOTICE);
            try {
                $item = (new FilesystemAdapter('ns', 0, $this->directory))->getItem(self::KEY);
            } finally {
                restore_error_handler();
            }
            self::assertFalse($item->isHit(), $state);
            self::assertNull($item->get(), $state);
        }

        file_put_contents($file, $complete);
        $item = (new FilesystemAdapter('ns', 0, $this->directory))->getItem(self::KEY);
        self::assertTrue($item->isHit());
        self::assertSame($value, $item->get());
    }

    /**
     * Reproduces the Windows failure deterministically: the first include sees an
     * entry that is still empty, the follow-up include sees the finished entry.
     */
    public function testDefaultSystemAdapterReturnsInternalTupleOnTornRead(): void
    {
        if (filter_var(ini_get('opcache.enable_cli'), FILTER_VALIDATE_BOOL) && function_exists('opcache_get_status')) {
            self::markTestSkipped('The torn-read simulation rewrites a PHP file between two includes in one request.');
        }

        $file = $this->saveAndLocate(new PhpFilesAdapter('ns', 0, $this->directory, true), true);
        $complete = file_get_contents($file);
        file_put_contents($file, '<?php file_put_contents(__FILE__, ' . var_export($complete, true) . '); return 1;');

        $item = (new PhpFilesAdapter('ns', 0, $this->directory, true))->getItem(self::KEY);

        self::assertSame(
            [PHP_INT_MAX, true],
            $item->get(),
            'PhpFilesAdapter no longer leaks [expiry, value] after a torn read. '
            . 'If this holds on Windows too, the Windows-only filesystem adapter override can be reconsidered.'
        );
    }

    private function saveAndLocate(AdapterInterface $adapter, mixed $value): string
    {
        $item = $adapter->getItem(self::KEY);
        $item->set($value);
        self::assertTrue($adapter->save($item));

        $files = [];
        $iterator = new \RecursiveIteratorIterator(new \RecursiveDirectoryIterator($this->directory, \FilesystemIterator::SKIP_DOTS));
        foreach ($iterator as $entry) {
            if ($entry->isFile()) {
                $files[] = $entry->getPathname();
            }
        }
        self::assertCount(1, $files);

        return $files[0];
    }

    private function removeDirectory(string $directory): void
    {
        if (!is_dir($directory)) {
            return;
        }
        $iterator = new \RecursiveIteratorIterator(
            new \RecursiveDirectoryIterator($directory, \FilesystemIterator::SKIP_DOTS),
            \RecursiveIteratorIterator::CHILD_FIRST
        );
        foreach ($iterator as $entry) {
            $entry->isDir() ? rmdir($entry->getPathname()) : unlink($entry->getPathname());
        }
        rmdir($directory);
    }
}
