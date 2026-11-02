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

    /**
     * 按**元数据族**配置（`llm_metaStore`）选存储，与 `MetaStore` 用同一个配置项：
     * `f_store`（默认，不指定也是它）/ `memory` / `postgres` / `mysql`。
     */
    public static func storeFor(metaStore: String): LoomStore {
        let name = metaStore.trimAscii().toAsciiLower()
        if(name.isEmpty() || name == 'f_store'){
            return FStoreLoomStore()
        }
        if(name == 'postgres'){
            return PostgresLoomStore()
        }
        if(name == 'mysql'){
            return MySqlLoomStore()
        }
        if(name == 'memory' || name == 'inmemory'){
            return MemoryLoomStore()
        }
        throw IllegalStateException(
            'unknown loom store: "${metaStore}"; expected f_store|memory|postgres|mysql')
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
