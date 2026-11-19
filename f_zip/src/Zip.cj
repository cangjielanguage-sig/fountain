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
package fountain::f_zip

import std.fs.{Directory, Path}
import std.io.OutputStream
import fountain::f_log.LoggerFactory

private struct ZipLog {
    static let logger = LoggerFactory.getLogger<ZipWriter>()
}

/**
 * 把目录打包成 ZIP，返回写入的**文件数**（不含目录条目）。
 *
 * 每个文件走 `addFileStream`——打包一个 2 GB 的目录不需要 2 GB 内存。
 * 目录本身写目录条目（空目录也能还原）。
 *
 * 符号链接一律跳过：文件链接跳过该条目，**目录链接跳过整棵子树**
 * （否则 `loop -> /` 会无限递归）。
 */
public func zip(output: OutputStream, dir: Path, options!: ZipWriterOptions = ZipWriterOptions()): Int64 {
    let writer = ZipWriter(output, options: options)
    let count = addTree(writer, dir, "")
    writer.close()
    count
}

private func addTree(writer: ZipWriter, current: Path, prefix: String): Int64 {
    var count: Int64 = 0
    for (info in Directory.readFrom(current)) {
        let name = if (prefix.isEmpty()) {
            info.name
        } else {
            "${prefix}/${info.name}"
        }
        if (info.isSymbolicLink()) {
            ZipLog.logger.warn("zip: 跳过符号链接 ${name}")
            continue
        }
        if (info.isDirectory()) {
            writer.addDirectory(name)
            count += addTree(writer, info.path, name)
        } else if (info.isRegular()) {
            writer.addFile(name, info.path)
            count += 1
        }
    }
    count
}
