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
package fountain::f_rule.exception

import fountain::f_base.BaseException

/**
 * `f_rule` 抛出的唯一异常类型（`doc/01-architecture.md` §6）。
 *
 * 继承 `fountain::f_base.BaseException`，与仓库其他模块统一捕获口径；原因链通过基类的
 * `causedBy` 透传，不额外声明字段。
 */
public class RuleException <: BaseException {
    /** 错误分类；调用方按此分支处理，不解析 `message`。 */
    public let code: RuleErrorCode

    /** 只给错误码：`message` 取码名，日志里至少能看到分类。 */
    public init(code: RuleErrorCode) {
        this(code, code.toString())
    }

    public init(code: RuleErrorCode, message: String) {
        super(message)
        this.code = code
    }

    public init(code: RuleErrorCode, caused: Exception) {
        this(code, code.toString(), caused)
    }

    public init(code: RuleErrorCode, message: String, caused: Exception) {
        super(message, caused)
        this.code = code
    }
}
