/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_data

public struct DataToString <: ToString {
    private let builder = StringGenerator()

    public func toString(): String {
        builder.append('}')
        builder.toString()
    }
    public func append<T>(): Unit {
        builder.append(TypeInfos.get<T>())
        builder.append('{')
    }
    public func append(name: String, value: Bool): Unit {
        builder.append('${name}: ${value}; ')
    }
    public func append(name: String, value: Float16): Unit {
        builder.append('${name}: ${value}; ')
    }
    public func append(name: String, value: Float32): Unit {
        builder.append('${name}: ${value}; ')
    }
    public func append(name: String, value: Float64): Unit {
        builder.append('${name}: ${value}; ')
    }
    public func append(name: String, value: Int8): Unit {
        builder.append('${name}: ${value}; ')
    }
    public func append(name: String, value: Int16): Unit {
        builder.append('${name}: ${value}; ')
    }
    public func append(name: String, value: Int32): Unit {
        builder.append('${name}: ${value}; ')
    }
    public func append(name: String, value: Int64): Unit {
        builder.append('${name}: ${value}; ')
    }
    public func append(name: String, value: UInt8): Unit {
        builder.append('${name}: ${value}; ')
    }
    public func append(name: String, value: UInt16): Unit {
        builder.append('${name}: ${value}; ')
    }
    public func append(name: String, value: UInt32): Unit {
        builder.append('${name}: ${value}; ')
    }
    public func append(name: String, value: UInt64): Unit {
        builder.append('${name}: ${value}; ')
    }
    public func append(name: String, value: IntNative): Unit {
        builder.append('${name}: ${value}; ')
    }
    public func append(name: String, value: UIntNative): Unit {
        builder.append('${name}: ${value}; ')
    }
    public func append(name: String, value: Rune): Unit {
        builder.append('${name}: ${value}; ')
    }
    public func append(name: String, value: String): Unit {
        builder.append('${name}: ${value}; ')
    }
    public func append(name: String, value: Duration): Unit {
        builder.append('${name}: ${value}; ')
    }
    public func append(name: String, value: DateTime): Unit {
        builder.append('${name}: ${value}; ')
    }
    public func append(name: String, value: BigInt): Unit {
        builder.append('${name}: ${value}; ')
    }
    public func append(name: String, value: Decimal): Unit {
        builder.append('${name}: ${value}; ')
    }
    public func append<T>(name: String, value: ?T): Unit {
        match (value) {
            case Some(x) => match (x) {
                case v: ToString => builder.append('${name}: ${v}; ')
                case v: Object => append(name, v)
                case _ => builder.append('${name}: _; ')
            }
            case _ => builder.append('${name}: None; ')
        }
    }
    public func append(name: String, value: Object): Unit {
        match (value) {
            case x: ToString => builder.append("${name} = ${x}; ")
            case _ => builder.append('${name}: {_}; ')
        }
    }
    private func append<T>(name: String, value: Collection<T>): Unit {
        builder.append('${name}: ')
        if (value.isEmpty()) {
            builder.append("[]")
            return
        } else if (let x: ToString <- value) {
            builder.append(x)
            return
        }
        builder.append('[')
        var i = 0
        for (v in value) {
            if (i > 0) {
                builder.append(',')
            }
            if (let x: ToString <- v) {
                builder.append(x)
            } else {
                builder.append('_')
            }
            i++
        }
        builder.append(']')
    }
    public func append<T>(name: String, value: Array<T>): Unit {
        let c: Collection<T> = value
        append(name, c)
    }

    public func append<T>(name: String, value: ArrayList<T>): Unit {
        let c: Collection<T> = value
        append(name, c)
    }
    public func append<T>(name: String, value: LinkedList<T>): Unit {
        let c: Collection<T> = value
        append(name, c)
    }
    public func append<T>(name: String, value: HashSet<T>): Unit where T <: Hashable & Equatable<T> {
        let c: Collection<T> = value
        append(name, c)
    }
    public func append<T>(name: String, value: TreeSet<T>): Unit where T <: Comparable<T> {
        let c: Collection<T> = value
        append(name, c)
    }
    public func append<T>(name: String, value: LinkedHashSet<T>): Unit where T <: Hashable & Equatable<T> {
        let c: Collection<T> = value
        append(name, c)
    }
    public func append<T>(name: String, value: ConcurrentHashSet<T>): Unit where T <: Hashable & Equatable<T> {
        let c: Collection<T> = value
        append(name, c)
    }
    private func append<K, V>(name: String, value: Map<K, V>): Unit where K <: Equatable<K> {
        builder.append('${name}: ')
        if (value.isEmpty()) {
            builder.append("{}")
            return
        } else if (let x: ToString <- value) {
            builder.append(x)
            return
        }
        builder.append('{')
        var i = 0
        for ((k, v) in value) {
            if (i > 0) {
                builder.append(',')
            }
            match ((k, v)) {
                case (x: ToString, y: ToString) => builder.append("${x}: ${y}")
                case (_, y: ToString) => builder.append("_: ${y}")
                case (x: ToString, _) => builder.append("${x}: _")
                case _ => builder.append('_')
            }
            i++
        }
        builder.append('}')
    }
    public func append<K, V>(name: String, value: HashMap<K, V>): Unit where K <: Hashable & Equatable<K> {
        let m: Map<K, V> = value
        append<K, V>(name, m)
    }
    public func append<K, V>(name: String, value: TreeMap<K, V>): Unit where K <: Comparable<K> {
        let m: Map<K, V> = value
        append<K, V>(name, m)
    }
    public func append<K, V>(name: String, value: LinkedHashMap<K, V>): Unit where K <: Hashable & Equatable<K> {
        let m: Map<K, V> = value
        append<K, V>(name, m)
    }

    public func append<K, V>(name: String, value: ConcurrentHashMap<K, V>): Unit where K <: Hashable & Equatable<K> {
        builder.append('${name}: ')
        if (let x: ToString <- value) {
            builder.append(x)
            return
        }
        builder.append('{')
        var i = 0
        for ((k, v) in value) {
            if (i > 0) {
                builder.append(',')
            }
            match ((k, v)) {
                case (x: ToString, y: ToString) => builder.append("${x}: ${y}")
                case (_, y: ToString) => builder.append("_: ${y}")
                case (x: ToString, _) => builder.append("${x}: _")
                case _ => builder.append('_')
            }
            i++
        }
        builder.append('}')
    }
}
