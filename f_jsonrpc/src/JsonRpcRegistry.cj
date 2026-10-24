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

/** 进程内默认端点的方法注册表。应用在 static init 阶段调 `register`。 */
public class JsonRpcRegistry {
    private static let defaultServer = JsonRpcServer.builder().endpoint(JsonRpcProtocol.PATH).build()

    public static func server(): JsonRpcServer {
        defaultServer
    }

    public static func register(meta: JsonRpcMethodMeta): Unit {
        defaultServer.addMethod(meta)
    }

    /**
     * 读取 `T.fnName` 上指定参数类型的重载的 `@JsonRpcMeta`。
     *
     * `argTypes` 是方法声明里的参数类型（不含 `this`）。没有匹配的重载或注解时，
     * 返回 `JsonRpcMeta('', '500ms')`：无描述，超时默认 500ms。
     */
    public static func getMeta<T>(fnName: String, argTypes: Array<TypeInfo>): JsonRpcMeta where T <: Object {
        for (function in TypeInfo.of<T>().getInstanceFunctions(fnName)) {
            let params = function.parameters
            // 反射的实例方法参数可能把 this 放在第 0 位。
            let offset = if (params.size == argTypes.size + 1) { 1 } else { 0 }
            if (params.size - offset != argTypes.size) {
                continue
            }
            var matched = true
            var i = 0
            while (i < argTypes.size) {
                if (params[offset + i].typeInfo != argTypes[i]) {
                    matched = false
                    break
                }
                i++
            }
            if (!matched) {
                continue
            }
            match (function.findAnnotation<JsonRpcMeta>()) {
                case Some(meta) => return meta
                case _ => return JsonRpcMeta('', '500ms')
            }
        }
        JsonRpcMeta('', '500ms')
    }

    /** 从 bean 容器取实例（`@JsonRpc` 展开时给类加了 `@Bean`）。 */
    public static func instance<T>(): T where T <: Object {
        lookup<T>()
    }
}
