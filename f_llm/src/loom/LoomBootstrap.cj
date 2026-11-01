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
package fountain::f_llm.loom

/** 启动恢复的统计（§9.9） */
public class ReloadResult {
    public var restored: Int64 = 0
    public var compiled: Int64 = 0
    public var failed: Int64 = 0

    public init() {
    }

    public func toString(): String {
        'loom reload: restored=${restored}, compiled=${compiled}, failed=${failed}'
    }
}

/**
 * 启动装配：选存储 → 恢复注册表 → 重新编译 `compiled` 的流程。
 *
 * 单条失败只把该条标 `failed`，不影响其它流程（§9.9）。
 */
public class LoomBootstrap {
    private init() {
    }

    /** 按内容族选存储：`postgres` / `mysql` 走库，其余（如 `f_hydra`、`inMemory`）走内存 */
    public static func storeFor(driver: String): LoomStore {
        match(driver){
            case 'postgres' => PostgresLoomStore()
            case 'mysql' => MySqlLoomStore()
            case _ => MemoryLoomStore()
        }
    }

    /**
     * @param registry 已绑定 store 的注册表（由 `LoomRegistry(store: …)` 创建）
     */
    public static func startup(registry: LoomRegistry, compiler!: ?LoomCompiler = None): ReloadResult {
        let result = ReloadResult()
        result.restored = registry.restore()
        let engine = match(compiler){
            case Some(value) => value
            case None => LoomCompiler()
        }
        for(flow in registry.compiledFlows()){
            try{
                let plan = Planner.parse(flow.planJson, requestOf(flow))
                engine.compileSteps(plan.plan.getOrThrow())
                result.compiled++
            }catch(e: Exception){
                flow.mark(LoomStatus.FAILED)
                registry.put(flow)
                result.failed++
            }
        }
        result
    }

    /** 恢复时描述可能为空：`LoomRequest` 会校验非空，这里补一个占位 */
    internal static func requestOf(flow: LoomFlow): LoomRequest {
        let description = if(flow.description.trimAscii().isEmpty()){
            'restored loom flow ${flow.name}'
        }else{
            flow.description
        }
        LoomRequest(flow.name, description)
    }
}
