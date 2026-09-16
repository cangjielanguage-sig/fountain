/*
Copyright (c) 2026 WuJingrun（吴京润）

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
package fountain::f_orm.base

public interface QueryMappersObject<T, C> <: QueryMappersInit<T> where C <: Columns, T <: QueryMappersObject<T, C> {
    static func tableColumns(): C
}

public abstract class Columns <: ToString & Iterable<Column> {
    private prop executor: SqlExecutor {
        get(){
            SqlExecutor.getCurrent()
        }
    }
    protected var tableAlias_: String = ''
    public func tableAlias(alias: String): This {
        tableAlias_ = alias
        return this
    }
}

public class Column <: ToString & Hashable & Equatable<Column> {
    public Column(let name: String){}
    private prop executor: SqlExecutor {
        get(){
            SqlExecutor.getCurrent()
        }
    }
    public func hashCode(): Int64 {
        name.hashCode()
    }
    public operator func ==(other: Column): Bool {
        name == other.name
    }
    private var alias_: String = ''
    public func AS(alias: String): This {
        alias_ = alias
        return this
    }
    private var tableAlias_: String = ''
    public func tableAlias(alias: String): This {
        tableAlias_ = alias
        return this
    }
    private var sort: String = ''
    public func ASC(): This {
        sort = ' ASC '
        return this
    }
    public func DESC(): This {
        sort = ' DESC '
        return this
    }
    public func toString(): String {
        if(alias_.size > 0 && sort.size > 0){
            throw ORMException('column alias and column alias cannot be set at the same time')
        }
        let exe = executor
        if(alias_.size > 0 && tableAlias_.size > 0){
            return ' ${exe.involve(tableAlias_)}.${exe.involve(name)} AS ${exe.involve(alias_)} '
        }else if(alias_.size > 0){
            return ' ${exe.involve(name)} AS ${exe.involve(alias_)} '
        }else if(tableAlias_.size > 0 && sort.size > 0){
            return ' ${exe.involve(tableAlias_)}.${exe.involve(name)} ${sort} '
        }else if(sort.size > 0){
            return ' ${exe.involve(name)} ${sort} '
        }else if(tableAlias_.size > 0){
            return ' ${exe.involve(tableAlias_)}.${exe.involve(name)} '
        }
        return ' ${exe.involve(name)} '
    }

    public func eq(arg: Any): LogicalExpr {
        CmpExpr(this, EQ, arg)
    }
    public func neq(arg: Any): LogicalExpr {
        CmpExpr(this, NEQ, arg)
    }
    public func lt(arg: Any): LogicalExpr {
        CmpExpr(this, LT, arg)
    }
    public func gt(arg: Any): LogicalExpr {
        CmpExpr(this, GT, arg)
    }
    public func lte(arg: Any): LogicalExpr {
        CmpExpr(this, LTE, arg)
    }
    public func gte(arg: Any): LogicalExpr {
        CmpExpr(this, GTE, arg)
    }
    public func IN<T>(arg: Collection<T>): LogicalExpr {
        InExpr<T>(this, CmpOp.IN, arg)
    }
    public func NOT_IN<T>(arg: Collection<T>): LogicalExpr {
        InExpr<T>(this, CmpOp.NOT_IN, arg)
    }
    public func IN<T, I>(arg: Collection<I>): LogicalExpr where I <: Collection<T> {
        In2Expr<I, T>(this, CmpOp.IN, arg)
    }
    public func NOT_IN<T, I>(arg: Collection<I>): LogicalExpr where I <: Collection<T> {
        In2Expr<I, T>(this, CmpOp.NOT_IN, arg)
    }
    public func LIKE(arg: Any): LogicalExpr {
        CmpExpr(this, CmpOp.LIKE, arg)
    }
    public func NOT_LIKE(arg: Any): LogicalExpr {
        CmpExpr(this, CmpOp.NOT_LIKE, arg)
    }
    public func BETWEEN(one: Any, two: Any): LogicalExpr {
        BetweenExpr(this, CmpOp.BETWEEN, [one, two])
    }
    public func NOT_BETWEEN(one: Any, two: Any): LogicalExpr {
        BetweenExpr(this, CmpOp.NOT_BETWEEN, [one, two])
    }
    public func IS_NULL(): LogicalExpr {
        NullExpr(this, CmpOp.IS_NULL)
    }
    public func IS_NOT_NULL(): LogicalExpr {
        NullExpr(this, CmpOp.IS_NOT_NULL)
    }
}