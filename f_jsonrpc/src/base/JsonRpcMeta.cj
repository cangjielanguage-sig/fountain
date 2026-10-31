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
package fountain::f_jsonrpc.base

import fountain::f_data.*

/**
 * 方法元数据注解。`timeout` 是 `Duration` 字符串（如 `'5s'`、`'1m30s'`）。
 *
 * 只对 `@JsonRpc` 修饰的类里的 public 实例方法生效。
 */
@Annotation[target: [MemberFunction]]
public class JsonRpcMeta {
    public const JsonRpcMeta(public let description: String, public let timeout: String) {}

    /** `timeout` 的 `Duration` 形式。 */
    public prop timeoutDuration: Duration {
        get() {
            Duration.parse(timeout)
        }
    }
}
