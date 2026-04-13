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
package fountain::f_egraph

import fountain::f_app.*
import fountain::f_bean.*

public import fountain::f_egraph.base.*
public import fountain::f_egraph.loader.*

public interface FlowInitializer <: Initializer {
    prop name: String {
        get(){
            'fountain::f_egraph'
        }
    }
    prop dependencies: Array<String> {
        get(){
            ['fountain::f_bean']
        }
    }
    func initialize(): Unit {
        for(flow in lookup<FlowLoader>().load()) {
            FlowDSLCompiler.compile(flow)
        }
    }
}