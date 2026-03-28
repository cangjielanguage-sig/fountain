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
package fountain::f_llm.agents

public class AgentEvent <: Event {
    private init(category!: String, tag!: String, name!: String, data!: Any,
                session!: String = UUID.random().toHexString()){
        super(category: category, tag: tag, name: name, data: data, session: session)
    }
    public init(category!: String, tag!: String, name!: String, data: AgentEventData,
                session!: String = UUID.random().toHexString()){
        this(category: category, tag: tag, name: name, data: (data as Any).getOrThrow(), session: session)
    }
    public init(category!: String, tag!: String, name!: String, data: String,
                session!: String = UUID.random().toHexString()){
        this(category: category, tag: tag, name: name, data: (data as Any).getOrThrow(), session: session)
    }
    public init(category!: String, tag!: String, name!: String, data: ChatMessage,
                session!: String = UUID.random().toHexString()){
        this(category: category, tag: tag, name: name, data: (data as Any).getOrThrow(), session: session)
    }
    public init(category!: String, tag!: String, name!: String, data: ArrayList<ChatMessage>,
                session!: String = UUID.random().toHexString()){
        this(category: category, tag: tag, name: name, data: (data as Any).getOrThrow(), session: session)
    }
}