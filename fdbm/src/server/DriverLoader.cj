/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package fountain::fdbm.server

import std.collection.{ArrayList, HashSet}
import std.database.sql.{Driver, DriverManager}
import std.fs.*
import std.reflect.PackageInfo
import std.unicode.UnicodeStringExtension
import fountain::f_log.LoggerFactory
import fountain::f_dbd.common.DbdErrorCode
import fountain::fdbm.exception.FdbmException

/**
 * 物理驱动加载（设计 §10.5）：`driver/` 下**有且只有一个**物理驱动。
 *
 * 校验三件事：目录里恰好一个动态库、加载后 `DriverManager` 恰好一个驱动、驱动名与节点配置一致。
 * 任一不满足 → `NO_DRIVER`（启动失败，不监听端口）。
 */
protected struct DriverLoader {
    private static let logger = LoggerFactory.getLogger('fountain::fdbm.server.DriverLoader')

    public static func load(driverDir: String, expectedName: String): Driver {
        let libraries = librariesOf(driverDir)
        if (libraries.isEmpty()) {
            throw FdbmException(DbdErrorCode.NO_DRIVER,
                'driver directory \'${driverDir}\' contains no database driver')
        }
        if (libraries.size > 1) {
            throw FdbmException(DbdErrorCode.NO_DRIVER,
                'driver directory \'${driverDir}\' contains ${libraries.size} drivers; exactly one is required')
        }
        let path = libraries[0]
        try {
            PackageInfo.load(withoutExtension(path))
        } catch (e: Exception) {
            throw FdbmException(DbdErrorCode.CONFIG,
                'failed to load database driver \'${path}\': ${e.message}', e)
        }
        // 真实驱动常注册多个别名（postgres / postgresql / pg）；只要别名指向同一个驱动实例即可。
        let names = DriverManager.drivers()
        let distinct = HashSet<String>()
        let registered = ArrayList<String>()
        for (name in names) {
            match (DriverManager.getDriver(name)) {
                case Some(value) =>
                    distinct.add(value.name)
                    registered.add(name)
                case None => ()
            }
        }
        if (distinct.size != 1) {
            throw FdbmException(DbdErrorCode.NO_DRIVER,
                'expected exactly one registered driver after loading \'${path}\', got ' +
                '${distinct.size}: [${joinNames(registered)}]')
        }
        if (!names.contains(expectedName)) {
            throw FdbmException(DbdErrorCode.NO_DRIVER,
                'driver \'${expectedName}\' is not registered after loading \'${path}\'; ' +
                'available: [${joinNames(registered)}]')
        }
        let driver = match (DriverManager.getDriver(expectedName)) {
            case Some(value) => value
            case None => throw FdbmException(DbdErrorCode.NO_DRIVER,
                'driver \'${expectedName}\' disappeared after loading \'${path}\'')
        }
        logger.info('loaded database driver \'${driver.name}\' from ${path}')
        driver
    }

    private static func joinNames(values: ArrayList<String>): String {
        let text = StringBuilder()
        for (value in values) {
            if (text.size > 0) {
                text.append(', ')
            }
            text.append(value)
        }
        text.toString()
    }

    /** 目录里按文件名排序的动态库；目录不存在 → 空（由调用方报 `NO_DRIVER`）。 */
    static func librariesOf(driverDir: String): Array<String> {
        let path = Path(driverDir)
        if (!exists(path) || !FileInfo(path).isDirectory()) {
            return Array<String>()
        }
        let found = ArrayList<String>()
        Directory.walk(path) {info =>
            if (!info.isDirectory() && isLibrary(info.path.fileName)) {
                found.add(info.path.toString())
            }
            true
        }
        let libraries = found.toArray()
        sort(libraries)
        libraries
    }

    private static func isLibrary(name: String): Bool {
        let lower = name.toLower()
        lower.endsWith('.so') || lower.endsWith('.dll') || lower.endsWith('.dylib')
    }

    private static func withoutExtension(path: String): String {
        for (ext in ['.so', '.dll', '.dylib']) {
            if (path.endsWith(ext)) {
                return path[0..path.size - ext.size]
            }
        }
        path
    }

    private static func sort(values: Array<String>): Unit {
        var i: Int64 = 1
        while (i < values.size) {
            let current = values[i]
            var j = i - 1
            while (j >= 0 && values[j] > current) {
                values[j + 1] = values[j]
                j -= 1
            }
            values[j + 1] = current
            i += 1
        }
    }
}
