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

import std.database.sql.SqlException

/**
 * f_dbd 对外抛出的唯一异常类型（设计 §4）。
 *
 * - 继承 `SqlException` ⇒ 应用既能 `catch (e: SqlException)` 统一兜住，也能按 `code` 细分处理；
 * - `code` 是细粒度错误码（`DbdErrorCode`），同时作为 `SqlException` 的第三构造参数传进去，
 *   因此 `SqlException.errorCode` 读到的就是它的线上数值；
 * - `cause` 保留原始异常（网络 / 编解码 / 物理库），便于排查。
 *
 * **为什么实现体在 `common` 而不是 `exception`**：`QueryResultImpl`（§3.10）与 `DbdInputStream`
 * （§3.11）都在 common 包且要抛本类，而本类需要 common 的 `DbdErrorCode` / `DbdErrorPayload`；
 * 若类留在 `exception` 包，就会形成 `common → exception → common` 的包级循环（cjpm 直接报
 * `cyclic dependency`）。故实现体放这里，`fountain::f_dbd.exception` 只做 `public import` 重导出，
 * 对调用方而言 import 路径与类型身份都不变。
 */
public class DbdException <: SqlException {
    /** 细粒度错误码。 */
    public prop code: DbdErrorCode {
        get() {
            code_
        }
    }
    /** 原始异常（网络 / 编解码 / 物理库），默认 `None`。 */
    public prop cause: ?Exception {
        get() {
            cause_
        }
    }

    private let code_: DbdErrorCode
    private let cause_: ?Exception

    public init(code: DbdErrorCode, message: String, sqlState!: String = '',
        cause!: ?Exception = None) {
        super(message, sqlState, code.value)
        this.code_ = code
        this.cause_ = cause
    }

    /** 从对端回的 `DbdErrorPayload` 还原成异常；未知 code 由 `errorCode()` 兜成 `INTERNAL`。 */
    public init(payload: DbdErrorPayload, cause!: ?Exception = None) {
        super(payload.message, payload.sqlState, payload.errorCode().value)
        this.code_ = payload.errorCode()
        this.cause_ = cause
    }
}
