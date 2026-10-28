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
package fountain::f_llm.constant

/**
 * 各平台对同一个模型的叫法不一样，框架内部只认 `MODEL_NAME_*` 常量。
 *
 * 归一**只用于能力判断/日志分类**：`conf.actualLlmName` 必须原样发出去——
 * 腾讯云 tokenhub 要的就是 `deepseek/deepseek-flash`，改掉就直接 404。
 */
public struct ModelNames {
    private init(){}

    /** 腾讯云 tokenhub 上的模型 ID（同一份 deepseek-flash） */
    public static const TENCENT_DEEPSEEK_FLASH = 'deepseek/deepseek-flash'
    public static const TENCENT_DEEPSEEK_CHAT = 'deepseek/deepseek-chat'
    public static const TENCENT_DEEPSEEK_REASONER = 'deepseek/deepseek-reasoner'

    /** 把平台写法归一成框架常量；认不出的原样返回 */
    public static func normalize(name: String): ModelName {
        let trimmed = name.trimAscii()
        match(trimmed.toAsciiLower()){
            case 'deepseek/deepseek-flash' => MODEL_NAME_DEEPSEEK_FLASH
            case 'deepseek/deepseek-chat' => MODEL_NAME_DEEPSEEK_CHAT
            case 'deepseek/deepseek-reasoner' => MODEL_NAME_DEEPSEEK_REASONER
            // 硅基流动/其他聚合平台的常见写法
            case 'deepseek-ai/deepseek-v3' => MODEL_NAME_DEEPSEEK_CHAT
            case 'deepseek-ai/deepseek-v3.1' => MODEL_NAME_DEEPSEEK_CHAT
            case 'deepseek-ai/deepseek-r1' => MODEL_NAME_DEEPSEEK_REASONER
            case 'zhipu/glm-5' => MODEL_NAME_GLM5
            case 'zhipu/glm-5-code' => MODEL_NAME_GLM5_CODE
            case _ => trimmed
        }
    }

    /** 是否（归一到）默认的 deepseek-flash */
    public static func isFlash(name: String): Bool {
        normalize(name) == MODEL_NAME_DEEPSEEK_FLASH
    }
}
