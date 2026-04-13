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
package fountain::f_llm.tool

public class WrappedFunctionCalling<T> <: FunctionCalling<T> where T <: ObjectData<T> {
    private let name_: String
    private let description_: String
    private let callee_: (T) -> FunctionResult
    public init(name!: String, description!: String, callee!: (T) -> FunctionResult){
        this.name_ = name
        this.description_ = description
        this.callee_ = callee
    }
    public init(def: FunctionDefinition, callee: (T) -> FunctionResult){
        this.name_ = def.name
        this.description_ = def.description
        this.callee_ = callee
    }
    public prop name: String {
        get() {
            return this.name_
        }
    }
    public prop description: String {
        get() {
            return this.description_
        }
    }
    public func call(input: T): FunctionResult {
        return this.callee_(input)
    }
}