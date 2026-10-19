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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.LocalType
import fountain::f_jit.test.ReflectUser
import fountain::f_jit.test.TCase

/**
 * GAP-05 乙的注册面：签名登记、幂等、查找、适配器调用。
 *
 * 这层验证的是「签名在宿主编译期固定」这一前提——适配器里的 `f as (ReflectUser) -> Int64`
 * 与 `a[0] as ReflectUser` 都由编译器静态检查，运行期不再做任何类型分派。
 */
@Test
public class HostSignature_test {
    private static func registerUserToI64(): Int32 {
        JitHost.registerSignature<(ReflectUser) -> Int64>(
            display: '(ReflectUser) -> Int64',
            params: [LocalType.HOST_OBJECT],
            paramNames: ['ReflectUser'],
            ret: LocalType.I64,
            retName: '',
            adapter: { f, a =>
                if (let g: (ReflectUser) -> Int64 <- f) {
                    let u = match (a[0]) {
                        case x: ReflectUser => x
                        case _ => throw Exception('实参不是 ReflectUser')
                    }
                    g(u)
                } else {
                    throw Exception('宿主函数不匹配 (ReflectUser) -> Int64')
                }
            })
    }

    @TestCase
    public func registerAndFindById(): Unit {
        SignatureRegistry.resetForTest()
        let id = HostSignature_test.registerUserToI64()
        @Assert(TCase.hit('T30/signature-register', id == 0), true)
        let found = JitHost.findSignature([LocalType.HOST_OBJECT], ['ReflectUser'], LocalType.I64, '')
        @Assert(TCase.hit('T30/signature-find', found == Some(Int32(0))), true)
        SignatureRegistry.resetForTest()
    }

    @TestCase
    public func sameShapeIsIdempotent(): Unit {
        SignatureRegistry.resetForTest()
        let a = HostSignature_test.registerUserToI64()
        let b = HostSignature_test.registerUserToI64()
        @Assert(TCase.hit('T30/signature-idempotent', a == b), true)
        @Assert(JitHost.signatureCount(), 1)
        SignatureRegistry.resetForTest()
    }

    @TestCase
    public func unknownShapeIsNone(): Unit {
        SignatureRegistry.resetForTest()
        let _ = HostSignature_test.registerUserToI64()
        // 同为 14 参数但返回 String ⇒ 结构不同，不应命中
        let miss = JitHost.findSignature([LocalType.HOST_OBJECT], ['ReflectUser'], LocalType.STRING, '')
        @Assert(TCase.hit('T30/signature-shape-strict', miss.isNone()), true)
        // 元数不同 ⇒ 也不命中
        let miss2 = JitHost.findSignature([], [], LocalType.I64, '')
        @Assert(miss2.isNone(), true)
        SignatureRegistry.resetForTest()
    }

    /** `(ReflectUser) -> Int64` 与 `(ReflectAdmin) -> Int64` 类别码相同，但必须是不同签名。 */
    @TestCase
    public func differentClassNamesGetDifferentIds(): Unit {
        SignatureRegistry.resetForTest()
        let a = HostSignature_test.registerUserToI64()
        let b = JitHost.registerSignature<(ReflectUser) -> Int64>(
            display: '(ReflectAdmin) -> Int64',
            params: [LocalType.HOST_OBJECT],
            paramNames: ['ReflectAdmin'],
            ret: LocalType.I64,
            retName: '',
            adapter: { f, a2 =>
                if (let g: (ReflectUser) -> Int64 <- f) {
                    let u = match (a2[0]) {
                        case x: ReflectUser => x
                        case _ => throw Exception('实参不是 ReflectUser')
                    }
                    g(u)
                } else {
                    throw Exception('宿主函数不匹配')
                }
            })
        @Assert(TCase.hit('T30/signature-class-name-distinguishes', a != b), true)
        @Assert(JitHost.signatureCount(), 2)
        @Assert(JitHost.findSignature([LocalType.HOST_OBJECT], ['ReflectAdmin'], LocalType.I64, ''),
            Some(b))
        SignatureRegistry.resetForTest()
    }

    @TestCase
    public func adapterInvokesHostFunction(): Unit {
        SignatureRegistry.resetForTest()
        let _ = HostSignature_test.registerUserToI64()
        let sig = match (JitHost.findSignature([LocalType.HOST_OBJECT], ['ReflectUser'], LocalType.I64, '')
            .flatMap({ id => SignatureRegistry.get(id) })) {
            case Some(s) => s
            case None => @Fail('签名未登记')
        }
        let host: (ReflectUser) -> Int64 = { u => u.id + 7 }
        let args: Array<Any> = [ReflectUser('bob')]
        let got = match (sig.adapter(host, args)) {
            case x: Int64 => x
            case _ => -1
        }
        @Assert(TCase.hit('T30/signature-adapter', got == 7), true)
        SignatureRegistry.resetForTest()
    }
}
