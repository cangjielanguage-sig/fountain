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
package fountain::f_llm.search

import fountain::f_data.macros.*

/**
 * 旧的搜索结果结构（`KnowledgeEntity` 的注入接口仍在用）。
 *
 * 新代码请用 `SearchResultItem`（字段更少、已归一）；这个类保留是因为
 * `KnowledgeEntity` 的 `searcher: (String) -> ArrayList<SearchResult>` 是公开注入点，
 * 删掉会破坏下游编译。等 `KnowledgeEntity` 换签名后再一并移除。
 */
@DataAssist[props fields]
public class SearchResult {
    private var title: String = ''
    private var content: String = ''
    private var link: String = ''
    private var media: String = ''
    private var icon: String = ''
    private var refer: String = ''
    private var publish_date: String = ''
}
