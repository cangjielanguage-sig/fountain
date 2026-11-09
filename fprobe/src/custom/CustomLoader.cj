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
package fountain::fprobe.custom

import std.collection.ArrayList
import std.fs.*
import std.reflect.PackageInfo
import std.unicode.UnicodeStringExtension
import fountain::f_probe.{ProbeErrorCode, ProbeException}

/** 单个扩展库的加载失败。 */
public class CustomLoadFailure {
    public let library: String
    public let message: String

    public init(library: String, message: String) {
        this.library = library
        this.message = message
    }
}

/** 一次目录加载的结果：成功的库与失败明细，供启动日志与用例断言。 */
public class CustomLoadReport {
    public let loaded: Array<String>
    public let failures: Array<CustomLoadFailure>

    public init(loaded: Array<String>, failures: Array<CustomLoadFailure>) {
        this.loaded = loaded
        this.failures = failures
    }
}

/**
 * `custom/` 目录加载（设计 D14）。
 *
 * 扩展在包初始化期自行调用 `ProbeRegistry.registerAgent` /
 * `AlarmChannelRegistry.registerChannel`，因此加载器只负责按排序逐个
 * `PackageInfo.load`；注册重名由注册表抛 `DUPLICATE`。
 *
 * `failFast=true` 时任一加载/注册失败都收敛为 `LOAD` 终止启动；`false` 时
 * 记录 ERROR 并继续加载后续库，内置实现保持优先。
 */
public struct CustomLoader {
    /** 生产入口：真实加载动态库，错误写到 stderr。 */
    public static func load(dir: String, failFast: Bool): CustomLoadReport {
        loadWith(dir, failFast, {path => PackageInfo.load(path)}, {message => eprintln(message)})
    }

    /** 可注入入口：`loader` 让用例在不加载真实 `.so` 的前提下驱动失败路径。 */
    public static func loadWith(dir: String, failFast: Bool, loader: (String) -> Unit,
        onError: (String) -> Unit): CustomLoadReport {
        let libraries = librariesOf(dir)
        let loaded = ArrayList<String>()
        let failures = ArrayList<CustomLoadFailure>()
        for (path in libraries) {
            try {
                loader(withoutExtension(path))
                loaded.add(path)
            } catch (e: Exception) {
                let message = 'failed to load custom extension ${path}: ${e.message}'
                if (failFast) {
                    throw ProbeException(ProbeErrorCode.LOAD, message, e)
                }
                onError('ERROR ${message}')
                failures.add(CustomLoadFailure(path, e.message))
            } catch (e: Error) {
                let message = 'failed to load custom extension ${path}: ${e.message}'
                if (failFast) {
                    throw ProbeException(ProbeErrorCode.LOAD, message)
                }
                onError('ERROR ${message}')
                failures.add(CustomLoadFailure(path, e.message))
            }
        }
        CustomLoadReport(loaded.toArray(), failures.toArray())
    }

    /** 收集目录下的动态库，按完整路径排序；目录不存在 = 无扩展。 */
    public static func librariesOf(customDir: String): Array<String> {
        let path = Path(customDir)
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
        let lower = path.toLower()
        for (ext in ['.so', '.dll', '.dylib']) {
            if (lower.endsWith(ext)) {
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
