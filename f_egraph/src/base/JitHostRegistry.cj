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

/**
 * 宿主类型的 JIT 注册表（`design.md` §5、§7.3）。
 *
 * 宏不可用的类型走这里的手工描述符：事件谱系、`Emitter`、`BaseFlow`、两个流程类；
 * `Task`/`ClosureTask`/`FlowEventFactory` 仍走 `@JitBind`（见 `configure` 末尾）。
 *
 * 只描述、不缓存：每次 `configure` 都新建描述符，`ClassDescriptor` 自带数组防御性拷贝。
 * `HostFieldTable` 是进程级全局表，重复 `configure` 只会追加等价访问器（`design.md` R11）。
 */
public class JitHostRegistry {
    private static let EVENT = "Event"
    private static let EMITTER = "Emitter"
    private static let BASE_FLOW = "BaseFlow"
    private static let IMMEDIATE_FLOW = "ImmediateFlow"
    private static let ASYNC_FLOW = "AsyncFlow"

    private init() {}

    /** 在执行任何流程脚本之前完成宿主类型注册（§5 表）。 */
    public static func configure(compiler: Compiler): Unit {
        JitHostRegistry.registerEventFields()
        for (desc in JitHostRegistry.eventDescriptors()) {
            compiler.registerClass(desc)
        }
        compiler.registerClass(JitHostRegistry.emitterDescriptor())
        compiler.registerClass(JitHostRegistry.baseFlowDescriptor())
        compiler.registerClass(JitHostRegistry.immediateFlowDescriptor())
        compiler.registerClass(JitHostRegistry.asyncFlowDescriptor())
        compiler.registerInterface<Task>()
        compiler.registerType<ClosureTask>()
        compiler.registerType<FlowEventFactory>()
    }

    // ===== 字段访问器（`HostFieldTable`，全局只登记一次）=====

    /** 事件字段访问器：`category`/`tag`/`name`/`session`，索引全局一致（§5.2）。 */
    internal static func registerEventFields(): Unit {
        HostFieldTable.register(index: 0u16, `type`: LocalType.STRING, mutable: false,
            accepts: { o => o is Event },
            getter: { o =>
                match (o) {
                    case e: Event => e.category
                    case _ => ''
                }
            },
            setter: { _, _ => () })
        HostFieldTable.register(index: 1u16, `type`: LocalType.STRING, mutable: false,
            accepts: { o => o is Event },
            getter: { o =>
                match (o) {
                    case e: Event => e.tag
                    case _ => ''
                }
            },
            setter: { _, _ => () })
        HostFieldTable.register(index: 2u16, `type`: LocalType.STRING, mutable: false,
            accepts: { o => o is Event },
            getter: { o =>
                match (o) {
                    case e: Event => e.name
                    case _ => ''
                }
            },
            setter: { _, _ => () })
        HostFieldTable.register(index: 3u16, `type`: LocalType.STRING, mutable: false,
            accepts: { o => o is Event },
            getter: { o =>
                match (o) {
                    case e: Event => e.session
                    case _ => ''
                }
            },
            setter: { _, _ => () })
    }

    internal static func eventFields(): Array<PublicField> {
        [
            PublicField(name: "category", `type`: LocalType.STRING, index: 0u16,
                mutable: false, typeRef: None),
            PublicField(name: "tag", `type`: LocalType.STRING, index: 1u16,
                mutable: false, typeRef: None),
            PublicField(name: "name", `type`: LocalType.STRING, index: 2u16,
                mutable: false, typeRef: None),
            PublicField(name: "session", `type`: LocalType.STRING, index: 3u16,
                mutable: false, typeRef: None)
        ]
    }

    // ===== 事件谱系 =====

    /**
     * 8 个事件类的描述符。
     *
     * 父链按真实继承关系填写（前端只做静态子类型判定，不做成员上溯）；字段与 `toString`
     * 只登记在各自描述符里，`Event.toString` 是唯一的事件方法。
     */
    internal static func eventDescriptors(): Array<ClassDescriptor> {
        [
            JitHostRegistry.eventDescriptor(JitHostRegistry.EVENT, Array<String>()),
            JitHostRegistry.eventDescriptor("DataEvent", [JitHostRegistry.EVENT]),
            JitHostRegistry.eventDescriptor("StartEvent", ["DataEvent", JitHostRegistry.EVENT]),
            JitHostRegistry.eventDescriptor("EndEvent", ["DataEvent", JitHostRegistry.EVENT]),
            JitHostRegistry.eventDescriptor("TaskEvent", ["DataEvent", JitHostRegistry.EVENT]),
            JitHostRegistry.eventDescriptor("ErrorEvent", ["DataEvent", JitHostRegistry.EVENT]),
            JitHostRegistry.eventDescriptor("MultiEvent", ["DataEvent", JitHostRegistry.EVENT]),
            JitHostRegistry.eventDescriptor("DummyEvent", [JitHostRegistry.EVENT])
        ]
    }

    private static func eventDescriptor(name: String, parents: Array<String>): ClassDescriptor {
        let methods = if (name == JitHostRegistry.EVENT) {
            [JitHostRegistry.eventToStringMethod()]
        } else {
            Array<PublicMethod>()
        }
        ClassDescriptor(name: name, fields: JitHostRegistry.eventFields(), methods: methods,
            ctors: Array<PublicCtor>(), parents: parents)
    }

    private static func eventToStringMethod(): PublicMethod {
        PublicMethod(name: "toString", bind: PredefinedFunction("Event.toString",
            [LocalType.HOST_OBJECT], LocalType.STRING, { args =>
                match (args[0]) {
                    case e: Event => e.toString()
                    case _ => throw GraphException('Event.toString expects an Event')
                }
            }))
    }

    // ===== 接口 =====

    /** `Emitter` 的唯一成员带 `Any` 形参，脚本面为空（§5.2）。 */
    internal static func emitterDescriptor(): ClassDescriptor {
        ClassDescriptor(name: JitHostRegistry.EMITTER,
            fields: Array<PublicField>(),
            methods: Array<PublicMethod>(),
            ctors: Array<PublicCtor>(),
            isInterface: true)
    }

    /** `BaseFlow`：只登记脚本契约用到的 7 个成员（§5.2）。 */
    internal static func baseFlowDescriptor(): ClassDescriptor {
        ClassDescriptor(name: JitHostRegistry.BASE_FLOW,
            fields: Array<PublicField>(),
            methods: JitHostRegistry.flowMethods(JitHostRegistry.BASE_FLOW),
            ctors: Array<PublicCtor>(),
            isInterface: true)
    }

    // ===== 具体流程类 =====

    internal static func immediateFlowDescriptor(): ClassDescriptor {
        ClassDescriptor(name: JitHostRegistry.IMMEDIATE_FLOW,
            fields: Array<PublicField>(),
            methods: JitHostRegistry.flowMethods(JitHostRegistry.IMMEDIATE_FLOW),
            ctors: [
                PublicCtor(params: [LocalType.STRING, LocalType.STRING], adapter: { args =>
                    ImmediateFlow(
                        category: JitHostRegistry.stringArg(args, 0, "ImmediateFlow"),
                        tag: JitHostRegistry.stringArg(args, 1, "ImmediateFlow"))
                })
            ],
            parents: [JitHostRegistry.BASE_FLOW])
    }

    internal static func asyncFlowDescriptor(): ClassDescriptor {
        ClassDescriptor(name: JitHostRegistry.ASYNC_FLOW,
            fields: Array<PublicField>(),
            methods: JitHostRegistry.flowMethods(JitHostRegistry.ASYNC_FLOW),
            ctors: [
                PublicCtor(params: [LocalType.STRING, LocalType.STRING], adapter: { args =>
                    AsyncFlow(
                        category: JitHostRegistry.stringArg(args, 0, "AsyncFlow"),
                        tag: JitHostRegistry.stringArg(args, 1, "AsyncFlow"))
                })
            ],
            parents: [JitHostRegistry.BASE_FLOW])
    }

    // ===== 方法适配器（每项一个独立工厂，参数序列与 §5.2 表逐行对应）=====

    private static func flowMethods(prefix: String): Array<PublicMethod> {
        [
            JitHostRegistry.flowMethod(prefix, "canBeRemoved", [LocalType.HOST_OBJECT],
                { f, _ => f.canBeRemoved() }),
            JitHostRegistry.flowMethod(prefix, "remove", [LocalType.HOST_OBJECT],
                { f, _ => f.remove() }),
            JitHostRegistry.flowMethod(prefix, "removeExceptCurrentTag", [LocalType.HOST_OBJECT],
                { f, _ => f.removeExceptCurrentTag() }),
            JitHostRegistry.flowMethod(prefix, "registerStart",
                [LocalType.HOST_OBJECT, LocalType.STRING],
                { f, args => f.registerStart(JitHostRegistry.stringArg(args, 1, '${prefix}.registerStart')) }),
            JitHostRegistry.flowMethod(prefix, "registerEnd", [LocalType.HOST_OBJECT],
                { f, _ => f.registerEnd() }),
            JitHostRegistry.flowMethod(prefix, "registerError", [LocalType.HOST_OBJECT],
                { f, _ => f.registerError() }),
            JitHostRegistry.flowMethod(prefix, "registerTask",
                [LocalType.HOST_OBJECT, LocalType.HOST_OBJECT],
                { f, args => f.registerTask(JitHostRegistry.taskArg(args, 1, '${prefix}.registerTask')) })
        ]
    }

    private static func flowMethod(prefix: String, name: String, paramTypes: Array<UInt16>,
        action: (BaseFlow, Array<Any>) -> Unit): PublicMethod {
        let bindName = '${prefix}.${name}'
        PublicMethod(name: name, bind: PredefinedFunction(bindName, paramTypes, LocalType.UNIT,
            { args =>
                action(JitHostRegistry.flowArg(args, 0, bindName), args)
                ()
            }))
    }

    // ===== 实参解包（统一 `match`，不做隐式转换）=====

    private static func flowArg(args: Array<Any>, index: Int64, context: String): BaseFlow {
        match (args[index]) {
            case f: BaseFlow => f
            case _ => throw GraphException('${context} expects a flow instance')
        }
    }

    private static func stringArg(args: Array<Any>, index: Int64, context: String): String {
        match (args[index]) {
            case v: String => v
            case _ => throw GraphException('${context} expects a String')
        }
    }

    private static func taskArg(args: Array<Any>, index: Int64, context: String): Task {
        match (args[index]) {
            case t: Task => t
            case _ => throw GraphException('${context} expects a Task')
        }
    }
}
