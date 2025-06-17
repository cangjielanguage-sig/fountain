/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
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
    func final(funcInfo: InvocationFuncInfo): Unit{}
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
