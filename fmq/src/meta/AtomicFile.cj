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
package fountain::fmq.meta

import std.fs.*

/**
 * 原子文件写入：`写临时文件 → fsync → rename → fsync(parent)`。
 *
 * 没有 fsync 时掉电可能留下「0 字节的正式文件」（rename 已生效、数据还在页缓存），
 * 元数据与位点都会因此丢条目。顺序通过 `trace` 钩子暴露给用例断言。
 *
 * 目录 fsync 依赖平台能力：不可用时只记 trace，不阻断写入（rename 的元数据由文件系统
 * 自身日志保证）。
 */
protected class AtomicFile {
    private let trace: (String) -> Unit

    protected init(trace!: (String) -> Unit = {_ => ()}) {
        this.trace = trace
    }

    protected func write(path: String, bytes: Array<Byte>): Unit {
        let parent = Path(path).parent
        if (!exists(parent)) {
            Directory.create(parent, recursive: true)
        }
        let tmp = "${path}.tmp"
        if (exists(tmp)) {
            remove(tmp)
        }
        this.trace("create")
        let file = File.create(tmp)
        try {
            this.trace("write")
            file.write(bytes)
            // `File.flush` 在标准库里就是 fsync：把数据刷到介质再 rename
            this.trace("fsync(file)")
            file.flush()
        } finally {
            this.trace("close")
            if (!file.isClosed()) {
                file.close()
            }
        }
        this.trace("rename")
        rename(tmp, to: path, overwrite: true)
        this.trace("fsync(parent)")
        syncDirectory(parent.toString())
    }

    /** 目录 fsync：尽力而为，不支持时静默跳过。 */
    private func syncDirectory(parent: String): Unit {
        try {
            let dir = File(parent, OpenMode.Read)
            try {
                dir.flush()
            } finally {
                if (!dir.isClosed()) {
                    dir.close()
                }
            }
        } catch (_: Exception) {}
    }
}
