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
package f_orm.wrap

public class SqlArgs <: Hashable & Equatable<SqlArgs> & ToString {
    private let args = ArrayList<SqlArg>()
    protected func clear() {
        args.clear()
    }
    protected func set(statement: Statement) {
        for (arg in args) {
            arg.set(statement)
        }
    }
    public func add(arg: SqlArg) {
        args.add(arg)
    }
    private func index(indexStartsWithZero: Bool): Int64 {
        if (indexStartsWithZero) {
            args.size
        } else {
            args.size + 1
        }
    }
    public func add(indexStartsWithZero: Bool, arg: Bool) {
        add(BoolSqlArg(index(indexStartsWithZero), arg))
    }
    public func add(indexStartsWithZero: Bool, arg: Int8) {
        add(Int8SqlArg(index(indexStartsWithZero), arg))
    }
    public func add(indexStartsWithZero: Bool, arg: UInt8) {
        add(UInt8SqlArg(index(indexStartsWithZero), arg))
    }
    public func add(indexStartsWithZero: Bool, arg: Int16) {
        add(Int16SqlArg(index(indexStartsWithZero), arg))
    }
    public func add(indexStartsWithZero: Bool, arg: UInt16) {
        add(UInt16SqlArg(index(indexStartsWithZero), arg))
    }
    public func add(indexStartsWithZero: Bool, arg: Int32) {
        add(Int32SqlArg(index(indexStartsWithZero), arg))
    }
    public func add(indexStartsWithZero: Bool, arg: UInt32) {
        add(UInt32SqlArg(index(indexStartsWithZero), arg))
    }
    public func add(indexStartsWithZero: Bool, arg: Int64) {
        add(Int64SqlArg(index(indexStartsWithZero), arg))
    }
    public func add(indexStartsWithZero: Bool, arg: UInt64) {
        add(UInt64SqlArg(index(indexStartsWithZero), arg))
    }
    public func add(indexStartsWithZero: Bool, arg: BigInt) {
        add(BigIntSqlArg(index(indexStartsWithZero), arg))
    }
    public func add(indexStartsWithZero: Bool, arg: Decimal) {
        add(DecimalSqlArg(index(indexStartsWithZero), arg))
    }
    public func add(indexStartsWithZero: Bool, arg: Float16) {
        add(Float16SqlArg(index(indexStartsWithZero), arg))
    }
    public func add(indexStartsWithZero: Bool, arg: Float32) {
        add(Float32SqlArg(index(indexStartsWithZero), arg))
    }
    public func add(indexStartsWithZero: Bool, arg: Float64) {
        add(Float64SqlArg(index(indexStartsWithZero), arg))
    }
    public func add(indexStartsWithZero: Bool, arg: Rune) {
        add(RuneSqlArg(index(indexStartsWithZero), arg))
    }
    public func add(indexStartsWithZero: Bool, arg: String) {
        add(StringSqlArg(index(indexStartsWithZero), arg))
    }
    public func add(indexStartsWithZero: Bool, arg: InputStream) {
        add(InputStreamSqlArg(index(indexStartsWithZero), arg))
    }
    public func add(indexStartsWithZero: Bool, arg: Duration) {
        add(DurationSqlArg(index(indexStartsWithZero), arg))
    }
    public func add(indexStartsWithZero: Bool, arg: DateTime) {
        add(DateTimeSqlArg(index(indexStartsWithZero), arg))
    }
    public func add(indexStartsWithZero: Bool, arg: Array<Byte>) {
        add(ByteArraySqlArg(index(indexStartsWithZero), arg))
    }
    public func toString() {
        args.toString()
    }
    private var h = 0
    public func hashCode() {
        if (h == 0) {
            let hasher = HashBuilder()
            hasher.append(TypeInfos.get<SqlArgs>())
            for (arg in args) {
                hasher.append(arg)
            }
            h = hasher.build()
        }
        h
    }
    public operator func ==(other: SqlArgs) {
        refEq(this, other) || args == other.args
    }
}
