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

public class AgentEventData {
    var skillIds = HashSet<String>()
    private let skillReferences = HashMap<String, ArrayList<SkillReference>>()
    public AgentEventData(
        public let data!: ?Any = None,
        public let messages!: ArrayList<ChatMessage> = ArrayList<ChatMessage>(),
        public let message!: String = '',
        public let functions!: HashSet<FunctionCall> = HashSet<FunctionCall>(),
        public let skillDetails!: ArrayList<(String, String)> = ArrayList<(String, String)>(),
        public let experiences!: ArrayList<Experience> = ArrayList<Experience>()
    ){
    }

    public func addFunctions<I>(functions: I): Unit where I <: Iterable<FunctionCall> {
        for (function in functions) {
            this.functions.add(function)
        }
    }
    func addSkillReferences(references: ArrayList<SkillReference>){
        for (reference in references) {
            this.skillReferences.computeIfAbsent(reference.skillTitle){ArrayList<SkillReference>()}.add(reference)
        }
    }
    func getSkillReferences(title: String): List<SkillReference> {
        return this.skillReferences.get(title) ?? EmptyList<SkillReference>.instance()
    }
    func addExperiences(experiences: ArrayList<Experience>){
        experiences.add(all: experiences)
    }
}