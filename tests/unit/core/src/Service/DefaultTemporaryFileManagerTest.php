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
 * You should have received a copy of the GNU Affero General Public License along with
 * this program; if not, see <http://www.gnu.org/licenses/>.
 *
 * In accordance with Section 7(b) of the GNU Affero General Public License version 3,
 * these Appropriate Legal Notices must retain the display of the "Supercharged by SuiteCRM"
 * logo. If the display of the logos is not reasonably feasible for technical reasons,
 * the Appropriate Legal Notices must display the words "Supercharged by SuiteCRM".
 */

namespace App\Tests\unit\core\src\Service;

use App\MediaObjects\Service\TemporaryFile\DefaultTemporaryFileManager;
use PHPUnit\Framework\TestCase;
use Psr\Log\NullLogger;

class DefaultTemporaryFileManagerTest extends TestCase
{
    /** @dataProvider baseDirectories */
    public function testResolvesWorkingFilePath(string $base, string $project, string $expectedBase): void
    {
        $manager = new class ($base, $project, new NullLogger()) extends DefaultTemporaryFileManager {
            protected function ensureDirectoryExists(string $dir): void
            {
                // Exercise path resolution without accessing drive roots or UNC shares.
            }
        };

        self::assertSame(
            implode(DIRECTORY_SEPARATOR, [$expectedBase, 'imports', 'batch', 'records.csv']),
            $manager->getWorkingFilePath('imports', 'records.csv', 'batch')
        );
    }

    public static function baseDirectories(): array
    {
        if (DIRECTORY_SEPARATOR === '\\') {
            $project = 'C:\\SuiteCRM';

            return [
                'default' => [' ', $project, 'C:\\SuiteCRM\\tmp'],
                'relative' => ['storage\\tmp', $project, 'C:\\SuiteCRM\\storage\\tmp'],
                'drive absolute' => ['D:\\CRM Data\\tmp', $project, 'D:\\CRM Data\\tmp'],
                'forward slashes on drive' => ['d:/CRM Data/tmp/', $project, 'd:/CRM Data/tmp'],
                'drive root' => ['D:\\', $project, 'D:'],
                'drive root forward' => ['D:/', $project, 'D:'],
                'UNC' => ['\\\\server\\share\\tmp', $project, '\\\\server\\share\\tmp'],
                'forward slash UNC' => ['//server/share/tmp', $project, '//server/share/tmp'],
                'root-relative' => ['\\temp', $project, '\\temp'],
                'forward slash root-relative' => ['/temp', $project, '/temp'],
            ];
        }

        $project = '/suitecrm';

        return [
            'default' => [' ', $project, '/suitecrm/tmp'],
            'relative' => ['storage/tmp', $project, '/suitecrm/storage/tmp'],
            'absolute' => ['/var/tmp/suitecrm/', $project, '/var/tmp/suitecrm'],
            'POSIX filename with colon' => ['D:/tmp', $project, '/suitecrm/D:/tmp'],
            'POSIX filename with backslash' => ['\\temp', $project, '/suitecrm/\\temp'],
        ];
    }

    public function testStreamsAndCleansUpInNativeAbsoluteDirectory(): void
    {
        $base = rtrim(sys_get_temp_dir(), DIRECTORY_SEPARATOR) . DIRECTORY_SEPARATOR . 'suitecrm - ' . bin2hex(random_bytes(8));
        $context = 'imports';
        $file = 'records.csv';
        $workingPath = $base . DIRECTORY_SEPARATOR . $context . DIRECTORY_SEPARATOR . $file;
        $manager = new DefaultTemporaryFileManager($base, __DIR__, new NullLogger());

        try {
            self::assertSame($workingPath, $manager->getWorkingFilePath($context, $file));
            $stream = $manager->openStream($context, $file);
            try {
                self::assertSame(3, fwrite($stream, 'crm'));
            } finally {
                fclose($stream);
            }
            self::assertSame('crm', file_get_contents($workingPath));
            self::assertTrue($manager->exists($context, $file));

            self::assertTrue(touch($workingPath, time() - 120));
            clearstatcache(true, $workingPath);
            self::assertSame(1, $manager->cleanupExpired(60));
            self::assertFalse($manager->exists($context, $file));

            fclose($manager->openStream($context, $file));
            $manager->cleanup($context);
            self::assertDirectoryDoesNotExist(dirname($workingPath));
        } finally {
            $manager->cleanup($context);
            if (is_dir($base)) {
                rmdir($base);
            }
        }
    }
}
