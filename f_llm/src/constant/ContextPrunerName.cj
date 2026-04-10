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

public type ContextPrunerName = String
/**
 * 保留全部
 */
public const CONTEXT_PRUNER_RETAIN = "Retain"
/**
 * 保留最新
 */
public const CONTEXT_PRUNER_LAST_N = "LastN"
/**
 * 摘要
 */
public const CONTEXT_PRUNER_SUMMARY = "Summary"
/**
 * 提取关键词
 */
public const CONTEXT_PRUNER_KEYWORDS = "Keywords"
/**
 * system单独一个策略，assistant+user+tool另外一个策略
 */
public const CONTEXT_PRUNER_DRC = "DRC"
/**
 * 上下文饱和后执行一个指定策略
 */
public const CONTEXT_PRUNER_SATURATION = "Saturation"
/**
 * 压缩上下文后，保留最后一条用户消息
 */
public const CONTEXT_PRUNER_RETAIN_LAST_USER = "RetainLastUser"
/**
 * 压缩上下文后，保留最后一轮会话
 */
public const CONTEXT_PRUNER_RETAIN_LAST_ROUND = "RetainLastRound"