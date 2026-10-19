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

import fountain::f_base.BaseException
import fountain::f_dbd.common.DbdErrorCode

/**
 * fdbm 内部统一异常（设计 §4）：携带 `f_dbd` 的错误码，`server` 层据此回 `DbdErrorPayload`。
 *
 * 物理库抛出的 `SqlException` 由调用方包成 `FdbmException(DB_ERROR, ..., caused)`，并透传 `sqlState`。
 */
public class FdbmException <: BaseException {
    private let code_: DbdErrorCode

    public init(code: DbdErrorCode, message: String) {
        super(message)
        this.code_ = code
    }

    public init(code: DbdErrorCode, message: String, caused: Exception) {
        super(message, caused)
        this.code_ = code
    }

    public init(code: DbdErrorCode, caused: Exception) {
        super(caused)
        this.code_ = code
    }

    public prop code: DbdErrorCode {
        get() {
            code_
        }
    }
}
