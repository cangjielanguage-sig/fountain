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
package fountain::f_jit

import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.SourceCompileException
import fountain::f_jit.bytecode.FbcReader
import fountain::f_jit.bytecode.Fingerprint
import fountain::f_jit.bytecode.LoadedUnit
import fountain::f_jit.compiler.SourceCompiler
import fountain::f_jit.runtime.Interp
import fountain::f_jit.runtime.JitContext

/**
 * S6.8 源码管线（§8）：`compile(source)` 四步——源码 → 字节码 → 执行器 → `JitFunction`。
 *
 * 进程级去重键 = 源码 FNV-1a-128；同源复用同一 `JitFunction`（`CompileCache`）。
 * 失败在 `compile` 时刻抛出（`SourceCompileException`），不进入运行期错误槽。
 */
public class CompilePipeline {
    public static func runSource(source: String, c: Compiler): JitFunction {
        let key = 'src/${Fingerprint.fnv1a128(source)}'
        match (CompileCache.lookup(key)) {
            case Some(f) => return f
            case None => ()
        }
        if (CompileCache.claim(key)) {
            try {
                let cu = SourceCompiler(c.snapshot(), DummyDiagnosticsSink()).compile(source)
                let unit = FbcReader.load(cu.raw)
                let fn = CompilePipeline.makeFunction(unit, cu.entryFn)
                CompileCache.finish(key, fn)
                return fn
            } catch (e: Exception) {
                CompileCache.fail(key, e.message)
                throw e
            }
        }
        match (CompileCache.awaitReady(key)) {
            case Some(f) => f
            case None =>
                let msg = match (CompileCache.failureOf(key)) {
                    case Some(m) => m
                    case None => '编译失败'
                }
                throw SourceCompileException('CompileFailed', 0, 0, 0, '', msg)
        }
    }

    /** 字节码形态执行器（机器码装载由 S6.9/桥接管，接口不变）。 */
    private static func makeFunction(unit: LoadedUnit, entryFn: UInt32): JitFunction {
        let idx = CompilePipeline.indexOf(unit, entryFn)
        let e = unit.dir.get(entryFn)
        let types = unit.types[idx]
        let params = Array<UInt16>(Int64(e.nargs), repeat: 0)
        var i = 0
        while (i < Int64(e.nargs)) {
            params[i] = UInt16(types.get(i))
            i = i + 1
        }
        let body: (JitContext, Array<Int64>) -> Int64 = { ctx, cells =>
            Interp(unit).run(entryFn, cells, ctx)
        }
        JitFunction(Int64(e.nargs), e.retType, params, body, body, '')
    }

    private static func indexOf(unit: LoadedUnit, fnId: UInt32): Int64 {
        var i = 0
        while (i < unit.dir.size) {
            if (unit.dir.at(i).fnId == fnId) {
                return i
            }
            i = i + 1
        }
        0
    }
}
