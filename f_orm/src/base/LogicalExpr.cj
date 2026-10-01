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

public enum CmpOp <: ToString{
    | EQ
    | NEQ
    | LT
    | LTE
    | GT
    | GTE
    | IN
    | NOT_IN
    | LIKE
    | NOT_LIKE
    | IS_NULL
    | IS_NOT_NULL
    | BETWEEN
    | NOT_BETWEEN
    public func toString(): String {
        match(this){
            case EQ => " = "
            case NEQ => " <> "
            case LT => " < "
            case LTE => " <= "
            case GT => " > "
            case GTE => " >= "
            case IN => " IN "
            case NOT_IN => " NOT IN "
            case LIKE => " LIKE "
            case NOT_LIKE => " NOT LIKE "
            case IS_NULL => " IS NULL "
            case IS_NOT_NULL => " IS NOT NULL "
            case BETWEEN => " BETWEEN "
            case NOT_BETWEEN => " NOT BETWEEN "
        }
    }
}
public abstract class LogicalExpr <: SqlExpr & ToString {}
public class EmptyExpr <: LogicalExpr {
    init(){}
    public func toString(): String {
        ''
    }
    public func AS(alias: String): This {
        this
    }

    public func ASC(): This {
        this
    }
    public func DESC(): This {
        this
    }

    public func eq(arg: Any): LogicalExpr {
        this
    }
    public func neq(arg: Any): LogicalExpr {
        this
    }
    public func lt(arg: Any): LogicalExpr {
        this
    }
    public func gt(arg: Any): LogicalExpr {
        this
    }
    public func lte(arg: Any): LogicalExpr {
        this
    }
    public func gte(arg: Any): LogicalExpr {
        this
    }
    public func IN<T>(arg: Collection<T>): LogicalExpr {
        this
    }
    public func NOT_IN<T>(arg: Collection<T>): LogicalExpr {
        this
    }
    public func IN<T, I>(arg: Collection<I>): LogicalExpr where I <: Collection<T> {
        this
    }
    public func NOT_IN<T, I>(arg: Collection<I>): LogicalExpr where I <: Collection<T> {
        this
    }
    public func LIKE(arg: Any): LogicalExpr {
        this
    }
    public func NOT_LIKE(arg: Any): LogicalExpr {
        this
    }
    public func BETWEEN(one: Any, two: Any): LogicalExpr {
        this
    }
    public func NOT_BETWEEN(one: Any, two: Any): LogicalExpr {
        this
    }
    public func IS_NULL(): LogicalExpr {
        this
    }
    public func IS_NOT_NULL(): LogicalExpr {
        this
    }
}
private struct ExprSqlExec <: RootDAO {}
public open class CmpExpr <: LogicalExpr {
    CmpExpr(
        private let column: SqlExpr,
        private let op: CmpOp,
        private let value: Any
    ){}
    public func toString(): String {
        if(alias_.size > 0 && sort.size > 0){
            throw ORMException('SqlFunc alias and SqlFunc alias cannot be set at the same time')
        }
        let exec = ExprSqlExec()
        let expr = match(op){
            case BETWEEN | NOT_BETWEEN => 
                match(value){
                    case x: Array<Any> => 
                        match((x[0], x[1])){
                            case (x: Column, y: Column) => ' ${column} ${op} ${x} AND ${y} '
                            case _ => ' ${column} ${op} ${exec.arg(x[0])} AND ${exec.arg(x[1])} '
                        }
                    case _ => throw SqlArgException('value must be Array<Any> for BETWEEN or NOT_BETWEEN')
                }
            case IS_NULL | IS_NOT_NULL => ' ${column} ${op} '
            case _ => 
                match(value){
                    case x: SqlExpr => ' ${column} ${op} ${x} '
                    case _ => ' ${column} ${op} ${exec.arg(value)} '
                }
        }
        if(alias_.size > 0){
            let exe = SqlExecutor.getCurrent()
            ' ${expr} AS ${exe.involve(alias_)} '
        }else if(sort.size > 0){
            ' ${expr} ${sort} '
        }else{
            expr
        }
    }
}
public class BetweenExpr <: CmpExpr {
    init(column: SqlExpr, op: CmpOp, value: Array<Any>){
        super(column, op, value)
        match(op){
            case BETWEEN | NOT_BETWEEN => ()
            case _ => throw SqlArgException('op must be BETWEEN or NOT_BETWEEN')

        }
    }
}

public class InExpr<T> <: LogicalExpr {
    InExpr(private let column: SqlExpr, private let op: CmpOp, private let value: Collection<T>){
        match(op){
            case IN | NOT_IN => ()
            case _ => throw SqlArgException('op must be IN or NOT_IN')
        }
    }
    public func toString(): String {
        let exec = ExprSqlExec()
        match(column){
            case x: Column => ' ${x.name} ${op} ${exec.arg<Collection<T>, T>(value)} '
            case x => ' ${x} ${op} ${exec.arg<Collection<T>, T>(value)} '
        }
    }
}
public class In2Expr<I, T> <: LogicalExpr where I <: Collection<T> {
    In2Expr(private let column: SqlExpr, private let op: CmpOp, private let value: Collection<I>){
        match(op){
            case IN | NOT_IN => ()
            case _ => throw SqlArgException('op must be IN or NOT_IN')
        }
    }
    public func toString(): String {
        let exec = ExprSqlExec()
        match(column){
            case x: Column => ' ${x.name} ${op} ${exec.arg<Collection<I>, I, T>(value)} '
            case x => ' ${x} ${op} ${exec.arg<Collection<I>, I, T>(value)} '
        }
    }
}

public class NullExpr <: CmpExpr {
    init(column: SqlExpr, op: CmpOp){
        super(column, op, Option<Any>.None)
        match(op){
            case IS_NULL | IS_NOT_NULL => ()
            case _ => throw SqlArgException('op must be IS_NULL or IS_NOT_NULL')
        }

    }
}

public enum RelationOp <: ToString {
    | AND
    | OR
    | NOT
    public func toString(): String {
        match(this){
            case AND => " AND "
            case OR => " OR "
            case NOT => " NOT "
        }
    }
}
public class RelationExpr <: LogicalExpr & ToString {
    RelationExpr(
        private let op: RelationOp,
        private let exprs: Array<LogicalExpr>
    ){}
    public func toString(): String {
        let builder = StringGenerator()
        if(let NOT <- op){
            builder.append(op)
            if(exprs.size > 1){
                throw SqlArgException('NOT only support one expr')
            }else{
                builder.append(' (').append(exprs[0]).append(') ')
            }
        }else{
            for(expr in exprs){
                let exprstr = expr.toString()
                if(emptyLogicalExpr(exprstr)){
                    continue
                }else if(builder.size > 0){
                    builder.append(op)
                }
                builder.append(' ').append(exprstr).append(' ')
            }
        }
        return builder.toString()
    }
}
public class ParenExpr <: LogicalExpr & ToString {
    ParenExpr(private let expr: LogicalExpr){}
    public func toString(): String {
        let s = expr.toString()
        if(s.isEmpty()){
            return ''
        }
        return '(${expr})'
    }
}
public class CommaExpr <: LogicalExpr & ToString {
    CommaExpr(private let exprs: Array<LogicalExpr>){}
    public func toString(): String {
        let builder = StringBuilder()
        for(expr in exprs){
            if(builder.size > 0){
                builder.append(',')
            }
            builder.append(expr)
        }
        return builder.toString()
    }
}