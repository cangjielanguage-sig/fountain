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
package fountain::f_jsonrpc

import std.reflect.TypeInfo
import fountain::f_bean.lookup
import fountain::f_data.*

/** `@JsonRpcMeta` 解析后的结果。 */
public struct JsonRpcRegisteredMeta {
    public const JsonRpcRegisteredMeta(public let description: String, public let timeout: ?Duration) {}
}

/**
 * `@jsonrpc` 宏生成的注册代码从这里取注解。
 *
 * `paramCount` 用来在重载之间消歧；`-1` 表示取第一个同名方法。
 */
public class JsonRpcRegister {
    public static func getMeta<T>(fnName: String, paramCount!: Int64 = -1): JsonRpcRegisteredMeta where T <: Object {
        let typeInfo = TypeInfo.of<T>()
        for (function in typeInfo.getInstanceFunctions(fnName)) {
            let count = function.parameters.size
            // 反射的 parameters 可能把 this 也算进去
            if (paramCount >= 0 && count != paramCount && count - 1 != paramCount) {
                continue
            }
            match (function.findAnnotation<JsonRpcMeta>()) {
                case Some(meta) => return JsonRpcRegisteredMeta(meta.description, parseTimeout(meta.timeout, fnName))
                case _ => return JsonRpcRegisteredMeta('', None)
            }
        }
        JsonRpcRegisteredMeta('', None)
    }

    /** 从 bean 容器取实例（`@jsonrpc` 展开时给类加了 `@Bean`）。 */
    public static func instance<T>(): T where T <: Object {
        lookup<T>()
    }

    /** 把 `JsonRpcMeta.timeout` 字符串解析成 `Duration`；空串返回 `None`。 */
    public static func parseTimeout(text: String): ?Duration {
        parseTimeout(text, '')
    }

    static func parseTimeout(text: String, fnName: String): ?Duration {
        if (text.isEmpty()) {
            return None<Duration>
        }
        try {
            Some(Duration.parse(text))
        } catch (e: Exception) {
            throw IllegalArgumentException("invalid JsonRpcMeta timeout '${text}' on method '${fnName}': ${e.message}")
        }
    }
}
