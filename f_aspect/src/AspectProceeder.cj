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

import f_base.*
import f_exception.TypeCastException

let recursiveInvocationFlag = ThreadLocal<Bool>()
/**本函数不是给开发者用的，是给@PointCut生成切点使用的*/
public func AspectProceeder<T>(serial: UInt64, name: String, args: Array<Any>, argTypes: Array<TypeInfo>, returnType: TypeInfo, fn: () -> Any): T {
    func setRecursiveSerial() {
        try {
            recursiveInvocationFlag.set(true)
            Aspects.proceed(name, args, argTypes, returnType, fn)
        } finally {
            recursiveInvocationFlag.remove()
        }
    }
    let result = if (serial == 0) {
        Aspects.proceed(name, args, argTypes, returnType, fn)
    } else {
        match (recursiveInvocationFlag.get()) {
            case Some(_) => fn()
            case _ => setRecursiveSerial()
        }
    }
    match (result) {
        case x: T => x
        case _ => throw TypeCastException()
    }
}
