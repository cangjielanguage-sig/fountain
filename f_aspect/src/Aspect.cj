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
    func before(qualifiedFunc: String, args: Array<Any>): Array<Any> {
        args
    }
    func after(qualifiedFunc: String, args: Array<Any>, result: Any): Any {
        result
    }
    func around(qualifiedFunc: String, args: Array<Any>, point: () -> Any): Any {
        point()
    }
    func throwing(qualifiedFunc: String, args: Array<Any>, e: Exception): Exception {
        e
    }
    func final(): Unit{}
    func proceed(qualifiedFunc: String, args: Array<Any>, point: () -> Any): Any {
        try {
            let newArgs = before(qualifiedFunc, args)
            let result = around(qualifiedFunc, newArgs, point)
            after(qualifiedFunc, args, result)
        } catch (e: Exception) {
            throw throwing(qualifiedFunc, args, e)
        } finally {
            final()
        }
    }
}
