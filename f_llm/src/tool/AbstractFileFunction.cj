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

public abstract class AbstractFileFunction<T> <: FunctionCalling<T> where T <: ObjectData<T> {
    protected func genPath(path: String): Path {
        if(path.startsWith('../')){
            throw IllegalPathException('path must not start with ../, but it is ${path}. The path as function calling param attempts to BREAK THROUGH the SAFETY SANDBOX')
        }
        var p = Path(path)
        if(OS.current.isWindows){
            if(p.isAbsolute()){
                throw IllegalPathException('path must not be absolute, but it is ${path}. The path as function calling param attempts to BREAK THROUGH the SAFETY SANDBOX')
            }
        }else if(p.isAbsolute()){
            p = Path(path[1 ..])
        }
        LLMConfig.getFileSandboxPath().join(p)
    }
}