/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_base

public interface OptionComparable<T> where T <: Comparable<T> {
    operator func >(other: ?T): Bool {
        compare(other, noneOrder: Least) == GT
    }
    operator func <(other: ?T): Bool {
        compare(other, noneOrder: Least) == LT
    }
    operator func >=(other: ?T): Bool {
        match (compare(other, noneOrder: Least)) {
            case GT | EQ => true
            case _ => false
        }
    }
    operator func <=(other: ?T): Bool {
        match (compare(other, noneOrder: NoneOrder.Least)) {
            case LT | EQ => true
            case _ => false
        }
    }
    operator func >(other: T): Bool {
        compare(other, noneOrder: Least) == GT
    }
    operator func <(other: T): Bool {
        compare(other, noneOrder: Least) == LT
    }
    operator func >=(other: T): Bool {
        match (compare(other, noneOrder: Least)) {
            case GT | EQ => true
            case _ => false
        }
    }
    operator func <=(other: T): Bool {
        match (compare(other, noneOrder: NoneOrder.Least)) {
            case LT | EQ => true
            case _ => false
        }
    }

    func compare(other: ?T, noneOrder!: NoneOrder): Ordering
}

extend<T> Option<T> <: OptionComparable<T> where T <: Comparable<T> {
    public func compare(other: Option<T>, noneOrder!: NoneOrder = Least): Ordering {
        match ((this, other)) {
            case (Some(v1), Some(v2)) => v1.compare(v2)
            case (Some(_), _) =>
                if (noneOrder.isGreatest) {
                    LT
                } else {
                    GT
                }
            case (_, Some(_)) =>
                if (noneOrder.isLeast) {
                    LT
                } else {
                    GT
                }
            case _ => EQ
        }
    }
}
