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

import std.io.ByteBuffer
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_codec.default.DefaultCodec

/** Step 1.6 `DbdErrorCode` / `DbdErrorPayload`（设计 §3.8） */
@Test
public class ErrorCodeTest {

    @TestCase
    public func errorCodeValuesAreUniqueAndStable(): Unit {
        let all: Array<DbdErrorCode> = [INTERNAL, PROTOCOL, SQL_SYNTAX, UNSUPPORTED_SQL, ROUTE_FAILED,
            PARTITION_CONFIG, NO_DRIVER, CURSOR_STATE, TX_STATE, DB_ERROR, TIMEOUT, CONFIG, CACHE, IO,
            ID_GENERATOR, CONVERSION]
        let expected: Array<Int64> = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
        @Assert(all.size, expected.size)
        for (i in 0..all.size) {
            @Assert(all[i].value, expected[i])
        }
    }

    @TestCase
    public func errorCodeToStringReturnsName(): Unit {
        @Assert(CURSOR_STATE.toString(), 'CURSOR_STATE')
        @Assert(CONVERSION.toString(), 'CONVERSION')
    }

    @TestCase
    public func errorPayloadDefaults(): Unit {
        let p = DbdErrorPayload()
        @Assert(p.code, 0)
        @Assert(p.sqlState, '')
        @Assert(p.message, '')
    }

    @TestCase
    public func errorPayloadFullConstructor(): Unit {
        let p = DbdErrorPayload(CURSOR_STATE, 'no cursor', sqlState: '25000')
        @Assert(p.code, CURSOR_STATE.value)
        @Assert(p.message, 'no cursor')
        @Assert(p.sqlState, '25000')
        @Assert(p.errorCode(), CURSOR_STATE)
    }

    @TestCase
    public func errorPayloadSqlStateDefaultsToEmpty(): Unit {
        let p = DbdErrorPayload(TIMEOUT, 'timeout')
        @Assert(p.sqlState, '')
    }

    /** 未知 code（越界值）→ `INTERNAL`。 */
    @TestCase
    public func errorCodeFallsBackToInternal(): Unit {
        let p = DbdErrorPayload()
        p.code = 9999
        @Assert(p.errorCode(), INTERNAL)
    }

    @TestCase
    public func errorPayloadRoundTrip(): Unit {
        let buf = ByteBuffer()
        let p = DbdErrorPayload(DB_ERROR, 'boom', sqlState: '42P01')
        DefaultCodec().encode(p).finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let decoded = DefaultCodec().decode<DbdErrorPayload>(buf).getOrThrow()
        @Assert(decoded.errorCode(), DB_ERROR)
        @Assert(decoded.message, 'boom')
        @Assert(decoded.sqlState, '42P01')
    }
}
