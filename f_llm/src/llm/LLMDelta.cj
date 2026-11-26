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

/** 流式增量的种类：正文 / 推理内容 / 工具调用参数片段 */
public enum LLMDeltaKind {
    | Text
    | Reasoning
    | ToolCall
}

/** 一条流式增量；回调方只负责展示或转发，不做归并 */
public class LLMDelta {
    public LLMDelta(public let kind: LLMDeltaKind, public let content: String){}
}
