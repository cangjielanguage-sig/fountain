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
package fountain::f_store

import std.fs.*
import std.env.atExit

/**
 * 共享测试工具：清理 f_store 用例在 `/tmp` 下的临时目录（见 .autocode/bugs/bug-archived-on-20261004.md 7.14）。
 *
 * 背景：`Store`/`WAL` 底层的 `SegmentedLog` 按 `maxFileSize`（默认 **64MB**）fallocate 预分配 + mmap，
 * 一个用例目录动辄几十 MB；而各用例只在自己**开始时**清自己的目录（`getTestDir()` 里那句 start-clean），
 * 结束时——尤其是中途失败时——并不管 ⇒ 跑一次全量用例就往 `/tmp` 堆 ~4GB（实测 3.9~4.1GB）。
 *
 * 做法：`/tmp` 下以 `f_store` 开头的顶层目录都是本模块用例的临时数据，统一在
 * 「包初始化（测试用例开始前）」与「进程退出」各清一次 ⇒ 即使某次运行失败也不会累积。
 * 需要保留现场排查时，把 `KEEP_TEST_TMP_DIRS` 改成 true 再跑。
 *
 * 注意：文件名以 `_test.cj` 结尾 ⇒ 只在测试构建里编译，不进库产物。
 */

/** `/tmp` 下属于本模块用例的目录前缀（新增用例目录沿用这个前缀即可被自动清理）。 */
private const TEST_TMP_DIR_PREFIX = '/tmp/f_store'

/** 排查问题时改成 true：跳过清理，保留现场。 */
private const KEEP_TEST_TMP_DIRS = false

/** 删除 `/tmp` 下所有本模块用例的临时目录（`walk` 非递归，只处理 `/tmp` 的顶层项）。 */
func cleanStoreTestTmpDirs(): Unit {
    if (KEEP_TEST_TMP_DIRS) {
        return
    }
    try {
        Directory.walk('/tmp') { fi: FileInfo =>
            let path = fi.path.toString()
            if (fi.isDirectory() && path.startsWith(TEST_TMP_DIR_PREFIX)) {
                try {
                    remove(path, recursive: true)
                } catch (_: Exception) {
                    // 单个目录删不掉（例如仍被其它进程占用）不影响用例结果
                }
            }
            true
        }
    } catch (_: Exception) {
        // /tmp 不可遍历时静默跳过
    }
}

/** 测试开始前清一次（清掉上次运行的残留），退出时再清一次（清掉本次运行产生的）。 */
let _STORE_TEST_TMP_CLEANUP = {
    =>
        cleanStoreTestTmpDirs()
        atExit { cleanStoreTestTmpDirs() }
        0
}()
