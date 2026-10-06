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
package fountain::f_llm.embedding

public abstract class AbstractEmbeddingContext {
    public AbstractEmbeddingContext(
        protected let id: Int64,
        protected let name: String,
        protected let url: String,
        protected let conf: String
    ){}
    public init(conf: LLMConf){
        this(conf.id, conf.name, conf.url, conf.conf)
    }
    public func access(param: EmbeddingParam): EmbeddingResp
}