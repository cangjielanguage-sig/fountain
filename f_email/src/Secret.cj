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
package fountain::f_email

/**
 * 凭据包装。
 *
 * 不提供任何直接取值方法：调用方只能在 [use] 的回调里看到原文，回调返回后引用即可被回收。
 * `toString()` 恒为 `<redacted>`，因此把 `Secret` 拼进日志、异常消息或协议跟踪都不会泄露密码。
 *
 * ```
 * let secret = Secret.of(password)
 * secret.use { p => authenticate(p) }
 * ```
 *
 * 注意：Cangjie 的 `String` 不可变且无零化接口，所以"回调返回后明文仍在内存"这件事无法在
 * 语言层彻底解决；本类型能保证的是**不把它交给任何公开 API 或日志**。
 */
public class Secret <: ToString {
    private let value: String

    private init(value: String) {
        this.value = value
    }

    public static func of(value: String): Secret {
        Secret(value)
    }

    /** 在回调内使用明文；返回值透传。 */
    public func use<T>(action: (String) -> T): T {
        action(value)
    }

    public func toString(): String {
        "<redacted>"
    }
}
