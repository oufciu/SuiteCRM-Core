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

namespace App\Engine\Cache;

/**
 * Chooses the adapter behind the framework "app" and "system" cache pools.
 *
 * On Windows, Symfony's filesystem cache writes entries with copy() instead of an
 * atomic rename(), so a concurrent reader can open an entry while it is still
 * empty. The default system adapter (PhpFilesAdapter in append-only mode) then
 * re-includes the finished file as a lazy value and returns its internal
 * [expiry, value] tuple as the cached value, which surfaces as TypeErrors such as
 * "PropertyInfoCacheExtractor::isWritable(): Return value must be of type ?bool,
 * array returned". FilesystemAdapter checks the stored key and unserializes the
 * payload, so an incomplete entry is read as a cache miss instead.
 */
final class CacheAdapterSelector
{
    public const DEFAULT_ADAPTER = 'cache.adapter.system';
    public const WINDOWS_ADAPTER = 'cache.adapter.filesystem';

    public static function forOsFamily(string $osFamily): string
    {
        return $osFamily === 'Windows' ? self::WINDOWS_ADAPTER : self::DEFAULT_ADAPTER;
    }
}
