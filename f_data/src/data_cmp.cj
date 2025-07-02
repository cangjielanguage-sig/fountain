/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_data

public func f_data_eq<T>(a: T, b: T): Bool where T <: Equatable<T> {
    a == b
}

public func f_data_eq<T1, T2>(a: T1, b: T2): Bool {
    match (a) {
        case x: Equatable<T2> => x == b
        case _ => match (b) {
            case x: Equatable<T1> => x == a
            case _ => true
        }
    }
}

public func f_data_cmp<T>(a: T, b: T): Ordering where T <: Comparable<T> {
    a.compare(b)
}

public func f_data_cmp<T1, T2>(a: T1, b: T2): Ordering {
    match (a) {
        case x: Comparable<T2> => x.compare(b)
        case _ => match (b) {
            case x: Comparable<T1> => match (x.compare(a)) {
                case GT => LT
                case LT => GT
                case _ => EQ
            }
            case _ => EQ
        }
    }
}
