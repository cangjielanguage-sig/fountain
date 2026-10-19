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
package fountain::f_jit.bytecode

import std.collection.ArrayList
import fountain::f_jit.base.Version
import fountain::f_util.Crc32

/**
 * `.fbc` 容器组装 —— design-m1 §3.3.8、plan-m1 S2.12。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §11.6。`crc32` 覆盖 **code + const + site + name** 四段
 * （头、目录、类型表不在内），算法 = **CRC-32/ISO-HDLC**，实现直接用
 * `fountain::f_util.Crc32.isoHdlc`（**不自实现**，design D8）——与 f_protocol 帧校验、
 * f_store WAL 校验同款。基准向量：`crc32(空) = 0`、`crc32("123456789") = 0xCBF43926`。
 *
 * 写方（本类）与读方（`FbcReader`）必须**同一口径**（§11.6 末句）。
 *
 * 本类**只写新布局**（`verMinor = 14`、`hdrSize = 36`、含 name 段）：旧布局单元的写出属于历史
 * 产物，M1 不再生产（§11.6「加载器按 verMinor 分支」只需读侧兼容）。
 */
public class FbcWriter {
    private var entryFn: UInt32 = 0u32
    private var flags: UInt32 = FbcFlags.UTF8
    private var code: Array<UInt8> = Array<UInt8>()
    private var consts: Array<UInt8> = Array<UInt8>()
    private var site: Array<UInt8> = Array<UInt8>()
    private var name: Array<UInt8> = Array<UInt8>()

    public init() {}

    /** 入口函数号（须命中目录，加载期校验）。 */
    public func setEntryFn(fnId: UInt32): Unit {
        this.entryFn = fnId
    }

    /** 头 flags 位域（默认 `bit0=UTF-8`）。 */
    public func setFlags(flags: UInt32): Unit {
        this.flags = flags
    }

    /** code 段（= 函数目录 + 局部类型表 + 各函数体，§11.7）。 */
    public func setCode(bytes: Array<UInt8>): Unit {
        this.code = bytes
    }

    /** const 段（§11.5，含 DAG 常量表）。 */
    public func setConst(bytes: Array<UInt8>): Unit {
        this.consts = bytes
    }

    /** site 段（§11.6，`count + 12 B × count`）。 */
    public func setSite(bytes: Array<UInt8>): Unit {
        this.site = bytes
    }

    /** name 段（§11.6，`count + 16 B × count + strBytes`；段恒存在，`count` 可为 0）。 */
    public func setName(bytes: Array<UInt8>): Unit {
        this.name = bytes
    }

    /** 四段拼接后的 CRC-32/ISO-HDLC（`f_util` 实现，design D8）。 */
    public func crc32OfPayload(): UInt32 {
        let all = ArrayList<UInt8>()
        for (b in this.code) {
            all.add(b)
        }
        for (b in this.consts) {
            all.add(b)
        }
        for (b in this.site) {
            all.add(b)
        }
        for (b in this.name) {
            all.add(b)
        }
        Crc32.isoHdlc.compute(all.toArray())
    }

    /** 组装完整 `.fbc` 字节串。 */
    public func build(): Array<UInt8> {
        let h = FbcHeader(
            Version.MAGIC,
            Version.MAJOR,
            Version.MINOR,
            this.flags,
            Version.HDR_SIZE,
            UInt32(this.code.size),
            UInt32(this.consts.size),
            UInt32(this.site.size),
            this.entryFn,
            UInt32(this.name.size),
            crc32OfPayload())
        let w = ByteWriter()
        h.write(w)
        w.wBytes(this.code)
        w.wBytes(this.consts)
        w.wBytes(this.site)
        w.wBytes(this.name)
        w.take()
    }
}
