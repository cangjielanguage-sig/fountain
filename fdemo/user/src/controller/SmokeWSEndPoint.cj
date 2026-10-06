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
package fountain::user.controller

import fountain::f_mvc.*
import fountain::f_mvc.macros.*

/**
 * §3.2 / `MVC-13` 的**冒烟端点**：只用于验证「`GET + Upgrade: websocket` 能被路由到 `WS` 键、
 * 并完成协议升级（响应 `HTTP/1.1 101 Switching Protocols`）」。
 *
 * 故意**不声明任何 `@OnWS*` 处理器** —— `WSMeta<T>.generate()` 对无注解的实例函数直接 `continue`
 * （`f_mvc/src/WSMeta.cj:406-408`），因此这个端点只有一个空 meta，足够验证握手路由，
 * 不会引入任何业务逻辑。冒烟脚本见 `fdemo/ws_smoke.sh`。
 */
@WSEndPoint['/ws/smoke']
public class SmokeWSEndPoint {}
