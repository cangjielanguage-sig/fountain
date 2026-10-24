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

/**
 * `@JsonRpc` 宏生成的注册代码从这里取注解。
 *
 * `T` 是 `@JsonRpc` 修饰的类；`funcName` 是类里的方法名（不含 topic 前缀）。
 */
public class JsonRpcRegister {
    /**
     * 读取 `T.funcName` 上的 `@JsonRpcMeta`。
     *
     * 没有注解时返回 `JsonRpcMeta('', '')`，对应“无描述、无超时”。
     */
    public static func getMeta<T>(funcName: String): JsonRpcMeta where T <: Object {
        for (function in TypeInfo.of<T>().getInstanceFunctions(funcName)) {
            match (function.findAnnotation<JsonRpcMeta>()) {
                case Some(meta) => return meta
                case _ => ()
            }
        }
        JsonRpcMeta('', '')
    }

    /** 从 bean 容器取实例（`@JsonRpc` 展开时给类加了 `@Bean`）。 */
    public static func instance<T>(): T where T <: Object {
        lookup<T>()
    }
}
