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
package fountain::f_mq.base.payload

import std.fs.*
import std.io.SeekPosition
import fountain::f_data.*
import fountain::f_log.*

/**
 * 可承载大载荷的字节字段。
 *
 * `DefaultCodec` 对超过 `fileThreshold`（4096）字节的 `INPUTSTREAM` 会返回
 * `DataInputStream(File)` 形态；直接把字段声明成 `Array<Byte>` 时，字段 setter 的
 * 宽松转换会落到 `Array<T>.tryFromData` 的兜底分支，静默得到空数组 —— 大消息会被
 * 误判成「本次没有消息」。本类型在解码阶段就把两种形态统一成字节序列，并负责清理
 * 解码器创建的临时文件与父目录。
 *
 * 线格式与 `Array<Byte>` 完全一致（都编码成 `DataCollection<Array<Byte>, Byte>`），
 * 对象类型特征只取类全名，因此替换字段类型不改变字节布局。
 */
public class MQBlob <: DataFields<MQBlob> {
    private static let log = LoggerFactory.getLogger("fountain::f_mq.base.payload.MQBlob")
    private var bytes: Array<Byte>

    public init() {
        this.bytes = []
    }

    public init(bytes: Array<Byte>) {
        this.bytes = bytes
    }

    /** 字节数。 */
    public func size(): Int64 {
        this.bytes.size
    }

    /** 是否为空（空 blob 表示「无内容」，而不是「解码失败」）。 */
    public func isEmpty(): Bool {
        this.bytes.isEmpty()
    }

    /** 取字节副本；调用方可以安全修改返回值。 */
    public func copyBytes(): Array<Byte> {
        this.bytes.clone()
    }

    public func toData(): Data {
        DataCollection<Array<Byte>, Byte>(this.bytes)
    }

    public static func tryFromData(data: Data, flag: DataConversionFlag): Any {
        // 所有分支统一返回 `?MQBlob`：混用 `MQBlob` 与 `?MQBlob` 会让编译器把整个 match
        // 推断成 `Option<MQBlob>`，成功分支被自动包成 `Some`，调用方按 `MQBlob` 匹配就会漏判。
        match (data) {
            case x: DataAny => tryFromData(x.data, flag)
            case d: DataCollection<Array<Byte>, Byte> => Some(MQBlob(d.data))
            case d: DataInputStream =>
                match (d.data) {
                    // 只有文件形态可以还原；其它流没有长度语义，不能静默降级成空字节
                    case f: File =>
                        match (readWholeFile(f)) {
                            case Some(bytes) => Some(MQBlob(bytes))
                            case _ => None<MQBlob>
                        }
                    case _ => None<MQBlob>
                }
            // 缺字段不是「没有消息」：数据集合才是空载荷的合法表示（A01）
            case _: DataNone => None<MQBlob>
            case _ => None<MQBlob>
        }
    }

    public static func fromData(data: Data, flag: DataConversionFlag): Any {
        match (tryFromData(data, flag)) {
            case x: ?MQBlob => x ?? throw DataException(
                "data cannot be converted to ${TypeInfo.of<MQBlob>()}")
            case x: MQBlob => x
            case _ => throw DataException("data cannot be converted to ${TypeInfo.of<MQBlob>()}")
        }
    }

    private static func readWholeFile(file: File): ?Array<Byte> {
        // `file.info` / `seek` / `read` 都可能因为「临时目录已被其他读取者清理」而抛错；
        // 同一个流重复读取不属于协议允许的场景，这里统一降级成 `None`。
        try {
            let path = file.info.path
            let parent = file.info.parentDirectory
            // 解码器返回的大载荷文件停在写端位置，必须先回到文件头
            file.seek(SeekPosition.Begin(0))
            let size = file.info.size
            let out = Array<Byte>(size, repeat: 0u8)
            var got = 0i64
            while (got < size) {
                let n = file.read(out[got..size])
                if (n <= 0) {
                    break
                }
                got += n
            }
            if (!file.isClosed()) {
                file.close()
            }
            // 临时文件与其父目录都是本进程创建的，用完即删；清理失败不能影响解码结果，但要留痕
            try {
                removeIfExists(path)
            } catch (e: Exception) {
                log.warn("cannot remove decoded temp file ${path}: ${e.message}")
            }
            if (let Some(dir) <- parent) {
                try {
                    removeIfExists(dir.path)
                } catch (e: Exception) {
                    log.warn("cannot remove decoded temp dir ${dir.path}: ${e.message}")
                }
            }
            if (got != size) {
                None<Array<Byte>>
            } else {
                Some(out)
            }
        } catch (_: Exception) {
            try {
                if (!file.isClosed()) {
                    file.close()
                }
            } catch (_: Exception) {}
            None<Array<Byte>>
        }
    }
}
