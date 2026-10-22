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
package fountain::f_io

import std.fs.*

/** 持久边界不能读取或发布时，停止该日志；不得退回物理文件长度。 */
public class LogBoundaryException <: Exception {
    public init(message: String) {
        super(message)
    }
}

/**
 * 固定 44 字节：版本标识、段号、容量、已提交长度、生命周期状态（均大端），最后 CRC32。
 * 只描述通用字节边界，不解释 MQ 或 WAL 的记录。文件名由所属 SegmentedLog 生成。
 */
internal class SegmentBoundary {
    static let INITIALIZING = 0i64
    static let COMMITTED = 1i64
    static let DELETING = 2i64
    static let SUFFIX = ".boundary"
    private static let MAGIC: Array<Byte> = [0x46u8, 0x53u8, 0x4cu8, 0x45u8, 0x4eu8, 0x30u8, 0x30u8, 0x31u8]

    let seq: Int64
    let capacity: Int64
    let length: Int64
    let state: Int64

    init(seq: Int64, capacity: Int64, length: Int64, state: Int64) {
        if (seq < 0 || capacity <= 0 || length < 0 || length > capacity ||
            state < INITIALIZING || state > DELETING || (state == INITIALIZING && length != 0)) {
            throw LogBoundaryException("invalid segment boundary fields")
        }
        this.seq = seq
        this.capacity = capacity
        this.length = length
        this.state = state
    }

    func bytes(): Array<Byte> {
        let result = Array<Byte>(44, repeat: 0u8)
        MAGIC.copyTo(result, 0, 0, MAGIC.size)
        put(result, 8, seq)
        put(result, 16, capacity)
        put(result, 24, length)
        put(result, 32, state)
        let sum = checksum(result[0..40])
        for (i in 0..4) {
            result[40 + i] = UInt8((sum >> ((3 - i) * 8)) & 0xffu32)
        }
        result
    }

    static func load(dataPath: String, expectedSeq: Int64, expectedCapacity: Int64): SegmentBoundary {
        let path = dataPath + SUFFIX
        try {
            if (!exists(path) || FileInfo(path).size != 44) {
                throw LogBoundaryException("missing or invalid segment boundary: ${path}")
            }
            let file = File(path, OpenMode.Read)
            let bytes = Array<Byte>(44, repeat: 0u8)
            try {
                var got = 0i64
                while (got < bytes.size) {
                    let n = file.read(bytes[got..])
                    if (n <= 0) {
                        throw LogBoundaryException("short segment boundary: ${path}")
                    }
                    got += n
                }
            } finally {
                file.close()
            }
            if (bytes[0..8] != MAGIC) {
                throw LogBoundaryException("unsupported segment boundary version: ${path}")
            }
            var stored = 0u32
            for (i in 40..44) {
                stored = (stored << 8) | UInt32(bytes[i])
            }
            if (stored != checksum(bytes[0..40])) {
                throw LogBoundaryException("segment boundary checksum mismatch: ${path}")
            }
            let result = SegmentBoundary(get(bytes, 8), get(bytes, 16), get(bytes, 24), get(bytes, 32))
            if (result.seq != expectedSeq || result.capacity != expectedCapacity) {
                throw LogBoundaryException("segment boundary identity mismatch: ${path}")
            }
            result
        } catch (e: LogBoundaryException) {
            throw e
        } catch (e: Exception) {
            throw LogBoundaryException("cannot read segment boundary ${path}: ${e.message}")
        }
    }

    /** 数据已同步后才能调用；任何步骤失败均向上传播，临时文件保留为未决结果。 */
    func publish(dataPath: String, step!: (String) -> Unit = {_ => ()}): Unit {
        let path = dataPath + SUFFIX
        let tmp = path + ".tmp"
        if (exists(tmp)) {
            throw LogBoundaryException("unresolved boundary temporary file: ${tmp}")
        }
        let file = File.create(tmp)
        try {
            file.write(bytes())
            step("before-boundary-file-sync")
            file.flush()
        } finally {
            file.close()
        }
        step("before-boundary-rename")
        rename(tmp, to: path, overwrite: true)
        step("before-boundary-directory-sync")
        syncDirectory(Path(path).parent.toString())
        step("after-boundary-sync")
    }

    /** 仅启动完整校验后调用；遗留临时发布保留原字节，不作为已提交长度。 */
    static func preserveTemporary(dataPath: String): Unit {
        let tmp = dataPath + SUFFIX + ".tmp"
        var index = 0i64
        var target = dataPath + SUFFIX + ".unpublished.${index}"
        while (exists(target)) {
            if (index == Int64.Max) { throw LogBoundaryException("unpublished boundary names are exhausted") }
            index++
            target = dataPath + SUFFIX + ".unpublished.${index}"
        }
        rename(tmp, to: target, overwrite: false)
        syncDirectory(Path(dataPath).parent.toString())
    }

    /** 不将不支持、权限或 I/O 错误解释为同步成功。 */
    static func syncDirectory(path: String): Unit {
        let directory = File(path, OpenMode.Read)
        try {
            directory.flush()
        } finally {
            directory.close()
        }
    }

    /** 新建目录逐级同步父目录，避免仅同步文件却丢失其目录名。 */
    static func ensureDirectory(path: String): Unit {
        if (exists(path)) {
            return
        }
        let parent = Path(path).parent.toString()
        if (parent == path || parent.isEmpty()) {
            throw LogBoundaryException("cannot create log directory: ${path}")
        }
        ensureDirectory(parent)
        Directory.create(path)
        syncDirectory(parent)
        syncDirectory(path)
    }

    private static func put(bytes: Array<Byte>, offset: Int64, value: Int64): Unit {
        for (i in 0..8) {
            bytes[offset + i] = UInt8((value >> ((7 - i) * 8)) & 0xff)
        }
    }

    private static func get(bytes: Array<Byte>, offset: Int64): Int64 {
        if (bytes[offset] >= 0x80u8) {
            throw LogBoundaryException("negative or overflowing segment boundary field")
        }
        var value = 0i64
        for (i in 0..8) {
            value = (value << 8) | Int64(bytes[offset + i])
        }
        value
    }

    /** 只校验固定元数据；CRC 不构成消息载荷的介质损坏保证。 */
    private static func checksum(bytes: Array<Byte>): UInt32 {
        var crc = 0xffffffffu32
        for (byte in bytes) {
            crc = crc ^ UInt32(byte)
            for (_ in 0..8) {
                crc = if ((crc & 1u32) != 0) { (crc >> 1) ^ 0xedb88320u32 } else { crc >> 1 }
            }
        }
        crc ^ 0xffffffffu32
    }
}
