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

import std.collection.*
import std.time.DateTime
import fountain::f_llm.channel.*
import fountain::f_llm.config.LLMConfig
import fountain::f_log.*
import fountain::f_llm.store.*

/**
 * loom 的启动装配。
 *
 * 需要宿主在 `StoreWiring.wire()` 之后调一次：
 *
 * ```cangjie
 * LoomWiring.wire({ model, system, user => /* 调 LLM，model 为空时用默认模型 */ })
 * ```
 *
 * 之所以不放进 `StoreWiring`：chat 回调依赖具体的 LLM 客户端与模型配置，
 * 由宿主决定比框架内写死更可控（也便于测试替换）。
 */
/** 懒建一次的网关持有者：首次 store 调用时建，之后复用 */
class LoomGatewayHolder {
    private var value: ?LoomStoreGateway = None

    func get(injected: ?LoomStoreGateway): LoomStoreGateway {
        match (injected) {
            case Some(gateway) => return gateway
            case None => ()
        }
        match (value) {
            case Some(gateway) => return gateway
            case None => ()
        }
        let built = LoomStoreGateway()
        value = Some(built)
        built
    }
}

public class LoomWiring {
    private init() {
    }

    /**
     * @param chat `(model, system, user) -> String`；`model` 为空串时由回调选默认模型
     * @param plannerModel 规划用模型；空串则 `LoomRequest.model` 优先、再回退默认
     * @return 已安装的 `LoomService`（同时写入 `LoomServices`）
     */
    /** 零配置：直接用 `LLM.chatByName`（模型取 `plannerModel`，为空则调用时报错） */
    public static func wire(plannerModel!: String = ''): LoomService {
        wire(LoomDefaults.chat(plannerModel), plannerModel: plannerModel)
    }

    /**
     * @param evolutionCron 非空时把技能演进注册成周期任务（cron 七段式）
     * @param evolutionUserId / evolutionNamespace 取经验与知识用的归属
     * @param evolutionModel 演进用的模型名；空串则交给 chat 回调取默认
     */
    public static func wire(chat: (String, String, String) -> String, plannerModel!: String = '',
        store!: ?LoomStore = None, memoryPolicy!: ?LoomMemoryPolicy = None,
        skillEmbedder!: ?(String) -> Array<Float64> = None, evolutionCron!: String = '', evolutionUserId!: Int64 = 0,
        evolutionNamespace!: String = 'loom', evolutionModel!: String = '', evolutionNameCandidates!: Bool = true,
        evolutionPolicy!: SkillEvolutionPolicy = SkillEvolutionPolicy(), gateway!: ?LoomStoreGateway = None,
        host!: ?LoomHost = None, characterUserId!: Int64 = 0): LoomService {
        // 人格归属：独立于记忆策略，配了才装
        if (characterUserId > 0) {
            LoomCharacterScope.install(characterUserId)
        }
        let settings = StoreSettings.load()
        // 与 MetaStore 共用 llm_metaStore：f_store（默认）/ memory / postgres / mysql
        let chosen = match (store) {
            case Some(value) => value
            case None => LoomBootstrap.storeFor(settings.metaStore)
        }
        let registry = LoomRegistry(store: chosen)
        let reloaded = LoomBootstrap.startup(registry)
        reload = Some(reloaded)
        if (reloaded.restoreFailed) {
            // 库可能比应用晚就绪：不阻断启动，但必须留下痕迹
            LoggerFactory.getLogger<LoomWiring>().warn('loom restore failed: ${reloaded.toString()}')
        }
        let planner = Planner({system, user => chat(plannerModel, system, user)})
        let service = LoomService(planner, registry)
        LoomServices.install(service)
        // 默认存储网关：首次使用时建一次，之后所有入口共用
        // （不在装配期直接建，避免启动即连存储；也不能每次调用都建，否则重复开库）
        let gatewayHolder = LoomGatewayHolder()
        LoomHostApi.installStore({
            kind, op, payload => gatewayHolder.get(gateway).call(kind, op, payload)
        })
        // 同一份 chat 回调兼作执行宿主：confirm+execute 时可直接跑一遍
        let chosenHost: LoomHost = match (host) {
            case Some(value) => value
            case None => match (LoomServices.currentHost()) {
                case Some(value) => value
                case None => DefaultLoomHost(chat)
            }
        }
        LoomServices.installHost(chosenHost)
        // 第三方平台通道：按 llm_channels 装配（未配置时什么都不做）
        let _ = ChannelBootstrap.installFromConfig()
        // Supervisor：开关打开时用已编译流程播种路由表（重启后恢复的流程也在这里进来）
        installSupervisor(service, registry, chat, plannerModel)
        // 记忆策略：默认开启（规则提炼），需要模型总结时由调用方传入 summarize=true
        match (memoryPolicy) {
            case Some(policy) => LoomMemoryPolicy.install(policy)
            case None => ()
        }
        // 技能目录：惰性取技能库；传了 embedder 就是向量检索，否则退回关键词
        SkillCatalog.install({=> Stores.meta().skills}, embedder: skillEmbedder)
        // 演进报告表：mysql/postgres 部署在启动时建表建索引（失败不阻断启动）
        EvolutionStores.bootstrap()
        // 演进状态：默认落 f_store；mysql/postgres 建表
        EvolutionStateStores.bootstrap()
        // 每日租约：跟着向量存储走（SQL 建单行表 / hydra 全 0 向量 / 本地 f_store）
        let _ = EvolutionLeases.bootstrap()
        // 技能演进统一由 SkillEvolutionJob 执行：配了 cron 就注册成周期任务
        registerEvolution(chat, evolutionCron, evolutionUserId, evolutionNamespace, evolutionModel,
            evolutionNameCandidates, evolutionPolicy, skillEmbedder, gatewayHolder, gateway)
        service
    }

    /**
     * 装配 Supervisor：`llm_supervisor` 关闭时什么都不做（零开销、零行为变化）。
     *
     * 路由表不落库，开机时按 `LoomRegistry` 里已恢复的流程重建；
     * 选路与派发复用同一份 chat 回调（模型名取 `plannerModel`）。
     */
    /** 最近一次装配的恢复结果（`wire` 写入）；进程级，和 `LoomServices` 一致 */
    private static var reload: ?ReloadResult = None

    public static func lastReload(): ?ReloadResult {
        reload
    }

    private static func installSupervisor(service: LoomService, registry: LoomRegistry,
        chat: (String, String, String) -> String, plannerModel: String): Unit {
        if (!LLMConfig.supervisorEnabled()) {
            return
        }
        let host: LoomHost = match (LoomServices.currentHost()) {
            case Some(value) => value
            case None => DefaultLoomHost(chat)
        }
        let flows = ArrayList<LoomFlow>()
        for (flow in registry.compiledFlows()) {
            flows.add(flow)
        }
        let _ = Supervisor.install(service, host, {system, user => chat(plannerModel, system, user)}, flows: flows)
    }

    /** 注册周期演进任务；未配 cron 或未装调度器时什么都不做 */
    private static func registerEvolution(chat: (String, String, String) -> String, cron: String, userId: Int64,
        namespace: String, model: String, nameCandidates: Bool, policy: SkillEvolutionPolicy,
        embedder: ?(String) -> Array<Float64>, holder: LoomGatewayHolder, injected: ?LoomStoreGateway): Unit {
        if (cron.trimAscii().isEmpty()) {
            return
        }
        let scheduler = match (LoomSchedules.current()) {
            case Some(value) => value
            case None => return
        }
        let state = EvolutionStateStores.current()
        let ledger = EvolutionStores.current()
        // 租约构造可能打开本地存储；失败就不做互斥（单进程也安全）
        let lease: ?EvolutionLease = try {
            Some(EvolutionLeases.current())
        } catch (error: Exception) {
            None
        }
        // chat 是 (model, system, user)；演进侧只需要 (system, user)
        let evolveChat = {system: String, user: String => chat(model, system, user)}
        SkillEvolutionJob.schedule('loom-skill-evolution', cron, scheduler, {=> Stores.meta().skills.list()},
            // 网关与存储都在任务触发时才构造：注册阶段不碰内容存储，避免启动即建连接
            {=> SkillEvolutionJob.load(holder.get(injected), userId, namespace)}, evolveChat, state, policy: policy,
            embedder: embedder, nameCandidates: nameCandidates, ledger: ledger, lease: lease,
            clock: {=> DateTime.now().toUnixTimeStamp().toSeconds()})
    }
}
