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
package fountain::f_dbd.common

import std.unittest.*
import std.unittest.testmacro.*
import std.database.sql.SqlException

/** 阶段 2 `DbdException`（设计 §4，实现体在 `common`） */
@Test
public class DbdExceptionTest {

    /**
     * `let e: SqlException = DbdException(...)` 必须能直接赋值 —— 对外统一异常类型。
     *
     * 注意 `SqlException.message` 会自行拼上 `, errorCode: N.`（`SqlState` 非空时还会拼 `SqlState`），
     * 故用 `contains` 断言原始消息而不是等值断言。
     */
    @TestCase
    public func isAssignableToSqlException(): Unit {
        let e: SqlException = DbdException(CURSOR_STATE, 'no cursor')
        @Assert(e.message.contains('no cursor'), true)
        @Assert(e.errorCode, CURSOR_STATE.value)
    }

    /** 能被 `catch (e: SqlException)` 接住，且 `code` 保真。 */
    @TestCase
    public func caughtAsSqlExceptionKeepsCode(): Unit {
        let caught = try {
            throw DbdException(TIMEOUT, 'timeout')
        } catch (e: SqlException) {
            e.message
        }
        @Assert(caught.contains('timeout'), true)
        let thrown = DbdException(TX_STATE, 'not in tx')
        @Assert(thrown.code, TX_STATE)
        @Assert(thrown.code == TX_STATE, true)
    }

    /** `sqlState` / `cause` 保真；默认分别为 `''` 与 `None`。 */
    @TestCase
    public func sqlStateAndCauseArePreserved(): Unit {
        let bare = DbdException(IO, 'io error')
        @Assert(bare.sqlState, '')
        @Assert(bare.cause.isNone(), true)
        let original = Exception('root cause')
        let wrapped = DbdException(PROTOCOL, 'bad payload', sqlState: 'HY000', cause: original)
        @Assert(wrapped.sqlState, 'HY000')
        @Assert(wrapped.cause.isSome(), true)
        @Assert(wrapped.cause.getOrThrow().message, 'root cause')
    }

    /** `SqlException.errorCode` 读到的就是 `code` 的线上数值（不用二次查表）。 */
    @TestCase
    public func errorCodeCarriesWireValue(): Unit {
        @Assert(DbdException(CONVERSION, 'x').errorCode, CONVERSION.value)
        @Assert(DbdException(CACHE, 'x').errorCode, 12i64)
    }

    /** `payload` 构造器：`message` / `sqlState` / `code` 一致。 */
    @TestCase
    public func payloadConstructorRestoresFields(): Unit {
        let payload = DbdErrorPayload(CURSOR_STATE, 'cursor closed', sqlState: '24000')
        let e = DbdException(payload)
        @Assert(e.code, CURSOR_STATE)
        @Assert(e.message.contains('cursor closed'), true)
        @Assert(e.message.contains('24000'), true)
        @Assert(e.sqlState, '24000')
        @Assert(e.errorCode, CURSOR_STATE.value)
    }

    /** 线上的未知 code（`99`）在这一层被兜成 `INTERNAL`。 */
    @TestCase
    public func payloadWithUnknownCodeFallsBackToInternal(): Unit {
        let payload = DbdErrorPayload(CACHE, 'cache error')
        payload.code = 99
        @Assert(DbdException(payload).code, INTERNAL)
    }

    /** payload 构造器同样可以带 `cause`。 */
    @TestCase
    public func payloadConstructorKeepsCause(): Unit {
        let payload = DbdErrorPayload(DB_ERROR, 'physical failure')
        let root = Exception('deadlock')
        @Assert(DbdException(payload, cause: root).cause.getOrThrow().message, 'deadlock')
    }
}
