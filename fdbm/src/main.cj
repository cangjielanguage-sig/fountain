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
package fountain::fdbm

import fountain::f_log.LoggerFactory
import fountain::fdbm.config.FdbmSettings
import fountain::fdbm.exception.FdbmException
import fountain::fdbm.server.FdbmServer

private let logger = LoggerFactory.getLogger('fountain::fdbm')

/**
 * 进程入口（设计 §10.5）：**没有子命令**。`cjpm install` 后命令行直接执行 `fdbm` 即启动服务。
 *
 * 启动自检失败 → 记 ERROR 并返回 1（显式退出码，不依赖未捕获异常）。
 */
main(): Int64 {
    try {
        FdbmServer(FdbmSettings.load()).start()
        return 0
    } catch (e: FdbmException) {
        logger.error('fdbm failed to start: ${e.code}: ${e.message}', e)
        // 启动失败时异步 appender 可能来不及 flush；同步写 stderr 保证错误可见（T08）
        eprintln('ERROR: fdbm failed to start: ${e.code}: ${e.message}')
        return 1
    } catch (e: Exception) {
        logger.error('fdbm failed to start: ${e.message}', e)
        eprintln('ERROR: fdbm failed to start: ${e.message}')
        return 1
    }
}
