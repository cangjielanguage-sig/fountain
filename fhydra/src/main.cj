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
package fountain::fhydra

import fountain::f_mvc.MVCStarter

/**
 * fhydra 可执行入口：自带 main，直接起 f_mvc HTTP 服务。
 *
 * 端口等参数读 `mvc_port` / `mvc_host` 环境变量（与 f_mvc 约定一致）。
 */
main(): Int64 {
    // 先初始化 MVC（装配 Server 与路由），再阻塞启动
    MVCStarter.initialize()
    MVCStarter.start()
    0
}
