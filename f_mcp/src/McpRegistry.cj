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
package fountain::f_mcp

import std.sync.Mutex

/** 进程内默认 MCP server。应用在 static init 阶段用 `configure` 注册工具 / 资源。 */
public class McpRegistry {
    private static let mutex = Mutex()
    private static let builder = McpServer.builder()
    private static var built: ?McpServer = None

    public static func configure(configure: (McpServerBuilder) -> Unit): Unit {
        synchronized(mutex) {
            if (built.isSome()) {
                throw McpException(McpProtocol.INTERNAL_ERROR,
                    'McpRegistry is already initialized; configure before first server()')
            }
            configure(builder)
        }
    }

    public static func server(): McpServer {
        synchronized(mutex) {
            match (built) {
                case Some(server) => server
                case _ =>
                    let server = builder.build()
                    built = Some(server)
                    server
            }
        }
    }
}
