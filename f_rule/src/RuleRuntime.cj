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
package fountain::f_rule

import std.sync.Mutex
import fountain::f_jit.Compiler
import fountain::f_log.LoggerFactory

/**
 * `f_rule` 进程级运行态：共享 `Compiler` 与全局配置。
 *
 * `f_jit` 的编译缓存是进程级静态的，`f_egraph` 的 `ClosureTask` 与 `f_rule` 的 `JitExpression`
 * 只有共用同一个 `Compiler` 才能命中同一份缓存。因此应用必须按
 * 「`f_jit` 注册类型 → `RuleRuntime.initCompiler(c)` → `RuleSet.build()`」的顺序初始化。
 *
 * 未注入时惰性创建一个默认 `Compiler`，并在**首次**创建时打印一次 WARN：默认实例不知道应用
 * 注册了哪些类型，脚本条件可能在构建期报 `SCRIPT_COMPILE`，所以这条告警不能沉默，也不能刷屏。
 */
public class RuleRuntime {
    private static let mtx = Mutex()
    private static let log = LoggerFactory.getLogger<RuleRuntime>()
    private static var shared: ?Compiler = None
    private static var lazyWarned = false
    private static var lazyWarnings: Int64 = 0

    private init() {}

    /**
     * 注入应用侧共享编译器。
     *
     * 可重复调用（后注入者生效），例如测试里替换实例；不会重置惰性告警计数。
     */
    public static func initCompiler(compiler: Compiler): Unit {
        synchronized(mtx) {
            shared = compiler
        }
    }

    /** 当前共享编译器；未注入时惰性创建默认实例（首次创建告警一次）。 */
    public static func compiler(): Compiler {
        synchronized(mtx) {
            match (shared) {
                case Some(c) => c
                case None =>
                    let created = Compiler()
                    shared = created
                    if (!lazyWarned) {
                        lazyWarned = true
                        lazyWarnings += 1
                        log.warn(
                            "f_rule 未注入共享 Compiler（RuleRuntime.initCompiler），已惰性创建默认实例；" +
                            "应用注册的类型可能不可见，脚本条件将在构建期报 SCRIPT_COMPILE"
                        )
                    }
                    created
            }
        }
    }

    /** 测试观测用：惰性路径实际发出 WARN 的次数（默认 `internal` 可见性，不对外）。 */
    static func lazyWarningCount(): Int64 {
        synchronized(mtx) {
            lazyWarnings
        }
    }

    /** 测试用：回到"未初始化"状态，保证用例之间互不影响。 */
    static func resetForTest(): Unit {
        synchronized(mtx) {
            shared = None
            lazyWarned = false
            lazyWarnings = 0
        }
    }
}
