<?php
/**
 * SuiteCRM is a customer relationship management program developed by SuiteCRM Ltd.
 * Copyright (C) 2025 SuiteCRM Ltd.
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

namespace App\Tests\unit\core\legacy;

use PHPUnit\Framework\TestCase;
use Symfony\Component\Process\Process;

class SchedulerConsoleEntryPointTest extends TestCase
{
    public function testRelativeForwardSlashPathReachesSchedulerHelp(): void
    {
        $this->assertSchedulerHelp(['bin/console']);
    }

    public function testNativeWindowsPathsReachSchedulerHelp(): void
    {
        if (PHP_OS_FAMILY !== 'Windows') {
            self::markTestSkipped('This test requires native Windows PHP.');
        }

        $this->assertSchedulerHelp(['bin\console']);
        $this->assertSchedulerHelp([dirname(__DIR__, 4) . '\bin\console']);

        // Cover spaces even when the checkout itself has none.
        $this->assertSchedulerHelp([
            '-r',
            '$_SERVER["PHP_SELF"] = $argv[1]; $_SERVER["argv"] = array_slice($argv, 1); require "bin/console";',
            '--',
            'D:\CRM Site\bin\console',
        ]);
    }

    public function testLegacyRequestPathValidationRemainsStrict(): void
    {
        $validate = <<<'PHP'
            define('sugarEntry', true);
            chdir('public/legacy');
            require 'include/utils.php';
            $sugar_config = ['site_url' => '/'];
            $_SERVER['PHP_SELF'] = $argv[1];
            clean_special_arguments();
            echo $_SERVER['PHP_SELF'];
            PHP;

        $valid = '/suite/index.php';
        self::assertSame($valid, $this->runPhp(['-r', $validate, '--', $valid]));
        foreach (['bin\console', 'D:/Suite/bin/console', 'bin/CRM Site/console'] as $invalid) {
            self::assertStringContainsString('Bad data passed in', $this->runPhp(['-r', $validate, '--', $invalid]));
        }
    }

    private function assertSchedulerHelp(array $command): void
    {
        $output = $this->runPhp([...$command, 'schedulers:run', '--help', '--no-ansi']);
        self::assertStringNotContainsString('Bad data passed in', $output);
        self::assertStringContainsString('Run all Schedulers', $output);
        self::assertStringContainsString('schedulers:run', $output);
    }

    private function runPhp(array $command): string
    {
        $process = new Process([PHP_BINARY, ...$command], dirname(__DIR__, 4));
        $process->run();

        $output = $process->getOutput() . $process->getErrorOutput();
        self::assertSame(0, $process->getExitCode(), $output);

        return $output;
    }
}
