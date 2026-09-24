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

public type LLMType = String 
//text embedding tokenizer rerank code video audio image prune
public const LLM_TYPE_TEXT = 'text'
public const LLM_TYPE_EMBEDDING = 'embedding'
public const LLM_TYPE_TOKENIZER = 'tokenizer'
public const LLM_TYPE_RERANK = 'rerank'
public const LLM_TYPE_CODE = 'code'
public const LLM_TYPE_VIDEO = 'video'
public const LLM_TYPE_AUDIO = 'audio'
public const LLM_TYPE_IMAGE = 'image'
public const LLM_TYPE_SEARCH = 'search'
