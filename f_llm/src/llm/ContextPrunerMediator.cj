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

    private var loaded = false

    /** 扫描 @Bean；只扫一次，之后走注册表 */
    private func ensureLoaded(){
        synchronized(mutex){
            if(loaded){
                return
            }
            for(pruner in lookupList<ContextPruner>()){
                pruners[pruner.name] = pruner
            }
            loaded = true
        }
    }

    /**
     * 显式注册（新增算法走这里，或让自己的类带 @Bean）。
     *
     * 同名直接失败：策略名就是 `agent.conf['pruner']` 里的字符串，
     * 两个实现抢同一个名字时，裁出来的上下文取决于扫描顺序，这种不确定性比启动失败更难查。
     */
    public func register(pruner: ContextPruner): Unit {
        ensureLoaded()
        synchronized(mutex){
            if(pruners.contains(pruner.name)){
                throw IllegalArgumentException('context pruner already registered: ${pruner.name}')
            }
            pruners[pruner.name] = pruner
        }
    }

    public func names(): ArrayList<String> {
        ensureLoaded()
        let result = ArrayList<String>()
        for((name, _) in pruners){
            result.add(name)
        }
        result
    }

    public func prune(name: String, agentId!: Int64, session!: String, messages!: ArrayList<ChatMessage>): ArrayList<ChatMessage> {
        ensureLoaded()
        if(let Some(pruner) <- pruners.get(name)){
            return pruner.prune(agentId, session, messages)
        }
        throw IllegalArgumentException('unknown context pruner: ${name}, available: ${names()}')
    }
}
