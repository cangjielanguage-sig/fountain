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
package fountain::f_dbd.exception

import std.unittest.*
import std.unittest.testmacro.*
import std.database.sql.SqlException
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_dbd.common.DbdErrorPayload

/**
 * 阶段 2 的**重导出验收**（设计 §4、开发计划阶段 2）：
 * 两条 import 路径拿到的是同一个类型，`DbdException` 可被 `SqlException` 统一 catch。
 */
@Test
public class ReexportTest {

    /** 从 `exception` 包构造、按 `SqlException` 捕获 —— import 路径对外不变。 */
    @TestCase
    public func usableFromExceptionPackage(): Unit {
        let e: SqlException = DbdException(CURSOR_STATE, 'cursor is gone')
        @Assert(e.message.contains('cursor is gone'), true)
        let caught = DbdException(TIMEOUT, 'timeout')
        @Assert(caught.code, TIMEOUT)
    }

    /** 两个包的类型身份相同：任意一个包构造的实例都能被另一个包的 `catch` 接住。 */
    @TestCase
    public func sameIdentityAcrossPackages(): Unit {
        let shared = DbdException(PROTOCOL, 'mismatch')
        @Assert(shared.code == PROTOCOL, true)
        @Assert(typeIdentity(shared), 'PROTOCOL')
    }

    /** payload 构造器在两个包下等价。 */
    @TestCase
    public func payloadConstructorWorksToo(): Unit {
        let payload = DbdErrorPayload(IO, 'broken pipe')
        let e = DbdException(payload)
        @Assert(e.code, IO)
        @Assert(e.message.contains('broken pipe'), true)
    }

    /** 用 `common` 的类型做实参，`exception` 的类做构造 —— 证明没有两份定义。 */
    private func typeIdentity(e: SqlException): String {
        try {
            throw e
        } catch (_: Exception) {
            ()
        }
        match (e) {
            case x: DbdException => x.code.toString()
            case _ => '-'
        }
    }
}
