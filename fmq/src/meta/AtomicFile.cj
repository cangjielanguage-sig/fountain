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
import fountain::f_log.*

/**
 * 原子文件写入：`写临时文件 → fsync → rename → fsync(parent)`。
 *
 * 没有 fsync 时掉电可能留下「0 字节的正式文件」（rename 已生效、数据还在页缓存），
 * 元数据与位点都会因此丢条目。顺序通过 `trace` 钩子暴露给用例断言。
 *
 * 目录 fsync 依赖平台能力：不支持时只记 DEBUG，不阻断写入；其它失败记 ERROR 并向上抛，
 * 不允许把「已 rename」当成持久化成功。
 */
protected class AtomicFile {
    private static let log = LoggerFactory.getLogger("fountain::fmq.meta.AtomicFile")
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
            try {
                file.flush()
            } catch (e: Exception) {
                log.error("fsync of ${tmp} failed, abort write of ${path}: ${e.message}")
                throw e
            }
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

    /**
     * 目录 fsync：平台不支持时按尽力而为处理，真实失败向上抛。
     *
     * 不区分两者会把「目录 fsync 未实现」当成致命错误，让所有元数据写入瘫痪；
     * 反过来一律吞掉则会让掉电丢文件的真实故障无迹可寻。
     */
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
        } catch (e: Exception) {
            if (isUnsupportedFsync(e)) {
                log.debug("directory fsync is not supported on ${parent}, skipped: ${e.message}")
            } else {
                log.error("directory fsync of ${parent} failed: ${e.message}")
                throw e
            }
        }
    }

    /** 判断是否属于「平台不支持目录 fsync」：这类失败不阻断写入。 */
    protected static func isUnsupportedFsync(e: Exception): Bool {
        let message = e.message.toAsciiLower()
        message.contains("not support") || message.contains("unsupported") ||
            message.contains("operation not permitted") || message.contains("invalid argument")
    }
}
