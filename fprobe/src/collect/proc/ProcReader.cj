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
package fountain::fprobe.collect.proc

import std.collection.{ArrayList, HashMap}
import std.fs.{Directory, File}
import fountain::f_probe.{ProbeErrorCode, ProbeException}

/**
 * `/proc`、`/sys` 等文件读取抽象。
 *
 * 探针只依赖接口，测试用 `FixtureProcReader` 注入内容，避免依赖真实内核状态。
 */
public interface ProcReader {
    /** 读取失败或文件不存在时返回 None。 */
    func read(path: String): ?String

    /** 列出目录项名称；返回 None 表示目录不存在或读取失败。 */
    func list(_: String): ?Array<String> {
        None<Array<String>>
    }
}

/** 内存 map 实现，供探针解析用例使用。 */
public class FixtureProcReader <: ProcReader {
    private let files = HashMap<String, String>()
    private let directories = HashMap<String, Array<String>>()

    public init(entries: Array<(String, String)>) {
        for ((path, content) in entries) {
            files[path] = content
        }
    }

    public init(entries: Array<(String, String)>, directories: Array<(String, Array<String>)>) {
        for ((path, content) in entries) {
            files[path] = content
        }
        for ((path, names) in directories) {
            this.directories[path] = names
        }
    }

    /** 用例模拟两帧采样时替换文件内容。 */
    public func set(path: String, content: String): Unit {
        files[path] = content
    }

    public func read(path: String): ?String {
        files.get(path)
    }

    public func list(path: String): ?Array<String> {
        directories.get(path)
    }
}

/** 生产实现：直接读取宿主文件系统。 */
public class RealProcReader <: ProcReader {
    public init() {}

    public func read(path: String): ?String {
        try {
            Some(String.fromUtf8(File.readFrom(path)))
        } catch (_: Exception) {
            None
        }
    }

    public func list(path: String): ?Array<String> {
        try {
            let entries = Directory.readFrom(path)
            let names = ArrayList<String>()
            for (entry in entries) {
                names.add(entry.path.fileName)
            }
            Some(names.toArray())
        } catch (_: Exception) {
            None
        }
    }
}

/** 非 Linux 平台实现：任何读取都明确报 unsupported。 */
public class UnsupportedProcReader <: ProcReader {
    public init() {}

    public func read(path: String): ?String {
        throw ProbeException(ProbeErrorCode.COLLECT, "proc reader unsupported on this platform: ${path}")
    }

    public func list(path: String): ?Array<String> {
        throw ProbeException(ProbeErrorCode.COLLECT, "proc reader unsupported on this platform: ${path}")
    }
}

/** 按编译目标选择读取器：Linux 用真实实现，其它平台统一降级。 */
@When[os == "Linux"]
public func createProcReader(): ProcReader {
    RealProcReader()
}

@When[os != "Linux"]
public func createProcReader(): ProcReader {
    UnsupportedProcReader()
}
