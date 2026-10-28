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

import std.env
import std.fs.{Directory, File, OpenMode, Path, exists}
import std.io.{ByteBuffer, SeekPosition}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_io.ByteBuffer as FByteBuffer
import fountain::f_base.OS

/** 慢用例门控：只有 `F_ZIP_SLOW=1` 才真正执行，其余时候直接返回。 */
internal func slowEnabled(): Bool {
    match (env.getVariable("F_ZIP_SLOW")) {
        case Some(v) => v == "1"
        case None => false
    }
}

/**
 * 大样本的工作目录：默认 `env.getTempDirectory()`，可用 `F_ZIP_TMP` 改道。
 *
 * 9.7b 要写 4 GB 以上的包，`/tmp` 在不少环境里是 tmpfs（等于吃内存），
 * 所以留一个环境变量把样本挪到大磁盘。
 */
internal func bigWorkDir(): Path {
    let base = match (env.getVariable("F_ZIP_TMP")) {
        case Some(v) => Path(v)
        case None => env.getTempDirectory()
    }
    if (!exists(base)) {
        Directory.create(base, recursive: true)
    }
    Directory.createTemp(base)
}

/** 建一个大小恰好 `size` 的稀疏文件：只写最后一个字节，中间是文件系统空洞。 */
internal func createSparseFile(path: Path, size: Int64): Unit {
    let file = File(path.toString(), OpenMode.Write)
    try {
        file.seek(Begin(size - 1))
        file.write([UInt8(0)])
        file.flush()
    } finally {
        try {
            file.close()
        } catch (_: Exception) {}
    }
}

/** 用一段构造逻辑产出完整 ZIP 字节。 */
internal func buildZipBytes(action: (ZipWriter) -> Unit, options!: ZipWriterOptions = ZipWriterOptions()): Array<Byte> {
    let out = ByteBuffer()
    let writer = ZipWriter(out, options: options)
    action(writer)
    writer.close()
    out.bytes()
}

/** 需要同时拿到构造过程中的返回值时用这个（闭包不能捕获可变变量）。 */
internal func buildZipWithResult<T>(
    action: (ZipWriter) -> T,
    options!: ZipWriterOptions = ZipWriterOptions()
): (Array<Byte>, T) {
    let out = ByteBuffer()
    let writer = ZipWriter(out, options: options)
    let result = action(writer)
    writer.close()
    (out.bytes(), result)
}

/** 平台默认阈值（Linux-gnu 64 MB，其他 16 MB）。 */
internal func expectedMemoryEntryThreshold(): Int64 {
    if (OS.current.isLinux) {
        64 * 1024 * 1024
    } else {
        16 * 1024 * 1024
    }
}

/** 把 ZIP 字节包成 reader。 */
internal func readerOf(bytes: Array<Byte>, limits!: ZipLimits = ZipLimits()): ZipReader {
    ZipReader(ByteBuffer(bytes), limits: limits)
}

internal func bytesEqual(a: Array<Byte>, b: Array<Byte>): Bool {
    if (a.size != b.size) {
        return false
    }
    for (i in 0..a.size) {
        if (a[i] != b[i]) {
            return false
        }
    }
    true
}

/** 在字节数组里找 `needle` 出现的次数（找 ZIP64 结构、descriptor 签名用）。 */
internal func countSignature(bytes: Array<Byte>, needle: Array<Byte>): Int64 {
    if (needle.size == 0 || bytes.size < needle.size) {
        return 0
    }
    var count: Int64 = 0
    var i: Int64 = 0
    while (i + needle.size <= bytes.size) {
        var matched = true
        for (j in 0..needle.size) {
            if (bytes[i + j] != needle[j]) {
                matched = false
                break
            }
        }
        if (matched) {
            count += 1
            i += needle.size
        } else {
            i += 1
        }
    }
    count
}

/** 在 `bytes` 里定位第一条 local header（`add` 的第一条总是从 0 开始）。 */
internal func parseLocalHeaderAt(bytes: Array<Byte>, offset: Int64): LocalHeader {
    let buf = FByteBuffer(bytes[offset..])
    readLocalHeader(buf)
}

internal func expectBytesEqual(actual: Array<Byte>, expected: Array<Byte>): Unit {
    if (!bytesEqual(actual, expected)) {
        @Fail("字节不一致：期望 ${expected.size} 字节，实际 ${actual.size} 字节")
    }
}
