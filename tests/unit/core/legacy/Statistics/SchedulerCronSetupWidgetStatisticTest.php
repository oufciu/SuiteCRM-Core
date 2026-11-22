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

namespace App\Tests\unit\core\legacy\Statistics;

use App\Schedulers\Statistics\SchedulerCronSetupWidgetStatistic;
use PHPUnit\Framework\TestCase;
use ReflectionMethod;

class SchedulerCronSetupWidgetStatisticTest extends TestCase
{
    public function testWindowsCommandPromptInstructions(): void
    {
        $statistic = $this->widget();
        $method = new ReflectionMethod($statistic, 'getWindowsCronInfo');
        $fields = $method->invoke($statistic)['fields'];

        self::assertSame('Windows', $fields['type']['value']);
        $paths = [
            '[path\to\php.exe]' => 'C:\PHP Tools\php.exe',
            '[path\to\suite\instance]' => 'D:\CRM Site',
        ];
        self::assertSame(
            ['cd /d "D:\CRM Site"', '"C:\PHP Tools\php.exe" "D:\CRM Site\bin\console" schedulers:run'],
            [strtr($fields['desc3']['value'], $paths), strtr($fields['desc4']['value'], $paths)]
        );
    }

    public function testUnixCronInstructionsRemainUnchanged(): void
    {
        $method = new ReflectionMethod(SchedulerCronSetupWidgetStatistic::class, 'getUnixCronInfo');
        $fields = $method->invoke($this->widget(), 'www-data')['fields'];

        self::assertSame('Unix', $fields['type']['value']);
        self::assertSame('sudo crontab -e -u www-data', $fields['desc3']['value']);
        self::assertSame(
            '* * * * *; [path/to/php] [path/to/suite/instance]/bin/console schedulers:run > /dev/null 2>&1',
            $fields['desc5']['value']
        );
        self::assertSame(
            '* * * * *; [path/to/php] [path/to/suite/instance]/bin/console -e [env] schedulers:run > /dev/null 2>&1',
            $fields['desc7']['value']
        );
    }

    public function testWidgetUsesTheOperatingSystemGuidance(): void
    {
        $statistic = $this->widget()->getData([]);
        self::assertSame(SchedulerCronSetupWidgetStatistic::KEY, $statistic->getId());

        $fields = $statistic->getData()['fields'];
        $windows = PHP_OS_FAMILY === 'Windows';
        self::assertSame($windows ? 'Windows' : 'Unix', $fields['type']['value']);
        self::assertSame(
            $windows ? 'cd /d "[path\to\suite\instance]"' : 'sudo crontab -e -u www-data',
            $fields['desc3']['value']
        );
    }

    private function widget(): SchedulerCronSetupWidgetStatistic
    {
        $widget = $this->getMockBuilder(SchedulerCronSetupWidgetStatistic::class)
            ->disableOriginalConstructor()
            ->onlyMethods(['getRunningUser'])
            ->getMock();
        $widget->method('getRunningUser')->willReturn('www-data');

        return $widget;
    }
}
