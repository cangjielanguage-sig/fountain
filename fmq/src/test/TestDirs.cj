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
package fountain::fmq.test

import std.fs.{Directory, exists, remove}
import std.random.Random
import std.sync.AtomicInt64

/**
 * 测试临时目录工厂：同模块各包的用例共用的测试 helper。
 *
 * 目录位于 `/tmp/fmq_test_<namespace>/<name>-<token>`，`token` 由进程内自增序号与随机数拼成，
 * 并发用例互不干扰。可见性为 `protected`（模块内可见）：兄弟包可通过
 * `import fountain::fmq.test.TestDirs` 引用，模块外不可见；生产源集不引用它，因此 `fmq`
 * 可执行文件不链接该符号（仓颉的 `internal` 只覆盖当前包及子包，`fmq.test` 与 `fmq.queue`
 * 是兄弟包，所以这里必须用 `protected`）。
 *
 * 本类型不注册任何进程级钩子（如 `atExit`）；用例在 `@AfterAll` 中调用
 * `TestDirs.cleanNamespace` 回收整个 namespace。
 */
protected class TestDirs {
    private static let seq = AtomicInt64(0)

    /** 返回一个已创建且由调用方负责清理的临时目录。 */
    protected static func of(namespace: String, name: String): String {
        let dir = "/tmp/fmq_test_${namespace}/${name}-${token()}"
        Directory.create(dir, recursive: true)
        return dir
    }

    /** 删除整个 namespace 根目录；不存在时静默返回。 */
    protected static func cleanNamespace(namespace: String): Unit {
        let root = "/tmp/fmq_test_${namespace}"
        if (exists(root)) {
            try {
                remove(root, recursive: true)
            } catch (_: Exception) {
            }
        }
    }

    private static func token(): String {
        let n = seq.fetchAdd(1)
        let r = Random()
        return "${r.nextUInt64()}-${n}"
    }
}
