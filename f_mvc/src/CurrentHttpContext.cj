/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_mvc

/**
 * 服务器处理http访问时，CurrentHttpContext.instance返回当前HttpContext
 */
public struct CurrentHttpContext {
    private static let context = ThreadLocal<HttpContext>()
    private init(){}
    static func set(ctx: HttpContext){
        context.set(ctx)
    }
    static func clear(): Unit {
        context.set(None<HttpContext>)
    }

    /**
     * 在当前线程建立请求上下文执行 `body`，结束后清理。
     *
     * 用于「handler 被派发到子线程」的场景（如 f_jsonrpc 的显式超时）：子线程默认没有
     * 父线程的 ThreadLocal，必须显式恢复。`ctx` 为 `None` 时只清理、不设置。
     */
    public static func scoped<T>(ctx: ?HttpContext, body: () -> T): T {
        match (ctx) {
            case Some(h) => context.set(h)
            case _ => ()
        }
        try {
            body()
        } finally {
            context.set(None<HttpContext>)
        }
    }

    public static prop instance: HttpContext {
        get(){
            context.get().getOrThrow()
        }
    }
}