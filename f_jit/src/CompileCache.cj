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
package fountain::f_jit

import std.collection.HashMap
import std.collection.HashSet
import std.sync.Mutex

/**
 * S6.7 编译缓存（§8 只编译一次）：进程级 static，状态 `Idle → Compiling → Ready/Failed`。
 *
 * 键 = 字节码/源码指纹的 128 位文本（`Fingerprint.bytes/source`，FNV-1a-128）。
 * 同键并发只有一个线程 `claim` 成功并执行管线；其余线程 `awaitReady` 等价共享结果
 * （失败亦共享）。命中后二次校验原字节由调用方（Pipeline）负责。
 */
protected class CompileCache {
    private static let mtx = Mutex()
    private static let ready = HashMap<String, JitFunction>()
    private static let compiling = HashSet<String>()
    private static let failures = HashMap<String, String>()
    private static var pipelineRuns: Int64 = 0

    /** 已就绪则直接返回；否则 None。 */
    public static func lookup(key: String): ?JitFunction {
        synchronized(mtx) {
            ready.get(key)
        }
    }

    /** 尝试认领编译权：`Idle` → true；`Compiling/Ready/Failed` → false。 */
    public static func claim(key: String): Bool {
        synchronized(mtx) {
            if (ready.contains(key) || compiling.contains(key) || failures.contains(key)) {
                return false
            }
            compiling.add(key)
            pipelineRuns = pipelineRuns + 1
            true
        }
    }

    /** 管线成功：发布结果并唤醒等待者。 */
    public static func finish(key: String, fn: JitFunction): Unit {
        synchronized(mtx) {
            fn.bindCacheKey(key)
            ready[key] = fn
            compiling.remove(key)
            failures.remove(key)
        }
    }

    /** 管线失败：等价共享错误文本。 */
    public static func fail(key: String, message: String): Unit {
        synchronized(mtx) {
            failures[key] = message
            compiling.remove(key)
        }
    }

    /** 等待状态离开 `Compiling`；返回就绪值（失败/未注册 → None）。 */
    public static func awaitReady(key: String): ?JitFunction {
        var spins = 0
        while (spins < 5000000) {
            let done = synchronized(mtx) {
                !compiling.contains(key)
            }
            if (done) {
                return synchronized(mtx) {
                    ready.get(key)
                }
            }
            spins = spins + 1
        }
        None
    }

    /** 失败文本（无 → None）。 */
    public static func failureOf(key: String): ?String {
        synchronized(mtx) {
            failures.get(key)
        }
    }

    /** 移除（卸载/缓存失效）。 */
    public static func remove(key: String): Unit {
        synchronized(mtx) {
            ready.remove(key)
            failures.remove(key)
            compiling.remove(key)
        }
    }

    /** 诊断：管线执行次数（同键并发应恰好 1）。 */
    public static func runs(): Int64 {
        synchronized(mtx) {
            pipelineRuns
        }
    }

    /** 测试用：清空。 */
    public static func reset(): Unit {
        synchronized(mtx) {
            ready.clear()
            failures.clear()
            compiling.clear()
            pipelineRuns = 0
        }
    }
}
