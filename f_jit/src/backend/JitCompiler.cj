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
package fountain::f_jit.backend

import std.collection.ArrayList
import fountain::f_jit.bytecode.LoadedUnit

/** 整单元 JIT 产物：机器码 + 每函数在码流中的偏移/长度（按目录顺序）。 */
public class JitArtifacts {
    public let code: Array<UInt8>
    public let fnIds: Array<UInt32>
    public let offsets: Array<Int64>
    public let lengths: Array<Int64>

    init(code: Array<UInt8>, fnIds: Array<UInt32>, offsets: Array<Int64>, lengths: Array<Int64>) {
        this.code = code
        this.fnIds = fnIds
        this.offsets = offsets
        this.lengths = lengths
    }

    /** 按 `fnId` 找函数码流区间 `(offset, length)`；不存在 → None。 */
    public func entry(fnId: UInt32): ?(Int64, Int64) {
        var i = 0
        while (i < this.fnIds.size) {
            if (this.fnIds[i] == fnId) {
                return Some((this.offsets[i], this.lengths[i]))
            }
            i = i + 1
        }
        None
    }

    /** 按 `fnId` 取该函数的机器码切片。 */
    public func codeOf(fnId: UInt32): ?Array<UInt8> {
        match (this.entry(fnId)) {
            case Some((off, len)) => Some(this.code[off..(off + len)])
            case None => None
        }
    }
}

/**
 * S5.8 `JitCompiler` 最小编排：逐函数 lowering 到同一码流，记录入口偏移。
 *
 * AArch64 先行（用户裁定）；x86_64 路径后续补齐。跨函数 `CALL_FUNC` 的 fnTable
 * 回填尚未接入——当前支持无跨函数调用的单元（最小单元 `{=>1}` 已验证原生执行）。
 */
public class JitCompiler {
    public static func compileUnit(unit: LoadedUnit): ?JitArtifacts {
        let out = ArrayList<UInt8>()
        let ids = ArrayList<UInt32>()
        let offs = ArrayList<Int64>()
        let lens = ArrayList<Int64>()
        var i = 0
        while (i < unit.dir.size) {
            let fn = unit.dir.at(i)
            match (A64Compiler.compileFunction(unit, fn)) {
                case Some(b) =>
                    ids.add(fn.fnId)
                    offs.add(out.size)
                    lens.add(b.size)
                    for (x in b) {
                        out.add(x)
                    }
                case None => return None
            }
            i = i + 1
        }
        Some(JitArtifacts(out.toArray(), ids.toArray(), offs.toArray(), lens.toArray()))
    }
}
