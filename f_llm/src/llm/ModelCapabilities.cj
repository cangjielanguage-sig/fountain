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
package fountain::f_llm.llm

import fountain::f_llm.constant.*
import fountain::f_llm.model.po.*

/**
 * 思考能力的解析顺序（规范要求的三级）：**配置覆盖 → 模型能力表 → 默认可开关**。
 *
 * 平台不参与判断：同一个 `deepseek-flash` 无论走 DeepSeek 官方还是腾讯云 tokenhub，
 * 都是 `Always`；差异只在方言怎么写字段。
 */
public struct ModelCapabilities {
    private init(){}

    public static func resolve(conf: LLMConf): ThinkingMode {
        // 1. 配置覆盖：conf['thinking'] = none | always | toggle
        match(conf.option('thinking', '').trimAscii().toAsciiLower()){
            case 'none' => return ThinkingMode.None
            case 'always' => return ThinkingMode.Always
            case 'toggle' => return ThinkingMode.Toggle
            case _ => ()
        }
        // 2. 模型能力表（模型名先归一到框架常量）
        //
        // 注意用 if 而不是 `match` + 常量模式：仓颉的 `case CONST` 会被当成**绑定模式**，
        // 结果所有模型都落到第一个分支（实测：glm-5 / embedding-3 全被判成 Always）。
        let model = ModelNames.normalize(conf.actualLlmName)
        if(model == MODEL_NAME_DEEPSEEK_FLASH || model == MODEL_NAME_DEEPSEEK_REASONER){
            return ThinkingMode.Always
        }
        if(model == MODEL_NAME_GLM_EMBEDDING3){
            return ThinkingMode.None
        }
        // 3. 默认：按可开关处理（deepseek-chat / glm-5 系列 / 未知模型）
        ThinkingMode.Toggle
    }

    /** 恒思考模型不接受 `temperature`（传了会被忽略或报错），报文里不该出现 */
    public static func blocksTemperature(conf: LLMConf): Bool {
        match(resolve(conf)){
            case ThinkingMode.Always => true
            case _ => false
        }
    }
}

/**
 * 把思考能力落到报文的公共部分。
 *
 * 与方言的分工：方言只管「字段长什么样」（`thinking` 对象 / `enable_thinking` 布尔 / 没有字段），
 * 这里管「该不该有、要不要连带删 `temperature`」，所以要在 `dialect.decorate` **之后**执行。
 */
public struct ThinkingPolicy {
    private static let log = LoggerFactory.getLogger<ThinkingPolicy>()

    private init(){}

    public static func apply(conf: LLMConf, body: JsonObject): Unit {
        match(ModelCapabilities.resolve(conf)){
            case ThinkingMode.Always =>
                body.remove('temperature')
            case ThinkingMode.None =>
                body.remove('thinking')
                body.remove('enable_thinking')
                if(conf.alwaysThinking){
                    log.warn{'model has no thinking capability but alwaysThinking is on, provider: ${conf.provider}, model: ${conf.actualLlmName}'}
                }
            case ThinkingMode.Toggle => ()
        }
    }
}
