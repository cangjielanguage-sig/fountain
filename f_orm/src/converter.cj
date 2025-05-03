/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
           http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */

package f_orm

import f_orm.exception.ORMException

public func convert<T>(value: Any): T {
    match (value) {
        case x: T => x
        case x: ?T => x.getOrThrow{ORMException('value is none')}
        case x: ToString => match (x.toString()) {
            case x: T => x
            case _ => throw ORMException("type of param does not match generic type")
        }
        case _ => throw ORMException("type of param does not match generic type")
    }
}
