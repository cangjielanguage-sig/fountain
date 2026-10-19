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
package fountain::fdbm.exception

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_base.BaseException
import fountain::f_dbd.common.DbdErrorCode

/** 阶段 2 `FdbmException`：错误码、消息与 cause 保真。 */
@Test
public class FdbmExceptionTest {

    @TestCase
    public func carriesCodeAndMessage(): Unit {
        let e = FdbmException(DbdErrorCode.CONFIG, 'bad config')
        @Assert(e.code, DbdErrorCode.CONFIG)
        @Assert(e.message, 'bad config')
        let base: BaseException = e
        @Assert(base.message, 'bad config')
    }

    @TestCase
    public func carriesCause(): Unit {
        let cause = Exception('boom')
        let withMessage = FdbmException(DbdErrorCode.DB_ERROR, 'query failed', cause)
        @Assert(withMessage.code, DbdErrorCode.DB_ERROR)
        @Assert(withMessage.message, 'query failed')
        @Assert(withMessage.causedBy.isSome(), true)

        let fromCause = FdbmException(DbdErrorCode.IO, cause)
        @Assert(fromCause.code, DbdErrorCode.IO)
        @Assert(fromCause.causedBy.isSome(), true)
    }
}
