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
package fountain::f_orm.wrap

public class SqlArgs <: Hashable & Equatable<SqlArgs> & ToString {
    protected SqlArgs(private var args: ArrayList<SqlArg>){}
    public init(){
        this.args = ArrayList<SqlArg>()
    }
    // bug-orm.md §3.1 ORM-C3/ORM-L2：原来的 `clone()` 只是换了个壳、与本体共享同一个 ArrayList（不是快照，
    // 日志路径之后再 `add` 会污染已传出的"副本"）。唯一调用点（`SqlExecutor.logMsg`）已改为直接引用原对象，
    // 故删除；需要真快照时应显式复制列表，别再用这个名字。
    protected func set(statement: Statement) {
        for (arg in args) {
            arg.set(statement)
        }
    }
    public func add(arg: SqlArg) {
        args.add(arg)
        // 内容变了必须让 hashCode 的记忆失效（bug.md §1.1 / ORM-1）：
        // 执行器在查询之间会跑空 SQL 的检查类执行，那时 args 还是空的、h 已被算成“空参数”的值；
        // 之后 add 填了参数但 h 不复位，会让同样参数的两个 SqlCacheKey 哈希不同 ⇒ 结果缓存永不命中。
        h = 0
    }
    public func add(arg: Bool) {
        add(BoolSqlArg(args.size, arg))
    }
    public func add(arg: Int8) {
        add(Int8SqlArg(args.size, arg))
    }
    public func add(arg: UInt8) {
        add(UInt8SqlArg(args.size, arg))
    }
    public func add(arg: Int16) {
        add(Int16SqlArg(args.size, arg))
    }
    public func add(arg: UInt16) {
        add(UInt16SqlArg(args.size, arg))
    }
    public func add(arg: Int32) {
        add(Int32SqlArg(args.size, arg))
    }
    public func add(arg: UInt32) {
        add(UInt32SqlArg(args.size, arg))
    }
    public func add(arg: Int64) {
        add(Int64SqlArg(args.size, arg))
    }
    public func add(arg: UInt64) {
        add(UInt64SqlArg(args.size, arg))
    }
    public func add(arg: BigInt) {
        add(BigIntSqlArg(args.size, arg))
    }
    public func add(arg: Decimal) {
        add(DecimalSqlArg(args.size, arg))
    }
    public func add(arg: Float16) {
        add(Float16SqlArg(args.size, arg))
    }
    public func add(arg: Float32) {
        add(Float32SqlArg(args.size, arg))
    }
    public func add(arg: Float64) {
        add(Float64SqlArg(args.size, arg))
    }
    public func add(arg: Rune) {
        add(RuneSqlArg(args.size, arg))
    }
    public func add(arg: String) {
        add(StringSqlArg(args.size, arg))
    }
    public func add(arg: InputStream) {
        add(InputStreamSqlArg(args.size, arg))
    }
    public func add(arg: Duration) {
        add(DurationSqlArg(args.size, arg))
    }
    public func add(arg: DateTime) {
        add(DateTimeSqlArg(args.size, arg))
    }
    public func add(arg: Array<Byte>) {
        add(ByteArraySqlArg(args.size, arg))
    }
    public func addNull() {
        add(NullSqlArg(args.size))
    }
    protected func add(all!: SqlArgs) {
        this.args.add(all: all.args)
        h = 0
    }
    public func toString() {
        args.toString()
    }
    private var h = 0
    public func hashCode() {
        if (h == 0) {
            let hasher = HashBuilder()
            hasher.append(TypeInfo.of<SqlArgs>())
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
