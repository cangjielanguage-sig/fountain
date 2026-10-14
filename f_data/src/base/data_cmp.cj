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
package fountain::f_data.base

public func f_data_eq<T>(a: T, b: T): Bool where T <: Equatable<T> {
    a == b
}

public func f_data_eq<T1, T2>(a: T1, b: T2): Bool {
    match (a) {
        case x: Equatable<T2> => x == b
        case _ => match (b) {
            case x: Equatable<T1> => x == a
            case _ =>
                // 修复历史缺陷：此前兜底返回 true（fail-open），@DataAssist[equal] 生成的逐字段判等会把
                // 「无法比较的字段」视为永远相等（字段不同的两个实例也被判相等）。改为引用相等：
                // 同一实例仍视为相等，否则不等（值类型无法比较时返回 false）。
                match ((a, b)) {
                    case (x: Object, y: Object) => refEq(x, y)
                    case _ => false
                }
        }
    }
}
public func f_data_hash_eq<T>(a: T, b: T): Bool where T <: Hashable {
    a.hashCode() == b.hashCode()
}
public func f_data_hash_eq<T1, T2>(a: T1, b: T2): Bool {
    if(let h1: Hashable <- a && let h2: Hashable <- b){
        h1.hashCode() == h2.hashCode()
    } else {
        // 语义说明：本函数只作 equals 的「哈希快筛」。无法计算哈希时返回 true（不构成否证），
        // 让逐字段比较继续；不能改成 false——只标 equal（无 hash）的类会退化成「除同一引用外恒不等」。
        true
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
            // 语义说明：两侧都不可比较时返回 EQ —— 不可比字段不参与排序（@DataAssist[compare] 保持原行为）。
            case _ => EQ
        }
    }
}
