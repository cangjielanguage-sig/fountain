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
package fountain::f_dbd.driver

import std.time.MonoTime
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_dbd.exception.DbdException

/**
 * driver 包各用例共用的断言小工具（同包的 `*_test.cj` 之间共享，仅在测试构建里可见）。
 */

/** 执行 `body` 并回其抛出的 `DbdException.code`；没抛或抛的不是 `DbdException` 时返回 `INTERNAL`。 */
func codeOf<T>(body: () -> T): DbdErrorCode {
    try {
        body()
    } catch (e: DbdException) {
        return e.code
    } catch (_: Exception) {
        return DbdErrorCode.INTERNAL
    }
    DbdErrorCode.INTERNAL
}

/** 执行 `body` 并回其抛出的异常的可读形态；没抛返回 `''`（用于断言"没有异常冒出来"）。 */
func messageOf<T>(body: () -> T): String {
    try {
        body()
    } catch (e: Exception) {
        return e.toString()
    }
    ''
}

/** 等一件异步结果最多 `ms` 毫秒成立（握手、后台线程记录等场景），超时返回 `false`。 */
func waitUntil(condition: () -> Bool, ms!: Int64 = 3000): Bool {
    let deadline = MonoTime.now() + Duration.millisecond * ms
    while (MonoTime.now() < deadline) {
        if (condition()) {
            return true
        }
        sleep(Duration.millisecond * 5)
    }
    condition()
}
