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
package fountain::f_llm.model

public class CodeParam {
    public CodeParam(
        public let projectId!: Int64 = 0,
        public let moduleName!: String = '',
        public let packageName!: String = '',
        public let code!: String = '',
        public let weight!: Float64 = 0.0,
        public let confidence!: Float64 = 0.0
    ){}
}