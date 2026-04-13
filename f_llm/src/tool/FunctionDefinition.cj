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

import std.reflect.*
import fountain::f_bean.BeanFactory

@Annotation[target: [MemberFunction]]
public class FunctionDefinition {
    public const FunctionDefinition(
        public let name!: String,
        public let description!: String
    ){}

    public static func register<C, P>(name: String, callee: (P) -> FunctionResult): Unit where P <: ObjectData<P> {
        let klass = TypeInfo.of<C>()
        let f = klass.getInstanceFunction(name, [TypeInfo.of<P>()])
        let def = f.findAnnotation<FunctionDefinition>() ?? throw FunctionCallingException('function declared in class with macro @Tool must be modified with @FunctionDefinition')
        BeanFactory.instance.register<WrappedFunctionCalling<P>>{
            WrappedFunctionCalling<P>(def, callee)
        }
    }
}