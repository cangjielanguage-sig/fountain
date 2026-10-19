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

import std.collection.{ArrayList, HashMap}
import std.fs.*
import std.reflect.PackageInfo
import std.unicode.UnicodeStringExtension
import fountain::f_app.InitializerCollection
import fountain::f_dbm.{IdGenerator, PartitionAlgorithm}
import fountain::f_log.LoggerFactory
import fountain::f_dbd.common.DbdErrorCode
import fountain::fdbm.exception.FdbmException

/** 自定义扩展集合（设计 §10.5）：启动校验要用名字集合，执行期要用实例。 */
protected class CustomExtensions {
    public let partitions: HashMap<String, PartitionAlgorithm>
    public let idGenerators: HashMap<String, IdGenerator>

    public init(partitions!: HashMap<String, PartitionAlgorithm> = HashMap<String, PartitionAlgorithm>(),
        idGenerators!: HashMap<String, IdGenerator> = HashMap<String, IdGenerator>()) {
        this.partitions = partitions
        this.idGenerators = idGenerators
    }

    public func partitionNames(): Array<String> {
        namesOf<PartitionAlgorithm>(partitions)
    }

    public func idGeneratorNames(): Array<String> {
        namesOf<IdGenerator>(idGenerators)
    }

    private static func namesOf<T>(values: HashMap<String, T>): Array<String> {
        let names = ArrayList<String>()
        for ((name, _) in values) {
            names.add(name)
        }
        names.toArray()
    }
}

/**
 * `custom/` 目录加载（设计 §10.5）：
 * ① 先**全部** `PackageInfo.load`（保证各包 `static init` 的注册都完成）；
 * ② 再调用一次 `InitializerCollection.initialize()`；
 * ③ 两轮模式匹配收集 `PartitionAlgorithm` / `IdGenerator`。
 *
 * 目录不存在 = 空扩展；任一库加载或任一 `initialize()` 失败 = `CONFIG` 启动失败；
 * 自定义之间重名拒绝（与内置重名由 `FdbmConfig.validate` 拒绝）。
 */
protected struct CustomLoader {
    private static let logger = LoggerFactory.getLogger('fountain::fdbm.server.CustomLoader')

    public static func load(customDir: String): CustomExtensions {
        let partitions = HashMap<String, PartitionAlgorithm>()
        let idGenerators = HashMap<String, IdGenerator>()
        let libraries = librariesOf(customDir)
        if (libraries.isEmpty()) {
            logger.info('no custom extension in \'${customDir}\'')
            return CustomExtensions(partitions: partitions, idGenerators: idGenerators)
        }
        for (path in libraries) {
            try {
                PackageInfo.load(withoutExtension(path))
            } catch (e: Exception) {
                throw FdbmException(DbdErrorCode.CONFIG,
                    'failed to load custom extension \'${path}\': ${e.message}', e)
            }
        }
        let providers = try {
            InitializerCollection.initialize()
        } catch (e: FdbmException) {
            throw e
        } catch (e: Exception) {
            throw FdbmException(DbdErrorCode.CONFIG,
                'custom extension initialization failed: ${e.message}', e)
        }
        for (provider in providers) {
            let instance = provider()
            match (instance) {
                case algorithm: PartitionAlgorithm =>
                    let name = algorithm.name
                    if (partitions.get(name).isSome()) {
                        throw FdbmException(DbdErrorCode.PARTITION_CONFIG,
                            'duplicated custom partition algorithm \'${name}\'')
                    }
                    partitions[name] = algorithm
                case _ => ()
            }
            match (instance) {
                case generator: IdGenerator =>
                    let name = generator.name
                    if (idGenerators.get(name).isSome()) {
                        throw FdbmException(DbdErrorCode.CONFIG,
                            'duplicated custom id generator \'${name}\'')
                    }
                    idGenerators[name] = generator
                case _ => ()
            }
        }
        logger.info('loaded ${partitions.size} custom partition algorithm(s) and ' +
            '${idGenerators.size} custom id generator(s) from \'${customDir}\'')
        CustomExtensions(partitions: partitions, idGenerators: idGenerators)
    }

    static func librariesOf(customDir: String): Array<String> {
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
