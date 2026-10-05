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
package fountain::f_aspect

public import fountain::f_aspect.exception.AspectBeforeException
import fountain::f_aspect.exception.AspectException

/**
 * 所有切面必须实现本接口，且必须被@AspectRoute修饰。
 */
public interface Aspect {
    /**
     * 最先执行，先于around 原函数体 after throwing final，默认什么也不做
     */
    func before(funcInfo: InvocationFuncInfo): Unit {
    }
    /**
     * 在around返回后执行，默认是立即返回result
     */
    func after(funcInfo: InvocationFuncInfo, result: Any): Any {
        result
    }
    /**
     * 在before返回后after之前执行，原函数在around内部某个时机执行，由开发者控制，默认是立即执行原函数体
     */
    func around(funcInfo: InvocationFuncInfo, point: (Array<Any>) -> Any): Any {
        point(funcInfo.args)
    }
    /**
     * 在before、原函数体、around、after任意一个抛出异常时执行，默认返回参数e
     */
    func throwing(funcInfo: InvocationFuncInfo, e: Exception): Exception {
        e
    }
    /**
     * 在before、原函数体、around、after、throwing执行完成后执行，默认什么也不做
     */
    func final(funcInfo: InvocationFuncInfo): Unit {}
    /**
     * 开发者可以覆盖这个函数自由定义切面，默认是执行before around 原函数体 after throwing final。
     * 默认实现**不丢弃任何异常**：`final` 抛异常时把它作为主异常、把之前的失败挂到 `suppressed` 上（见 `f_base.BaseException`）。
     */
    func proceed(funcInfo: InvocationFuncInfo, point: (Array<Any>) -> Any): Any {
        var failure = None<Exception>
        try {
            before(funcInfo)
            var result = around(funcInfo, point)
            result = after(funcInfo, result)
            result
        } catch (e: Exception) {
            failure = try {
                throwing(funcInfo, e)
            } catch (ee: Exception) {
                let ex = AspectException(ee)
                ex.addSuppressed(e)
                ex
            }
            // 让 catch 分支以 Never 收尾：异常统一由 finally 合并后抛出
            //（final 也抛时把 failure 挂到 suppressed；final 正常时此处抛出的就是 failure）
            throw failure.getOrThrow()
        } finally {
            try {
                final(funcInfo)
            } catch (e: Exception) {
                match (failure) {
                    case Some(ex) =>
                        let ee = AspectException(e)
                        ee.addSuppressed(ex)
                        throw ee
                    case _ => throw e
                }
            }
        }
    }
}
