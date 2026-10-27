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
package fountain::f_llm.finder

import fountain::f_llm.model.po.*

/**
 * 数据库配置源的查询入口。
 *
 * 只返回可用配置（`enabled = true AND weight > 0`）；按能力维度（llmType）的过滤
 * 由调用方按 `conf.option('llmType', ...)` 自行判断，接口本身不再带过滤参数。
 */
public interface LLMFinder {
    func listConfs(): ArrayList<LLMConf>
}
