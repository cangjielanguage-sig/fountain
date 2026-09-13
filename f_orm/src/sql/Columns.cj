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
package fountain::f_orm.sql

public interface QueryMappersObject<T, C> <: QueryMappersInit<T> where C <: Columns, T <: QueryMappersObject<T, C> {
    static func tableColumns(): C
}

public abstract class Columns <: ToString {
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

public class Column <: ToString {
    public Column(private let name: String){}
    private prop executor: SqlExecutor {
        get(){
            SqlExecutor.getCurrent()
        }
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
    public func toString(): String {
        let exe = executor
        if(alias_.size > 0 && tableAlias_.size > 0){
            return '${exe.involve(tableAlias_)}.${exe.involve(name)} AS ${exe.involve(alias_)}'
        }else if(alias_.size > 0){
            return '${exe.involve(name)} AS ${exe.involve(alias_)}'
        }else if(tableAlias_.size > 0){
            return '${exe.involve(tableAlias_)}.${exe.involve(name)}'
        }
        return exe.involve(name)
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
    public func IN(arg: Any): LogicalExpr {
        CmpExpr(this, CmpOp.IN, arg)
    }
    public func NOT_INT(arg: Any): LogicalExpr {
        CmpExpr(this, NOT_IN, arg)
    }
    public func LIKE(arg: Any): LogicalExpr {
        CmpExpr(this, CmpOp.LIKE, arg)
    }
    public func NOT_LIKE(arg: Any): LogicalExpr {
        CmpExpr(this, CmpOp.NOT_LIKE, arg)
    }
    public func BETWEEN(arg: Array<Any>): LogicalExpr {
        BetweenExpr(this, CmpOp.BETWEEN, arg)
    }
    public func NOT_BETWEEN(arg: Any): LogicalExpr {
        BetweenExpr(this, CmpOp.NOT_BETWEEN, arg)
    }
    public func IS_NULL(): LogicalExpr {
        NullExpr(this, CmpOp.IS_NULL)
    }
    public func IS_NOT_NULL(): LogicalExpr {
        NullExpr(this, CmpOp.IS_NOT_NULL)
    }
}