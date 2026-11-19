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

public type ModelName = String

// ===== DeepSeek（默认供应商）=====
/** 默认模型：便宜、够快，装配与日常对话都用它 */
public const MODEL_NAME_DEEPSEEK_FLASH = 'deepseek-flash'
public const MODEL_NAME_DEEPSEEK_CHAT = 'deepseek-chat'
public const MODEL_NAME_DEEPSEEK_REASONER = 'deepseek-reasoner'

// ===== 智谱 =====
public const MODEL_NAME_GLM5 = 'glm-5'
public const MODEL_NAME_GLM5_CODE = 'glm-5-code'
public const MODEL_NAME_GLM5_FLASH = 'glm-5-flash'
public const MODEL_NAME_GLM_EMBEDDING3 = 'embedding-3'

// ===== 搜索（仅作为 conf 里的 llmType=search 标记，不参与对话）=====
public const MODEL_NAME_GLM_SEARCH_STD = 'glm|search-std'
public const MODEL_NAME_GLM_SEARCH_PRO = 'glm|search-pro'
public const MODEL_NAME_GLM_SEARCH_PRO_QUARK = 'glm|search-pro-quark'
public const MODEL_NAME_GLM_SEARCH_PRO_SOGOU = 'glm|search-pro-quark-sogou'
