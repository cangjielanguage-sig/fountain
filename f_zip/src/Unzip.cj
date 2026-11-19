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

import std.fs.{Directory, File, OpenMode, Path, exists, removeIfExists}
import std.io.InputStream
import fountain::f_log.LoggerFactory

/**
 * 把 ZIP 全部解压到目录，返回解压出的**文件数**（不含目录条目）。
 *
 * 安全策略在这里生效（读取层 `read` / `open` 不做任何路径判断）：
 *
 * 1. 拒绝绝对路径、含 `..` 段的路径、规范化后不在目标目录内的路径；
 * 2. 符号链接条目**跳过**（不跟随、不重建、不报错），只记 warning；
 * 3. `ZipLimits` 的四条上限透传（条目数在解析期拒绝，大小按实际解压字节累计）；
 * 4. 加密 ZIP 直接报错，不产生"解出来一半是对的"的部分结果。
 *
 * 目标目录不存在会自动创建；同名文件覆盖（与 `read` 取最后一个一致）。
 */
public func unzip(input: InputStream, dir: Path, limits!: ZipLimits = ZipLimits()): Int64 {
    let reader = ZipReader(input, limits: limits)
    var count: Int64 = 0
    try {
        count = unzipInto(reader, dir)
    } finally {
        reader.close()
    }
    count
}

/** 从文件解压（走 seek，不缓冲整包）。 */
public func unzip(path: String, dir: Path, limits!: ZipLimits = ZipLimits()): Int64 {
    let reader = ZipReader(path, limits: limits)
    var count: Int64 = 0
    try {
        count = unzipInto(reader, dir)
    } finally {
        reader.close()
    }
    count
}

private struct UnzipLog {
    static let logger = LoggerFactory.getLogger<ZipReader>()
}

private func unzipInto(reader: ZipReader, dir: Path): Int64 {
    ensureDirectory(dir)
    var count: Int64 = 0
    for (e in reader.internalEntries()) {
        if (isSymbolicLinkEntry(e)) {
            UnzipLog.logger.warn("zip: 跳过符号链接条目 ${e.name} -> ${readLinkTarget(reader, e)}")
            continue
        }
        let target = resolveSafeTarget(dir, e.name)
        if (e.isDirectory) {
            ensureDirectory(target)
            continue
        }
        ensureDirectory(target.parent)
        writeEntryToFile(reader, e, target)
        count += 1
    }
    count
}

/** `Directory.create` 对已存在的目录会抛异常，所以先判存在。 */
private func ensureDirectory(path: Path): Unit {
    if (!exists(path)) {
        Directory.create(path, recursive: true)
    }
}

/** `(externalAttributes >> 16) & 0xF000 == 0xA000` 即 Unix 符号链接。 */
internal func isSymbolicLinkEntry(e: CentralEntry): Bool {
    ((e.externalAttributes >> 16) & 0xF000) == 0xA000
}

/** 读链接目标只是为了把 warning 写全；读不出来就返回空串，不影响跳过。 */
private func readLinkTarget(reader: ZipReader, e: CentralEntry): String {
    if (e.uncompressedSize <= 0 || e.uncompressedSize > 4096) {
        return "?"
    }
    try {
        if (let Some(bytes) <- reader.read(e.name)) {
            return String.fromUtf8(bytes)
        }
        "?"
    } catch (_: Exception) {
        "?"
    }
}

/**
 * Zip Slip 校验：绝对路径 / 盘符 / `..` 段一律拒绝，规范化后必须仍在目标目录内。
 *
 * 校验**先于**任何落盘动作，所以非法条目不会留下半截目录树。
 */
internal func resolveSafeTarget(dir: Path, name: String): Path {
    if (name.isEmpty()) {
        throw ZipException("条目路径非法：${name}")
    }
    let bytes = name.toArray()
    if (bytes[0] == UInt8(47) || bytes[0] == UInt8(92)) {
        throw ZipException("条目路径非法：${name}")
    }
    if (bytes.size >= 2 && bytes[1] == UInt8(58) && isAsciiLetter(bytes[0])) {
        throw ZipException("条目路径非法：${name}")
    }
    for (segment in name.split("/")) {
        if (segment == "..") {
            throw ZipException("条目路径非法：${name}")
        }
    }
    let base = dir.normalize().toString()
    let target = dir.join(name).normalize().toString()
    let prefix = "${base}${Path.Separator}"
    if (target != base && !target.startsWith(prefix)) {
        throw ZipException("条目路径非法：${name}")
    }
    Path(target)
}

private func isAsciiLetter(b: Byte): Bool {
    (b >= UInt8(65) && b <= UInt8(90)) || (b >= UInt8(97) && b <= UInt8(122))
}

private func writeEntryToFile(reader: ZipReader, e: CentralEntry, target: Path): Unit {
    let stream = reader.openEntry(e)
    // Write 模式：存在则截断、不存在则创建（同名覆盖语义）
    let file = File(target.toString(), OpenMode.Write)
    var ok = false
    try {
        let buf = Array<Byte>(8192, repeat: 0)
        var n = stream.read(buf)
        while (n > 0) {
            file.write(buf[0..n])
            n = stream.read(buf)
        }
        file.flush()
        ok = true
    } finally {
        try {
            file.close()
        } catch (_: Exception) {}
        if (!ok) {
            // 超限 / CRC 失败 / 截断：不留半截文件
            try {
                removeIfExists(target)
            } catch (_: Exception) {}
        }
    }
}
