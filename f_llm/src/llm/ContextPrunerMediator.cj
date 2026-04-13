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

public class ContextPrunerMediator {
    public static let instance = ContextPrunerMediator()
    private ContextPrunerMediator() {}
    private let pruners = ConcurrentHashMap<String, ContextPruner>()

    private let mutex = Mutex()
    private func load(name: String){
        if(let Some(x) <- pruners.get(name)){
            return x
        }
        synchronized(mutex){
            if(let Some(x) <- pruners.get(name)){
                return x
            }
            for(pruner in lookupList<ContextPruner>()){
                pruners[pruner.name] = pruner
            }
            pruners[name]
        }
    }

    public func prune(name: String, agentId!: Int64, session!: String, messages!: ArrayList<ChatMessage>): ArrayList<ChatMessage> {
        load(name).prune(agentId, session, messages)
    }
}