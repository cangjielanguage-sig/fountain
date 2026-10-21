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

import std.collection.concurrent.ConcurrentHashMap
import std.env.atExit
import std.fs.{Directory, exists, remove}
import std.random.Random
import std.sync.{AtomicBool, AtomicInt64}

/**
 * 测试临时目录工厂。
 *
 * 所有用例的临时目录都放在 `/tmp/fmq_test_<namespace>/<name>-<token>`，
 * `token` 由进程内自增序号与随机数拼成，保证并发用例互不干扰；
 * 每个 namespace 的根目录在进程退出时（`atExit`）整棵删除，
 * 不再使用固定的 `/tmp/fmq_test_*` 路径互相覆盖。
 */
public class TestDirs {
    private static let seq = AtomicInt64(0)
    private static let registered = ConcurrentHashMap<String, AtomicBool>()

    /**
     * 返回一个已创建且进程退出时自动清理的临时目录。
     */
    public static func of(namespace: String, name: String): String {
        let root = "/tmp/fmq_test_${namespace}"
        let dir = "${root}/${name}-${token()}"
        Directory.create(dir, recursive: true)
        registerCleanup(root)
        return dir
    }

    /**
     * 只给 namespace，目录名用自增序号。
     */
    public static func unique(namespace: String): String {
        return of(namespace, "case")
    }

    /**
     * 删除目录树；不存在时静默返回。
     */
    public static func clean(path: String): Unit {
        if (exists(path)) {
            try {
                remove(path, recursive: true)
            } catch (_: Exception) {
            }
        }
    }

    /**
     * 删除整个 namespace 根目录；用例内部需要干净目录时调用。
     */
    public static func cleanNamespace(namespace: String): Unit {
        clean("/tmp/fmq_test_${namespace}")
    }

    private static func token(): String {
        let n = seq.fetchAdd(1)
        let r = Random()
        return "${r.nextUInt64()}-${n}"
    }

    private static func registerCleanup(root: String): Unit {
        let flag = AtomicBool(false)
        let previous = registered.addIfAbsent(root, flag)
        if (previous.isSome()) {
            return
        }
        atExit {
            clean(root)
        }
    }
}
