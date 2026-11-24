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

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Symfony\Component\Process\Process;

class SchedulerLegacyWindowsGuidanceTest extends TestCase
{
    #[DataProvider('legacySurfaces')]
    public function testLegacyWindowsGuidanceUsesSuite8Console(string $surface): void
    {
        $render = <<<'PHP'
            define('sugarEntry', true);
            function is_windows() { return true; }
            class SugarBean {}
            class Basic {}
            class LoggerManager {
                static function getLogger() { return new self(); }
                function __call($name, $arguments) {}
            }
            class UploadStream {
                const STREAM_NAME = 'upload';
                static function getSuhosinStatus() { return true; }
            }
            function return_bytes($size) { return 0; }
            function get_sugar_config_defaults() { return []; }
            function get_language_header() { return 'lang="en"'; }
            function return_module_language($language, $module) {
                require 'modules/Schedulers/language/en_us.lang.php';
                return $mod_strings;
            }
            $current_language = 'en_us';
            if ($argv[1] === 'admin') {
                $mod_strings = return_module_language('en_us', 'Schedulers');
                require 'modules/Schedulers/Scheduler.php';
                (new ReflectionClass(Scheduler::class))->newInstanceWithoutConstructor()->displayCronInstructions();
            } else {
                $install_script = true;
                $mod_strings = new ArrayObject();
                $sugar_config = ['default_language' => 'en_us', 'cache_dir' => 'cache/', 'site_url' => '', 'translation_string_prefix' => ''];
                $sugar_md = '';
                $next_step = '';
                require 'install/ready.php';
            }
            PHP;
        $process = new Process(
            [PHP_BINARY, '-d', 'error_reporting=17', '-r', $render, '--', $surface],
            dirname(__DIR__, 4) . '/public/legacy'
        );
        $process->mustRun();

        $html = $process->getOutput();
        self::assertStringNotContainsString('cron.php', $html);
        self::assertStringContainsString('cd /d "[path\to\suite\instance]"', $html);
        self::assertStringContainsString('"[path\to\php.exe]" "bin\console" schedulers:run', $html);
        self::assertStringContainsString('cron.allowed_cron_users', $html);
        self::assertStringContainsString('docs/windows/scheduler.md', $html);
    }

    public static function legacySurfaces(): array
    {
        return [['admin'], ['installer']];
    }
}
