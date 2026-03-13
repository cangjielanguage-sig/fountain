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

import std.convert.*

import fountain::f_llm.exception.*

public const FCODER_USER = 'f_llm'

public type Role = String
public const ROLE_SYSTEM = "system"
public const ROLE_USER = "user"
public const ROLE_ASSISTANT = "assistant"
public const ROLE_TOOL = "tool"

public type ToolType = String
public const TOOL_TYPE_FUNCTION = "function"
public const TOOL_TYPE_WEB_SEARCH = "web_search"
public const TOOL_TYPE_RETRIEVAL = "retrieval"

public type KnowledgeKind = String
public const KNOWLEDGE_KIND_STD = 'STD' 
public const KNOWLEDGE_KIND_API = 'API'
public const KNOWLEDGE_KIND_SYNTAX = 'SYNTAX'
public const KNOWLEDGE_KIND_EXPERIENCE = 'EXPERIENCE'
public const KNOWLEDGE_KIND_CODESPEC = 'CODESPEC'
public const KNOWLEDGE_KIND_ARTICLE = 'ARTICLE'
public const KNOWLEDGE_KIND_COPYRIGHT = 'COPYRIGHT'
public const KNOWLEDGE_KIND_SKILL_RESOURCE = 'SKILL_RESOURCE'
public const KNOWLEDGE_KIND_SKILL_REFERENCE = 'SKILL_REFERENCE'
public const KNOWLEDGE_KIND_SKILL_TOOL = 'SKILL_TOOL'

public type LLMType = String 
//text embedding rerank code video audio image
public const LLM_TYPE_TEXT = 'text'
public const LLM_TYPE_EMBEDDING = 'embedding'
public const LLM_TYPE_RERANK = 'rerank'
public const LLM_TYPE_CODE = 'code'
public const LLM_TYPE_VIDEO = 'video'
public const LLM_TYPE_AUDIO = 'audio'
public const LLM_TYPE_IMAGE = 'image'
public const LLM_TYPE_SEARCH = 'search'

public const CONTENT_SIZE_MEDIUM = 'medium'
public const CONTENT_SIZE_HIGH = 'high'

public type ModelName = String
public const MODEL_NAME_GLM4_7_FLASH = 'glm-4.7-flash'
public const MODEL_NAME_GLM5 = 'glm-5'
public const MODEL_NAME_GLM5_CODE = 'glm-5-code'
public const MODEL_NAME_GLM_EMBEDDING3 = 'embedding-3'
public const MODEL_NAME_GLM_SEARCH_STD = 'glm|search-std'
public const MODEL_NAME_GLM_SEARCH_PRO = 'glm|search-pro'
public const MODEL_NAME_GLM_SEARCH_PRO_QUARK = 'glm|search-pro-quark'
public const MODEL_NAME_GLM_SEARCH_PRO_SOGOU = 'glm|search-pro-quark-sogou'

public type ThinkingSwitch = String
public const THINGKING_ENABLED = 'enabled'
public const THINGKING_DISABLED = 'disabled'

public type SpecKind = String
public const SPEC_KIND_CONSTITUTION = 'CONSTITUTION'
public const SPEC_KIND_FEASIBILITY = 'FEASIBILITY'
public const SPEC_KIND_REQUIREMENT = 'REQUIREMENT'
public const SPEC_KIND_PRELIMINARY = 'PRELIMINARY'
public const SPEC_KIND_DETAIL = 'DETAIL'
public const SPEC_KIND_PLAN = 'PLAN'
public const SPEC_KIND_TASK = 'TASK'

public type SkillType = String
public const SKILL_TYPE_PRIMARY = 'primary'
public const SKILL_TYPE_AUXILIARY = 'auxiliary'