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

    public static func wire(chat: (String, String, String) -> String,
                            plannerModel!: String = ''): LoomService {
        let settings = StoreSettings.load()
        let registry = LoomRegistry(store: LoomBootstrap.storeFor(settings.memoryStore))
        LoomBootstrap.startup(registry)
        let planner = Planner({ system, user => chat(plannerModel, system, user) })
        let service = LoomService(planner, registry)
        LoomServices.install(service)
        // 同一份 chat 回调兼作执行宿主：confirm+execute 时可直接跑一遍
        LoomServices.installHost(DefaultLoomHost(chat))
        service
    }
}
