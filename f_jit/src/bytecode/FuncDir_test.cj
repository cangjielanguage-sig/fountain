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
 * S2.4 / S2.5 `FuncEntry` + `FuncFlags` + `FuncDir` 的失败用例（先写红）。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §11.7：
 *
 * ```
 * FuncDir   { count: u32, funcs: [FuncEntry] }
 * FuncEntry = { fnId: u32, u32, u32, u32,
 *               u16, u16, u16, u16, u16 }   // 恒 26 B
 * ```
 *
 * 字段顺序即序列化顺序（`localTypesOff` 相对 code 段起点）；`flags.bit0` = 含变更型调用。
 */
@Test
public class FuncDir_test {
    /** 条目恒 26 B 且编解码往返后字段保真（§11.7「恒 26 B」）。 */
    @TestCase
    public func entryRoundTripsIn26Bytes(): Unit {
        let e = FuncEntry(7u32,
            100u32,
            48u32,
            148u32,
            2u16,
            5u16,
            3u16,
            LocalType.I64,
            FuncFlags.MUTATION)
        @Assert(FuncEntry.SIZE, 26)

        let w = ByteWriter()
        e.write(w)
        let bs = w.take()
        @Assert(bs.size, 26)
        // 字段偏移核对（§11.7 顺序）：fnId@0 codeOff@4 codeLen@8 localTypesOff@12
        // nargs@16 nLocals@18 maxStack@20 retType@22 flags@24
        let r = ByteReader(bs)
        @Assert(r.u32(), 7u32)
        @Assert(r.u32(), 100u32)
        @Assert(r.u32(), 48u32)
        @Assert(r.u32(), 148u32)
        @Assert(r.u16(), 2u16)
        @Assert(r.u16(), 5u16)
        @Assert(r.u16(), 3u16)
        @Assert(r.u16(), 0u16)
        @Assert(r.u16(), 1u16)
        @Assert(r.remaining(), 0)

        let back = FuncEntry.read(ByteReader(bs))
        @Assert(back.fnId, e.fnId)
        @Assert(back.codeOff, e.codeOff)
        @Assert(back.codeLen, e.codeLen)
        @Assert(back.localTypesOff, e.localTypesOff)
        @Assert(back.nargs, e.nargs)
        @Assert(back.nLocals, e.nLocals)
        @Assert(back.maxStack, e.maxStack)
        @Assert(back.retType, e.retType)
        @Assert(back.flags, e.flags)
    }

    /** 目录增 / 查 / 未命中。 */
    @TestCase
    public func dirAddGetFindSize(): Unit {
        let dir = FuncDir()
        @Assert(dir.size, 0)
        dir.add(FuncEntry(0u32, 30u32, 10u32, 40u32,
            0u16, 1u16, 1u16, LocalType.I64, 0u16))
        dir.add(FuncEntry(1u32, 40u32, 10u32, 50u32,
            1u16, 2u16, 2u16, LocalType.STRING, 0u16))
        @Assert(dir.size, 2)
        @Assert(dir.get(1u32).codeOff, 40u32)
        @Assert(dir.get(1u32).retType, LocalType.STRING)
        @Assert(dir.find(0u32).isSome(), true)
        @Assert(dir.find(9u32).isNone(), true)
    }

    /** 重复 `fnId` 拒绝（`CALL_FUNC` 解析必须唯一，§11.7「`CALL_FUNC fid` 经目录解析目标」）。 */
    @TestCase
    public func duplicateFnIdIsRejected(): Unit {
        let dir = FuncDir()
        let e = FuncEntry(3u32, 30u32, 10u32, 40u32,
            0u16, 1u16, 1u16, LocalType.UNIT, 0u16)
        dir.add(e)
        var rejected = false
        try {
            dir.add(e)
        } catch (ex: JitException) {
            @Assert(ex.code, ErrCode.NOT_IMPL)
            rejected = true
        }
        @Assert(rejected, true)
        @Assert(dir.size, 1)
    }

    /** `codeOff + codeLen` 超出 code 段 ⇒ 拒绝（§11.7「加载器校验其结构」）。 */
    @TestCase
    public func codeRangeOutOfBoundsIsRejected(): Unit {
        let dir = FuncDir()
        dir.add(FuncEntry(0u32, 90u32, 20u32, 90u32,
            0u16, 1u16, 1u16, LocalType.I64, 0u16))
        var rejected = false
        try {
            dir.validate(100u32, 0u32)
        } catch (ex: JitException) {
            @Assert(ex.code, ErrCode.NOT_IMPL)
            rejected = true
        }
        @Assert(rejected, true)
    }

    /** `localTypesOff + nLocals` 超出 code 段 ⇒ 拒绝（局部类型表在 code 段内，§11.7）。 */
    @TestCase
    public func localTypesRangeOutOfBoundsIsRejected(): Unit {
        let dir = FuncDir()
        dir.add(FuncEntry(0u32, 10u32, 10u32, 98u32,
            0u16, 5u16, 1u16, LocalType.I64, 0u16))
        var rejected = false
        try {
            dir.validate(100u32, 0u32)
        } catch (ex: JitException) {
            rejected = true
        }
        @Assert(rejected, true)
    }

    /** 入口函数号不在目录中 ⇒ 拒绝（§11.7「容器头 `entryFn` 必须命中目录中某个 `fnId`」）。 */
    @TestCase
    public func entryFnMissIsRejected(): Unit {
        let dir = FuncDir()
        dir.add(FuncEntry(0u32, 30u32, 10u32, 40u32,
            0u16, 1u16, 1u16, LocalType.I64, 0u16))
        var rejected = false
        try {
            dir.validate(100u32, 5u32)
        } catch (ex: JitException) {
            rejected = true
        }
        @Assert(rejected, true)
    }

    /** 合法目录通过校验（正向对照，确保上三条拒绝不是「永不通过」）。 */
    @TestCase
    public func healthyDirPassesValidation(): Unit {
        let dir = FuncDir()
        // code 段 = 目录(4+26) + 类型表(2) = 32；函数体占位 [30,40)
        dir.add(FuncEntry(0u32, 30u32, 10u32, 30u32,
            0u16, 2u16, 1u16, LocalType.I64, 0u16))
        dir.validate(40u32, 0u32)
        @Assert(dir.size, 1)
    }
}
