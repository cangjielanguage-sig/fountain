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
package fountain::fcoder.llm

public sealed abstract class AbstractLLMContext {
    private AbstractLLMContext(
        protected let id: Int64,
        protected let name: String,
        protected let llmType: String,
        protected let url: String,
        protected let conf: String,
        protected let threshold: Int64
    ) {}
    public init(conf: LLMConf){
        this(conf.id, conf.name, conf.llmType, conf.url, conf.conf, conf.threshold)
    }

    public func access(params: LLMParams): LLMResp
}