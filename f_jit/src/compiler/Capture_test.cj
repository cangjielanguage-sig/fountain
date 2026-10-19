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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.SourceCompileException
import fountain::f_jit.base.Version
import fountain::f_jit.bytecode.FbcReader
import fountain::f_jit.bytecode.LoadedUnit

/** Q3.9 / Q3.10：逃逸闭包捕获描述符、白名单拒绝与放开。 */
@Test
public class Capture_test {
    /** 值型捕获可逃逸；描述符逐项分类为「值型」。 */
    @TestCase
    public func valueCaptureMayEscape(): Unit {
        let cu = Capture_test.compile('{ n: Int64 => { => n } }')
        @Assert(cu.captures.size, 1)
        let d = cu.captures[0]
        @Assert(d.escaping, true)
        @Assert(d.entries.size, 1)
        @Assert(d.entries[0].name, 'n')
        @Assert(d.entries[0].origin, CaptureOrigin.VALUE)
        @Assert(d.handleCaptureNames().size, 0)
    }

    /** 路径 A 常量捕获可逃逸。 */
    @TestCase
    public func constantCaptureMayEscape(): Unit {
        let cu = Capture_test.compile('{ => let c = "abc"\n { => c } }')
        @Assert(cu.captures.size, 1)
        let d = cu.captures[0]
        @Assert(d.escaping, true)
        @Assert(d.entries[0].origin, CaptureOrigin.CONSTANT)
        @Assert(d.handleCaptureNames().size, 0)
    }

    /** 路径 B（函数参数）捕获：第 1 步放开后仍保留来源分类。 */
    @TestCase
    public func parameterCaptureEscapeKeepsOrigin(): Unit {
        let cu = Capture_test.compile('{ s: String => { => s } }')
        @Assert(cu.captures[0].entries[0].name, 's')
        @Assert(cu.captures[0].entries[0].origin, CaptureOrigin.PARAMETER)
    }

    /** 路径 C（窗口分配）捕获：第 1 步放开后仍保留来源分类。 */
    @TestCase
    public func windowCaptureEscapeKeepsOrigin(): Unit {
        let cu = Capture_test.compile('{ => let l: List<Int64> = []\n { => l } }')
        @Assert(cu.captures[0].entries[0].name, 'l')
        @Assert(cu.captures[0].entries[0].origin, CaptureOrigin.WINDOW)
    }

    /** 非逃逸闭包：路径 B 捕获只分类、不拒绝。 */
    @TestCase
    public func nonEscapingParameterCaptureIsClassified(): Unit {
        let cu = Capture_test.compile('{ s: String => let f = { => s }\n 1 }')
        @Assert(cu.captures.size, 1)
        let d = cu.captures[0]
        @Assert(d.escaping, false)
        @Assert(d.entries[0].origin, CaptureOrigin.PARAMETER)
        @Assert(d.handleCaptureNames()[0], 's')
    }

    /** 描述符是编译期伴随知识，`.fbc` 仍按原格式加载（无新增段）。 */
    @TestCase
    public func descriptorIsNotInFbc(): Unit {
        let cu = Capture_test.compile('{ => let c = "abc"\n { => c } }')
        @Assert(cu.captures.size, 1)
        let unit = FbcReader.load(cu.raw)
        @Assert(unit.dir.size >= 1, true)
    }

    private static func compile(src: String): CompiledSourceUnit {
        let sc = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(),
            verMajor: Version.M2_MAJOR)
        sc.compile(src)
    }

    // ==================================================================
    // Q3.10：第 1 步放开拒绝面 + 提升组内容（描述符句柄集）
    // ==================================================================

    /** 路径 B 捕获不再编译错误；句柄型捕获集进入提升组。 */
    @TestCase
    public func parameterCaptureEscapeIsAllowed(): Unit {
        let cu = Capture_test.compile('{ s: String => { => s } }')
        @Assert(cu.captures.size, 1)
        let d = cu.captures[0]
        @Assert(d.escaping, true)
        @Assert(d.handleCaptureNames().size, 1)
        @Assert(d.handleCaptureNames()[0], 's')
    }

    /** 路径 C 捕获不再编译错误；提升组内容 = 句柄型捕获集。 */
    @TestCase
    public func windowCaptureEscapeIsAllowed(): Unit {
        let cu = Capture_test.compile('{ => let l: List<Int64> = []\n { => l } }')
        @Assert(cu.captures.size, 1)
        let d = cu.captures[0]
        @Assert(d.handleCaptureNames().size, 1)
        @Assert(d.handleCaptureNames()[0], 'l')
    }

    /** 混合捕获：B/C 入组，值型/路径 A 不入组。 */
    @TestCase
    public func promotionSetIsExactlyHandleCaptures(): Unit {
        let cu = Capture_test.compile(
            '{ s: String, n: Int64 => let c = "k"\n let l: List<Int64> = []\n { => s + c + l[0] + n } }')
        @Assert(cu.captures.size, 1)
        let names = cu.captures[0].handleCaptureNames()
        @Assert(names.size, 2)
        @Assert(Capture_test.has(names, 's'), true)
        @Assert(Capture_test.has(names, 'l'), true)
        @Assert(Capture_test.has(names, 'n'), false)
        @Assert(Capture_test.has(names, 'c'), false)
    }

    private static func has(xs: Array<String>, x: String): Bool {
        for (y in xs) {
            if (y == x) {
                return true
            }
        }
        false
    }

    /** `LOAD_CAP` 语义零变化：捕获项仍以 LOAD_CAP + STOREL 进闭包帧。 */
    @TestCase
    public func loadCapSemanticsUnchanged(): Unit {
        let cu = Capture_test.compile('{ s: String => { => s } }')
        let unit = FbcReader.load(cu.raw)
        @Assert(unit.dir.size, 2)
        let ops = CodeDump.ops(Capture_test.funcBytes(unit, 1u32))
        @Assert(ops.contains('LOAD_CAP'), true)
        @Assert(ops.contains('STOREL'), true)
    }

    /** 取目录中 `fnId` 对应项的函数体。 */
    private static func funcBytes(unit: LoadedUnit, fnId: UInt32): Array<UInt8> {
        var e = unit.dir.at(0)
        for (i in 0..unit.dir.size) {
            let cand = unit.dir.at(i)
            if (cand.fnId == fnId) {
                e = cand
            }
        }
        let n = Int64(e.codeLen)
        let out = Array<UInt8>(n, repeat: 0u8)
        var i: Int64 = 0
        while (i < n) {
            out[i] = unit.code[Int64(e.codeOff) + i]
            i = i + 1
        }
        out
    }

    /** `[kind, message]`。 */
    private static func err(src: String): Array<String> {
        var kind = ''
        var msg = ''
        try {
            let _ = Capture_test.compile(src)
        } catch (e: SourceCompileException) {
            kind = e.kind
            msg = e.message
        }
        [kind, msg]
    }
}
