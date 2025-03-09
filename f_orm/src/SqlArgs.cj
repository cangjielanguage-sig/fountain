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

public open class SqlArgs <: Collection<SqlDbType> & ToString & Hashable & Equatable<SqlArgs> { //sql参数集
    public static let empty = SqlArgs(finished: true)
    private let sqlArgs = ArrayList<SqlDbType>()
    private let args = ArrayList<SqlArg>()
    SqlArgs(private let driverName!: String = String.empty, var finished!: Bool = false) {}

    public func iterator(): Iterator<SqlDbType> {
        sqlArgs.iterator()
    }
    public func toString(): String {
        let builder = StringBuilder("(")
        var i = 0
        while (i < args.size) {
            if (i > 0) {
                builder.append(", ")
            }
            builder.append(args[i])
            i++
        }
        builder.append(")").toString()
    }
    private var h = 0
    public func hashCode(): Int64 {
        if (h == 0) {
            h = HashBuilder().append(args).finish()
        }
        h
    }
    public operator func ==(other: SqlArgs): Bool {
        var eq = hashCode() == other.hashCode() && this.args.size == other.args.size
        var i = 0
        while (eq && i < args.size) {
            eq = args[i] == other.args[i]
            i++
        }
        eq
    }
    public func isEmpty(): Bool {
        sqlArgs.isEmpty()
    }
    public prop size: Int64 {
        get() {
            sqlArgs.size
        }
    }
    public func toArray(): Array<SqlDbType> {
        sqlArgs.toArray()
    }
    private func append(arg: SqlArg) {
        if (finished) {
            throw ORMException("current instance of SqlArgs is finished.")
        }
        sqlArgs.append(SqlDataCreators.generate(driverName, arg.argType, arg.value))
        args.append(arg)
    }
    func append(dataType: DataType, value: Any) {
        append(SqlArg(sqlArgs.size, dataType, value))
    }
    func append(value: Any) {
        match(value){
            case x: SalArg => append(x)
            case _ => append(SqlArg(sqlArgs.size, value))
        }
    }
    public operator func [](index: Int64) {
        sqlArgs[index]
    }
}
