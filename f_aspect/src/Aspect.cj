/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package f_aspect

public import f_aspect.exception.AspectBeforeException

/**
 * 所有切面必须实现本接口，且必须被@AspectRoute修饰。
 */
public interface Aspect {
    func before(funcInfo: InvocationFuncInfo): Unit {
    }
    func after(funcInfo: InvocationFuncInfo, result: Any): Any {
        result
    }
    func around(funcInfo: InvocationFuncInfo, point: (Array<Any>) -> Any): Any {
        point(funcInfo.args)
    }
    func throwing(funcInfo: InvocationFuncInfo, e: Exception): Exception {
        e
    }
    func final(funcInfo: InvocationFuncInfo): Unit {}
    func proceed(funcInfo: InvocationFuncInfo, point: (Array<Any>) -> Any): Any {
        try {
            before(funcInfo)
            var result = around(funcInfo, point)
            result = after(funcInfo, result)
            result
        } catch (e: Exception) {
            throw throwing(funcInfo, e)
        } finally {
            final(funcInfo)
        }
    }
}
