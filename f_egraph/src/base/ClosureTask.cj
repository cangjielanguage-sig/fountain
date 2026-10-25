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
package fountain::f_egraph.base

// 宏导入是文件级的（`design.md` §12.1）。
import fountain::f_jit.macros.*

/**
 * 由 f_jit 源码生成任务体的 [Task] 实现（`design.md` §7.1）。
 *
 * - 宿主可直接注入闭包（`body`），也可以走 [compile] 把「任务体语句序列」编译成执行体；
 * - `compile` 的 `exec` 是**语句序列**，参数名固定为 `e`，返回值必须是 `Event`；
 * - 编译错误与运行期错误原样上抛（保留 f_jit 的站点与错误码），不包装成 `GraphException`。
 */
@JitBind
public class ClosureTask <: Task {
    private static let compilerMtx = Mutex()
    private static var sharedCompiler: ?Compiler = None

    private let name_: String
    private let acceptable_: Array<String>
    private let producing_: Array<String>
    private let body_: (Event) -> Event

    public init(name: String, acceptableEvents: Array<String>, producingEvents: Array<String>,
        body: (Event) -> Event) {
        if (name.trimAscii().isEmpty()) {
            throw GraphException("ClosureTask name must not be blank")
        }
        if (acceptableEvents.size == 0) {
            throw GraphException("ClosureTask acceptableEvents must not be empty")
        }
        if (producingEvents.size == 0) {
            throw GraphException("ClosureTask producingEvents must not be empty")
        }
        this.name_ = name
        this.acceptable_ = acceptableEvents
        this.producing_ = producingEvents
        this.body_ = body
    }

    /** 宿主注入编译器：所有 `compile` 共用同一实例（命中 `CompileCache`）。 */
    @IgnoreJitBinding
    public static func initCompiler(compiler: Compiler): Unit {
        synchronized(ClosureTask.compilerMtx) {
            ClosureTask.sharedCompiler = compiler
        }
    }

    /** 测试专用：清空共享编译器，便于验证惰性创建路径。 */
    internal static func resetCompilerForTest(): Unit {
        synchronized(ClosureTask.compilerMtx) {
            ClosureTask.sharedCompiler = None
        }
    }

    private static func ensureCompiler(): Compiler {
        synchronized(ClosureTask.compilerMtx) {
            match (ClosureTask.sharedCompiler) {
                case Some(c) => c
                case None =>
                    let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
                    JitHostRegistry.configure(c)
                    ClosureTask.sharedCompiler = c
                    c
            }
        }
    }

    /**
     * 把任务体语句序列编译成执行体。
     *
     * 列表形参用 `ArrayList<Any>`：f_jit 的 LIST 字面量类型码是 `10`，但运行时形态恒为
     * `ArrayList<Any>`，且仓颉泛型不协变——`ArrayList<String>` 形参从脚本调用必然
     * `typeMismatch`。因此这里逐元素校验 `is String`，非字符串抛 `GraphException`
     * （`design.md` §7.1）。
     */
    public static func compile(name: String, acceptableEvents: ArrayList<Any>,
        producingEvents: ArrayList<Any>, exec: String): ClosureTask {
        if (name.trimAscii().isEmpty()) {
            throw GraphException("ClosureTask name must not be blank")
        }
        let acceptable = ClosureTask.stringEvents(acceptableEvents, "acceptableEvents")
        let producing = ClosureTask.stringEvents(producingEvents, "producingEvents")
        if (exec.trimAscii().isEmpty()) {
            throw GraphException("ClosureTask exec must not be blank")
        }
        let compiler = ClosureTask.ensureCompiler()
        let fn = compiler.compile("{ e: Event =>\n" + exec + "\n}")
        ClosureTask(name, acceptable, producing, { e => fn.call<Event>([e]) })
    }

    /** 事件列表必须非空且元素全为 `String`（LIST 运行时只保证 `ArrayList<Any>`）。 */
    private static func stringEvents(values: ArrayList<Any>, field: String): Array<String> {
        if (values.size == 0) {
            throw GraphException('ClosureTask ${field} must not be empty')
        }
        let out = Array<String>(values.size, repeat: '')
        var i = 0
        for (value in values) {
            match (value) {
                case s: String => out[i] = s
                case _ => throw GraphException('ClosureTask ${field} elements must be String')
            }
            i++
        }
        out
    }

    public prop name: String {
        get() {
            name_
        }
    }

    public prop acceptableEvents: Array<String> {
        get() {
            acceptable_
        }
    }

    public prop producingEvents: Array<String> {
        get() {
            producing_
        }
    }

    public func exec(e: Event): Event {
        body_(e)
    }
}
