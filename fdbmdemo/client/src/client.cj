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
package fountain::fdbmdemo_client

import std.env.exit
import fountain::f_app.{Initializer, InitializerCollection}
import fountain::f_log.LoggerFactory

/**
 * f_dbd 演示客户端入口：本模块是**动态链接库**（`output-type = "dynamic"`），
 * 由 fboot 启动：`./boot.sh demo` → `fboot run ./target --dylibPattern='(fdbmdemo_client)'`。
 *
 * 演示逻辑放在 [Initializer.start]（f_app 在主线程启动后另起线程调用），
 * 不放包级初始化器：包级初始化在 Init Image 阶段执行，其中的配置/网络异常会让动态库加载失败。
 *
 * 演示跑完调用 `std.env.exit(code)`：f_app 的主线程是 `sleep(Duration.Max)` 常驻，
 * 不主动退出的话命令行演示会挂住（这是演示程序与服务端程序的区别）。
 */
public struct FdbmDemoInitializer <: Initializer {
    private static let log = LoggerFactory.getLogger('fountain::fdbmdemo_client')

    static init() {
        InitializerCollection.register(FdbmDemoInitializer())
    }

    private init() {}

    public prop name: String {
        get() {
            'fountain::fdbmdemo_client'
        }
    }

    public prop dependencies: Array<String> {
        get() {
            []
        }
    }

    public func initialize(): Unit {
        // 无启动期动作：连接与全部演示都在 start() 里
    }

    public func start(): Unit {
        try {
            exit(runDemo())
        } catch (e: Exception) {
            log.error('fdbmdemo failed: ${e.message}', e)
            println('FAIL ${e.message}')
            println('提示：先执行 ./boot.sh driver && ./boot.sh init-db && ./boot.sh start')
            exit(1)
        }
    }
}
