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
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.SourceCompileException
import fountain::f_jit.base.SourcePos

/** Q3.4：名字解析顺序 `recursive → user helper → HostClosure(13) → 未定义`。 */
@Test
public class NameResolver_test {
    @TestCase
    public func recursiveWins(): Unit {
        let nr = NameResolver(NameResolver_test.snap(['f']), 'x')
        match (nr.resolve('recursive', SourcePos(1, 1), isHostClosure: true)) {
            case ResolvedCall.Recursive => @Assert(true, true)
            case _ => @Fail('recursive 未优先')
        }
    }

    @TestCase
    public func userHelperBeforeHostClosure(): Unit {
        let nr = NameResolver(NameResolver_test.snap(['f']), 'x')
        match (nr.resolve('f', SourcePos(1, 1))) {
            case ResolvedCall.UserHelper(slot) => @Assert(slot, 0u16)
            case _ => @Fail('user helper 未命中')
        }
    }

    @TestCase
    public func hostClosureBranch(): Unit {
        let nr = NameResolver(NameResolver_test.snap([]), 'x')
        match (nr.resolve('cb', SourcePos(1, 1), isHostClosure: true)) {
            case ResolvedCall.HostClosureCall => @Assert(true, true)
            case _ => @Fail('HostClosure 分支未命中')
        }
    }

    @TestCase
    public func undefinedIsRejected(): Unit {
        let nr = NameResolver(NameResolver_test.snap([]), 'x')
        @Assert(NameResolver_test.errKindOf(nr, 'ghost', false), DiagKind.UNREGISTERED_FUNCTION)
    }

    /** HostClosure 形参/局部与 user helper 同名 → 编译错误（消息含名字）。 */
    @TestCase
    public func nameClashIsRejected(): Unit {
        let nr = NameResolver(NameResolver_test.snap(['f']), 'x')
        var msg = ''
        var kind = ''
        try {
            let _ = nr.resolve('f', SourcePos(1, 1), isHostClosure: true)
        } catch (e: SourceCompileException) {
            msg = e.message
            kind = e.kind
        }
        @Assert(kind, DiagKind.SYNTAX_ERROR)
        @Assert(msg.contains('f'), true)
        @Assert(msg.contains('冲突'), true)
    }

    private static func snap(names: Array<String>): PredefinedSnapshot {
        var params = ArrayList<Array<UInt16>>()
        var rets = ArrayList<UInt16>()
        for (_ in names) {
            params.add([LocalType.I64])
            rets.add(LocalType.I64)
        }
        PredefinedSnapshot(names, params.toArray(), rets.toArray())
    }

    private static func errKindOf(nr: NameResolver, name: String, host: Bool): String {
        var got = ''
        try {
            let _ = nr.resolve(name, SourcePos(1, 1), isHostClosure: host)
        } catch (e: SourceCompileException) {
            got = e.kind
        }
        got
    }
}
