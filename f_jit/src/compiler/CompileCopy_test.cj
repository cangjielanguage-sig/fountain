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
package fountain::f_jit.compiler

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_base.Arch
import fountain::f_jit.backend.A64Compiler
import fountain::f_jit.backend.JitCompiler
import fountain::f_jit.backend.X86Compiler
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.Version
import fountain::f_jit.bytecode.FbcReader
import fountain::f_jit.bytecode.LoadedUnit

/**
 * 整单元发码的拼接契约（`optimize-compile-copy`）。
 *
 * `JitCompiler.compileUnitWith` 把逐函数产物拼成一整块 code 段。本次把它从
 * 「`ArrayList` 逐字节追加 + `toArray`」改成「一次分配 + 下标写入」，
 * 必须保证：**拼接结果与逐函数产物逐个字节相同，且 offsets/lengths 与拼接自洽**。
 *
 * 与架构无关：在 aarch64 上走 `A64Compiler`，在 x86_64 上走 `X86Compiler`，
 * 与 `compileUnitWith` 内部的选择规则一致。
 */
@Test
public class CompileCopy_test {
    private static func registry(n: Int64): PredefinedSnapshot {
        let names = ArrayList<String>()
        let pts = ArrayList<Array<UInt16>>()
        let rts = ArrayList<UInt16>()
        var i = 0
        while (i < n) {
            names.add('fn${i}')
            pts.add([LocalType.I64])
            rts.add(LocalType.I64)
            i = i + 1
        }
        PredefinedSnapshot(names.toArray(), pts.toArray(), rts.toArray())
    }

    private static func unitOf(): LoadedUnit {
        // 闭包只捕获形参（预定义函数名在闭包创建点不可捕获，DA 会拒绝）
        let src = '{ n: Int64 => let g = { x: Int64 => x * 2 }\n g(n) + fn0(1) + fn1(2) }'
        let cu = SourceCompiler(CompileCopy_test.registry(4), DummyDiagnosticsSink(),
            verMajor: Version.LATEST).compile(src)
        FbcReader.load(cu.raw)
    }

    private static func perFunction(unit: LoadedUnit, idx: Int64): ?Array<UInt8> {
        let fn = unit.dir.at(idx)
        match (Arch.current.toString()) {
            case 'x86_64' => X86Compiler.compileFunctionWith(unit, fn, 0, 0)
            case _ => A64Compiler.compileFunctionWith(unit, fn, 0, 0)
        }
    }

    @TestCase
    public func unitCodeEqualsPerFunctionConcat(): Unit {
        let unit = CompileCopy_test.unitOf()
        // 必须真有多个函数，否则「拼接」这件事没被覆盖
        @Assert(unit.dir.size >= 2, true)

        let art = match (JitCompiler.compileUnitWith(unit, 0, 0)) {
            case Some(a) => a
            case None =>
                @Fail('compileUnitWith 返回 None（本机架构应支持）')
                return
        }

        let expected = ArrayList<UInt8>()
        var i = 0
        while (i < unit.dir.size) {
            let b = match (CompileCopy_test.perFunction(unit, i)) {
                case Some(x) => x
                case None =>
                    @Fail('逐函数发码返回 None')
                    return
            }
            @Assert(art.lengths[i], Int64(b.size))
            @Assert(art.offsets[i], Int64(expected.size))
            @Assert(art.fnIds[i], unit.dir.at(i).fnId)
            for (x in b) {
                expected.add(x)
            }
            i = i + 1
        }

        @Assert(Int64(art.code.size), Int64(expected.size))
        i = 0
        while (i < Int64(expected.size)) {
            @Assert(art.code[i], expected[i])
            i = i + 1
        }

        // entry 反查必须落在同一偏移
        i = 0
        while (i < unit.dir.size) {
            let fn = unit.dir.at(i)
            match (art.entry(fn.fnId)) {
                case Some((off, _)) => @Assert(off, art.offsets[i])
                case None => @Fail('entry 缺函数 ${fn.fnId}')
            }
            i = i + 1
        }
    }
}
