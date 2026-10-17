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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.*

/**
 * S2.2 `ByteReader` / `ByteWriter` 的失败用例（先写红）。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §11.2「编码与端序」：字节码是**字节串、固定小端（LE）**，
 * 多字节操作数必须**显式解码**；禁止 memcpy、指针强转、结构体覆盖来解读字节码。所有指令
 * 定长、无对齐要求（故本组用例刻意覆盖非对齐与跨边界位置）。
 */
@Test
public class ByteCodec_test {
    /** 字节序断言 + 往返：`0x0102` 的 LE 字节序列为 `02 01`，读回与写入值相同。 */
    @TestCase
    public func littleEndianRoundTrip(): Unit {
        let w = ByteWriter()
        w.wU16(0x0102u16)
        let bs = w.take()
        @Assert(bs.size, 2)
        @Assert(bs[0], 0x02u8)
        @Assert(bs[1], 0x01u8)

        let r = ByteReader(bs)
        @Assert(r.u16(), 0x0102u16)
        @Assert(r.remaining(), 0)
    }

    /** 各原语逐字节 LE 往返（u8/u16/u32/i32/i64/f64bits/bytes）。 */
    @TestCase
    public func allPrimitivesRoundTrip(): Unit {
        let w = ByteWriter()
        w.wU8(0xABu8)
        w.wU16(0xBEEFu16)
        w.wU32(0xDEADBEEFu32)
        w.wI32(-2i32)
        w.wI64(-9007199254740993i64)
        w.wU64(0x7FF8000000000000u64)
        w.wBytes([0x01u8, 0x02u8, 0x03u8])
        let bs = w.take()
        @Assert(bs.size, 1 + 2 + 4 + 4 + 8 + 8 + 3)

        let r = ByteReader(bs)
        @Assert(r.u8(), 0xABu8)
        @Assert(r.u16(), 0xBEEFu16)
        @Assert(r.u32(), 0xDEADBEEFu32)
        @Assert(r.i32(), -2i32)
        @Assert(r.i64(), -9007199254740993i64)
        @Assert(r.f64bits(), 0x7FF8000000000000u64)
        @Assert(r.bytes(3).size, 3)
        @Assert(r.remaining(), 0)
    }

    /** 非对齐与跨缓冲区边界：结果必须与对齐位置逐位一致，不依赖主机端序与对齐（§11.2、T3）。 */
    @TestCase
    public func unalignedAndCrossBoundaryAreIdentical(): Unit {
        // 同一串多字节值，分别在偏移 0 / 1 / 3 写入（制造非对齐），读回必须一致
        for (pad in 0..4) {
            let w = ByteWriter()
            for (_ in 0..pad) {
                w.wU8(0xCCu8)
            }
            w.wU32(0x01020304u32)
            w.wI64(-1i64)
            w.wU16(0x0708u16)
            let bs = w.take()

            let r = ByteReader(bs, Int64(pad))
            @Assert(r.u32(), 0x01020304u32)
            @Assert(r.i64(), -1i64)
            @Assert(r.u16(), 0x0708u16)
            @Assert(r.remaining(), 0)
        }
    }

    /** 逐字节手工拼出的 LE 序列可被正确读回（反向验证：不靠写侧自证）。 */
    @TestCase
    public func handBuiltLittleEndianBytes(): Unit {
        // 0x12345678 的 LE = 78 56 34 12
        let bs = [0x78u8, 0x56u8, 0x34u8, 0x12u8]
        @Assert(ByteReader(bs).u32(), 0x12345678u32)
        // -1i32 的补码 LE = FF FF FF FF
        @Assert(ByteReader([0xFFu8, 0xFFu8, 0xFFu8, 0xFFu8]).i32(), -1i32)
        // -1i64
        @Assert(ByteReader([0xFFu8, 0xFFu8, 0xFFu8, 0xFFu8, 0xFFu8, 0xFFu8, 0xFFu8, 0xFFu8]).i64(), -1i64)
    }

    /** 越界读必须报错而非越界访问（§11.2「必须显式解码」的防御面）。 */
    @TestCase
    public func outOfBoundsReadIsRejected(): Unit {
        let bs = [0x01u8, 0x02u8]
        let r = ByteReader(bs)
        @Assert(r.u8(), 0x01u8)
        @Assert(r.u8(), 0x02u8)
        @Assert(r.remaining(), 0)

        var rejected = 0
        try {
            r.u8()
        } catch (e: JitException) {
            rejected = rejected + 1
            @Assert(e.code, ErrCode.NOT_IMPL)
        }
        try {
            r.u32()
        } catch (e: JitException) {
            rejected = rejected + 1
        }
        try {
            r.bytes(1)
        } catch (e: JitException) {
            rejected = rejected + 1
        }
        @Assert(rejected, 3)
    }

    /** `bytes(n)` 请求量超过剩余量即拒绝；恰好取完则成功。 */
    @TestCase
    public func bytesHonoursRemaining(): Unit {
        let r = ByteReader([0x0Au8, 0x0Bu8, 0x0Cu8])
        @Assert(r.bytes(2), [0x0Au8, 0x0Bu8])
        @Assert(r.remaining(), 1)
        var rejected = false
        try {
            r.bytes(2)
        } catch (e: JitException) {
            rejected = true
        }
        @Assert(rejected, true)
        @Assert(r.remaining(), 1)
    }

    /** `Float64` 位模式往返：canonical NaN 的位模式不被改动（§11.3）。 */
    @TestCase
    public func floatBitsArePreserved(): Unit {
        let canonical = 0x7FF8000000000000u64
        let w = ByteWriter()
        w.wU64(canonical)
        @Assert(ByteReader(w.take()).f64bits(), canonical)
    }
}
