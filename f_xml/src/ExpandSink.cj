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
package fountain::f_xml

import std.collection.ArrayList
import std.env
import std.fs.{Directory, File, Path, exists, removeIfExists}
import std.io.SeekPosition
import fountain::f_base.StringGenerator

/**
 * 实体溢出目录的四级解析。
 *
 * 顺序固定：`EntityLimits.spillDir` → `TMPDIR` → 系统临时目录 → `./.fountain_tmp`（自动创建）。
 * 四级全失败直接抛错，**不降级回内存**——那等于把 OOM 风险重新引回来，而且调用方完全无感。
 */
internal class SpillDir {
    static func candidates(limits: EntityLimits): ArrayList<Path> {
        let list = ArrayList<Path>()
        if (let Some(dir) <- limits.spillDir) {
            list.add(dir)
        }
        if (let Some(value) <- env.getVariable("TMPDIR")) {
            if (!value.isEmpty()) {
                list.add(Path(value))
            }
        }
        list.add(env.getTempDirectory())
        list.add(fallbackDirectory())
        list
    }

    static func fallbackDirectory(): Path {
        env.getWorkingDirectory().join(".fountain_tmp")
    }

    /** 按序尝试创建溢出文件；全部失败抛含 `spillDir` 的异常。 */
    static func createFile(limits: EntityLimits): File {
        let fallback = fallbackDirectory().toString()
        for (candidate in candidates(limits)) {
            try {
                if (!exists(candidate)) {
                    if (candidate.toString() != fallback) {
                        continue
                    }
                    Directory.create(candidate, recursive: true)
                }
                return File.createTemp(candidate)
            } catch (_: Exception) {
                continue
            }
        }
        throw XmlException("无法创建实体溢出文件，请显式指定 spillDir")
    }
}

/**
 * 实体展开的落点：内存或临时文件，**单向切换**。
 *
 * - `Spill`：软阈值超限后把已有内容倒进文件、后续直接写文件；切换不回头。
 * - `Strict`：软阈值超限直接抛。
 * - 属性值（`attribute = true`）：**永不溢出**，超限抛 `AttributeValue`。
 *
 * 溢出文件恒为 UTF-8（写的是已解码字符的 UTF-8 编码），与输入编码无关。
 */
internal class ExpandSink {
    private let limits: EntityLimits
    private let attribute: Bool
    private let attrName: ?String
    private let counter: EntityCounter
    private let memory = StringGenerator()
    private var file: ?File = None
    private var filePath: ?Path = None
    private var bytes: Int64 = 0
    private var forcedSpill: Bool

    init(
        limits: EntityLimits,
        counter: EntityCounter,
        attribute!: Bool = false,
        attrName!: ?String = None,
        forcedSpill!: Bool = false
    ) {
        this.limits = limits
        this.counter = counter
        this.attribute = attribute
        this.attrName = attrName
        this.forcedSpill = forcedSpill
    }

    /** 溢出文件路径（测试用）。 */
    func spillPath(): ?Path {
        this.filePath
    }

    func isSpilled(): Bool {
        this.file.isSome()
    }

    /** 内存侧保留的字节数：溢出后为 0。 */
    func retainedBytes(): Int64 {
        if (this.isSpilled()) {
            0
        } else {
            this.memory.size
        }
    }

    func size(): Int64 {
        this.bytes
    }

    /** 只对内存态有意义；溢出后返回空串（调用方应先看 `isSpilled`）。 */
    func text(): String {
        this.memory.toString()
    }

    /** 追加一段已展开的字符，并在写入前完成全部计数与阈值判定。 */
    func write(segment: String): Unit {
        if (segment.isEmpty()) {
            return
        }
        let length = Int64(runesOf(segment).size)
        let nextBytes = this.bytes + length
        let nextTotal = this.counter.total + length

        if (this.attribute) {
            if (nextBytes > this.limits.maxExpandedPerEntity) {
                throw XmlException(
                    "属性 ${attrLabel(this.attrName)} 的值中实体展开超过 ${kbText(this.limits.maxExpandedPerEntity)}，属性值不支持溢出",
                    0,
                    0,
                    kind: EntityLimitKind.AttributeValue
                )
            }
            if (nextTotal > this.limits.maxExpandedHardLimit) {
                throw XmlException("实体展开总量超过硬限制", 0, 0, kind: EntityLimitKind.HardLimit)
            }
            if (this.limits.overflowPolicy == EntityOverflowPolicy.Strict &&
                nextTotal > this.limits.maxExpandedTotal) {
                throw XmlException(
                    "实体展开总量超过 ${kbText(this.limits.maxExpandedTotal)}",
                    0,
                    0,
                    kind: EntityLimitKind.Total
                )
            }
        } else {
            if (nextTotal > this.limits.maxExpandedHardLimit) {
                throw XmlException(
                    "实体展开总量超过硬限制 ${this.limits.maxExpandedHardLimit}",
                    0,
                    0,
                    kind: EntityLimitKind.HardLimit
                )
            }
            let overPerEntity = nextBytes > this.limits.maxExpandedPerEntity
            let overTotal = nextTotal > this.limits.maxExpandedTotal
            if (this.limits.overflowPolicy == EntityOverflowPolicy.Strict) {
                if (overPerEntity) {
                    throw XmlException(
                        "单实体展开量超过 ${kbText(this.limits.maxExpandedPerEntity)}",
                        0,
                        0,
                        kind: EntityLimitKind.PerEntity
                    )
                }
                if (overTotal) {
                    throw XmlException(
                        "实体展开总量超过 ${kbText(this.limits.maxExpandedTotal)}",
                        0,
                        0,
                        kind: EntityLimitKind.Total
                    )
                }
            } else if (overPerEntity || overTotal || this.forcedSpill) {
                this.spill()
            }
        }

        this.counter.total = nextTotal
        this.bytes = nextBytes
        match (this.file) {
            case Some(file) => file.write(segment.toArray())
            case None => this.memory.append<String>(segment)
        }
    }

    private func spill(): Unit {
        if (this.isSpilled()) {
            return
        }
        let file = SpillDir.createFile(this.limits)
        this.filePath = Some(file.info.path)
        // File.createTemp 已经创建了文件句柄；先写内存里已有的内容。
        if (this.memory.size > 0) {
            file.write(this.memory.unsafeBytes())
        }
        this.memory.clear()
        this.file = Some(file)
    }

    /**
     * 读回全部内容：内存态直接给字符串；文件态按 `bufSize` 分块解码。
     *
     * 溢出对下游完全透明——消费方只看到「分块」，本来就允许一段文本拆成多次回调。
     */
    func readAll(bufSize: Int64): String {
        let reader = this.openReader(bufSize)
        let gen = StringGenerator()
        while (true) {
            let cp = reader.nextCp()
            if (cp < 0) {
                break
            }
            gen.append(Rune(cp))
        }
        reader.close()
        gen.toString()
    }

    /** 关闭并删除溢出文件（用完即删）。 */
    func close(): Unit {
        match (this.file) {
            case Some(file) =>
                file.close()
                this.file = None
            case None => ()
        }
        match (this.filePath) {
            case Some(path) =>
                try {
                    removeIfExists(path)
                } catch (_: Exception) {}
                this.filePath = None
            case None => ()
        }
        this.memory.clear()
    }

    /** 打开一个逐字符读回器（内存 / 文件两态统一）。溢出文件在读到 EOF 时自动删除。 */
    func openReader(bufSize: Int64): ExpandReader {
        match (this.file) {
            case Some(file) =>
                file.flush()
                file.seek(SeekPosition.Begin(0))
                FileExpandReader(file, this.filePath, ByteDecoder(file, ByteCodec.Utf8Replace, bufSize))
            case None => MemoryExpandReader(cps32Of(this.memory.toString()))
        }
    }
}

internal func kbText(bytes: Int64): String {
    if (bytes >= 1024 * 1024) {
        "${bytes / (1024 * 1024)} MB"
    } else if (bytes >= 1024) {
        "${bytes / 1024} KB"
    } else {
        "${bytes} 字节"
    }
}

internal func attrLabel(name: ?String): String {
    match (name) {
        case Some(n) => "'${n}'"
        case None => ""
    }
}

/** 解析器实例级的展开计数器（不是全局状态）。 */
internal class EntityCounter {
    var total: Int64 = 0
}


/** 溢出内容的逐字符读回器（码点入口；`next()` 只是包装）。 */
internal interface ExpandReader {
    func nextCp(): Int64
    func next(): ?Rune
    func close(): Unit
}

internal class MemoryExpandReader <: ExpandReader {
    private let cps: Array<Int32>
    private var pos: Int64 = 0

    init(cps: Array<Int32>) {
        this.cps = cps
    }

    public func nextCp(): Int64 {
        if (this.pos >= this.cps.size) {
            return -1
        }
        let cp = Int64(this.cps[this.pos])
        this.pos++
        cp
    }

    public func next(): ?Rune {
        let cp = this.nextCp()
        if (cp < 0) {
            None
        } else {
            Some(Rune(cp))
        }
    }

    public func close(): Unit {}
}

internal class FileExpandReader <: ExpandReader {
    private let file: File
    private let path: ?Path
    private let decoder: ByteDecoder
    private var closed = false

    init(file: File, path: ?Path, decoder: ByteDecoder) {
        this.file = file
        this.path = path
        this.decoder = decoder
    }

    public func nextCp(): Int64 {
        let cp = this.decoder.next()
        if (cp < 0) {
            this.close()
        }
        cp
    }

    public func next(): ?Rune {
        let cp = this.nextCp()
        if (cp < 0) {
            None
        } else {
            Some(Rune(cp))
        }
    }

    public func close(): Unit {
        if (this.closed) {
            return
        }
        this.closed = true
        this.file.close()
        match (this.path) {
            case Some(p) =>
                try {
                    removeIfExists(p)
                } catch (_: Exception) {}
            case None => ()
        }
    }
}
