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
package fountain::fdbm.sql

import std.collection.ArrayList
import std.convert.*
import fountain::f_data.{Data, DataBool, DataNone, DataReal, DataString}
import fountain::f_dbd.common.DbdErrorCode
import fountain::fdbm.exception.FdbmException
import fountain::f_log.LoggerFactory

/**
 * 手写递归下降解析器（设计 §8.2）。
 *
 * - 语法错误 → `FdbmException(SQL_SYNTAX)`（含位置）；
 * - 语法正确但本期不支持（函数、子查询、`group by`、`union`、存储过程等）→ `UNSUPPORTED_SQL`。
 */
protected class SqlParser {
    private static let logger = LoggerFactory.getLogger('fountain::fdbm.sql.SqlParser')

    private let tokens: Array<Token>
    private let currentDatabase: String
    private var cursor: Int64 = 0
    private var parameterIndex: Int64 = 0
    private let original: String

    private init(tokens: Array<Token>, currentDatabase: String, original: String) {
        this.tokens = tokens
        this.currentDatabase = currentDatabase
        this.original = original
    }

    /** 完整解析；`currentDatabase` 用于补全未限定的表名。 */
    public static func parse(sql: String, currentDatabase: String): SqlStatement {
        match (parseSessionCtl(sql)) {
            case Some(statement) => return statement
            case None => ()
        }
        let tokens = Lexer(sql).tokenize()
        let parser = SqlParser(tokens, currentDatabase, sql)
        parser.statement()
    }

    /**
     * 会话控制快速识别：只做关键字/形态匹配，不构造完整 AST。
     *
     * 非会话语句（含词法非法）→ `None`，交给完整解析给出准确的错误码。
     */
    public static func parseSessionCtl(sql: String): ?SessionCtlStatement {
        let tokens = try {
            Lexer(sql).tokenize()
        } catch (_: Exception) {
            return None<SessionCtlStatement>
        }
        var end = tokens.size - 1   // 去掉 End
        while (end > 0 && tokens[end - 1].kind == TokenKind.Semicolon) {
            end -= 1
        }
        if (end == 0) {
            return None<SessionCtlStatement>
        }
        let text = sql.trimAscii()
        let verb: SessionCtlVerb
        var savepoint: ?String = None
        if (tokens[0].isKeyword('begin')) {
            if (end != 1) {
                return None<SessionCtlStatement>
            }
            verb = SessionCtlVerb.Begin
        } else if (tokens[0].isKeyword('start')) {
            if (end != 2 || !tokens[1].isKeyword('transaction')) {
                return None<SessionCtlStatement>
            }
            verb = SessionCtlVerb.Begin
        } else if (tokens[0].isKeyword('commit')) {
            if (end != 1) {
                return None<SessionCtlStatement>
            }
            verb = SessionCtlVerb.Commit
        } else if (tokens[0].isKeyword('rollback')) {
            if (end == 1) {
                verb = SessionCtlVerb.Rollback
            } else {
                var index = 1
                if (tokens[index].isKeyword('to')) {
                    index += 1
                    if (index < end && tokens[index].isKeyword('savepoint')) {
                        index += 1
                    }
                } else if (tokens[index].isKeyword('savepoint')) {
                    index += 1
                }
                if (index != end - 1 || tokens[index].kind != TokenKind.Ident) {
                    return None<SessionCtlStatement>
                }
                savepoint = Some(tokens[index].text)
                verb = SessionCtlVerb.RollbackTo
            }
        } else if (tokens[0].isKeyword('savepoint')) {
            if (end != 2 || tokens[1].kind != TokenKind.Ident) {
                return None<SessionCtlStatement>
            }
            savepoint = Some(tokens[1].text)
            verb = SessionCtlVerb.Savepoint
        } else if (tokens[0].isKeyword('release')) {
            var index = 1
            if (index < end && tokens[index].isKeyword('savepoint')) {
                index += 1
            }
            if (index != end - 1 || tokens[index].kind != TokenKind.Ident) {
                return None<SessionCtlStatement>
            }
            savepoint = Some(tokens[index].text)
            verb = SessionCtlVerb.Release
        } else {
            return None<SessionCtlStatement>
        }
        SessionCtlStatement(verb, savepoint, stripSemicolon(text))
    }

    // ==================== 语句分派 ====================

    private func statement(): SqlStatement {
        if (peek().isKeyword('select')) {
            return finish(select())
        }
        if (peek().isKeyword('insert')) {
            return finish(insert())
        }
        if (peek().isKeyword('update')) {
            return finish(update())
        }
        if (peek().isKeyword('delete')) {
            return finish(delete())
        }
        if (peek().isKeyword('show')) {
            return finish(show())
        }
        if (peek().isKeyword('create') || peek().isKeyword('alter') ||
            peek().isKeyword('drop') || peek().isKeyword('truncate')) {
            return finish(ddl())
        }
        if (peek().isKeyword('export')) {
            return finish(export())
        }
        if (peek().kind == TokenKind.End) {
            throw syntax('empty statement', peek().position)
        }
        if (isKnownButUnsupported()) {
            throw unsupported('${peek().text} is not supported', peek().position)
        }
        throw syntax('unexpected token \'${peek().text}\'', peek().position)
    }

    /** 允许唯一的结尾分号，之后必须结束。 */
    private func finish(statement: SqlStatement): SqlStatement {
        accept(TokenKind.Semicolon)
        if (peek().kind != TokenKind.End) {
            throw syntax('unexpected token \'${peek().text}\'', peek().position)
        }
        statement
    }

    private func isKnownButUnsupported(): Bool {
        let keyword = peek().upperText()
        keyword == 'CALL' || keyword == 'WITH' || keyword == 'MERGE' || keyword == 'GRANT' ||
            keyword == 'REVOKE' || keyword == 'ANALYZE' || keyword == 'EXPLAIN'
    }

    // ==================== SELECT ====================

    private func select(): SelectStatement {
        expectKeyword('select')
        var distinct = matchKeyword('distinct')
        if (!distinct) {
            matchKeyword('all')
        }
        let columns = ArrayList<SelectItem>()
        columns.add(selectItem())
        while (accept(TokenKind.Comma)) {
            columns.add(selectItem())
        }
        let from = ArrayList<TableRef>()
        let joins = ArrayList<JoinClause>()
        if (matchKeyword('from')) {
            from.add(tableRef())
            while (accept(TokenKind.Comma)) {
                from.add(tableRef())
            }
            while (isJoinStart()) {
                joins.add(joinClause())
            }
        }
        let condition = if (matchKeyword('where')) {
            Some(expression())
        } else {
            None<SqlExpression>
        }
        if (peek().isKeyword('group') || peek().isKeyword('having') || peek().isKeyword('union') ||
            peek().isKeyword('window')) {
            throw unsupported('${peek().text} is not supported', peek().position)
        }
        let orderBy = ArrayList<(SqlExpression, Bool)>()
        if (matchKeyword('order')) {
            expectKeyword('by')
            orderBy.add(orderItem())
            while (accept(TokenKind.Comma)) {
                orderBy.add(orderItem())
            }
        }
        var limit: ?SqlExpression = None
        var offset: ?SqlExpression = None
        if (matchKeyword('limit')) {
            let first = limitValue()
            if (accept(TokenKind.Comma)) {
                offset = Some(first)
                limit = Some(limitValue())
            } else {
                limit = Some(first)
                if (matchKeyword('offset')) {
                    offset = Some(limitValue())
                }
            }
        }
        let statement = SelectStatement(distinct, columns.toArray(), from.toArray(), joins.toArray(),
            condition, orderBy.toArray(), limit, offset)
        validateSelectShape(statement)
        statement
    }

    /**
     * 派生表 / `count(*)` 的形状校验（设计 D4）。
     *
     * 只放行 f_orm 分页固定生成的两类语句，其余组合一律 `UNSUPPORTED_SQL`，
     * 避免「能解析但语义不确定」的语句被静默下推。
     */
    /** 派生表计数：覆盖 `from` 与 `joins` 的所有表引用位置（D08）。 */
    private static func derivedTablesOf(statement: SelectStatement): Int64 {
        var count: Int64 = 0
        for (table in statement.from) {
            if (table.derived.isSome()) {
                count += 1
            }
        }
        for (join in statement.joins) {
            if (join.table.derived.isSome()) {
                count += 1
            }
        }
        count
    }

    private func validateSelectShape(statement: SelectStatement): Unit {
        let derivedCount = derivedTablesOf(statement)
        var countColumns: Int64 = 0
        for (item in statement.columns) {
            if (item.expression is CountExpression) {
                countColumns += 1
            }
        }
        if (countColumns > 0 && (countColumns != 1 || statement.columns.size != 1)) {
            throw unsupported('count(*) must be the only select column', peek().position)
        }
        if (countColumns == 1) {
            if (statement.from.isEmpty()) {
                throw unsupported('count(*) requires a from clause', peek().position)
            }
            if (statement.limit.isSome() || statement.offset.isSome() || statement.distinct ||
                !statement.orderBy.isEmpty()) {
                throw unsupported('count(*) cannot be combined with limit/offset/distinct/order by',
                    peek().position)
            }
        }
        if (derivedCount == 0) {
            return
        }
        if (derivedCount != 1 || statement.from.size != 1 || !statement.joins.isEmpty()) {
            throw unsupported('a derived table must be the only from item and cannot be joined',
                peek().position)
        }
        if (statement.condition.isSome() || !statement.orderBy.isEmpty() || statement.distinct) {
            throw unsupported('where / order by / distinct on a derived table is not supported',
                peek().position)
        }
        if (countColumns == 0) {
            for (item in statement.columns) {
                match (item.expression) {
                    case _: StarExpression => ()
                    case _: ColumnExpression => ()
                    case _ => throw unsupported('column expression on a derived table is not supported',
                        peek().position)
                }
            }
        }
    }

    /** `limit` / `offset` 的值：整数或 `?`（与 WHERE 的参数共用同一序号）。 */
    private func limitValue(): SqlExpression {
        if (peek().kind == TokenKind.Question) {
            next()
            let index = parameterIndex
            parameterIndex += 1
            return ParameterExpression(index)
        }
        LiteralExpression(DataReal(integerLiteral()))
    }

    private func selectItem(): SelectItem {
        let expression = if (peek().kind == TokenKind.Operator && peek().text == '*') {
            next()
            StarExpression()
        } else {
            expression()
        }
        var alias: ?String = None
        if (matchKeyword('as')) {
            alias = Some(expectIdent('alias').text)
        } else if (peek().kind == TokenKind.Ident && !isClauseKeyword()) {
            alias = Some(next().text)
        }
        SelectItem(expression, alias)
    }

    private func orderItem(): (SqlExpression, Bool) {
        let expression = expression()
        var asc = true
        if (matchKeyword('asc')) {
            asc = true
        } else if (matchKeyword('desc')) {
            asc = false
        }
        (expression, asc)
    }

    private func isClauseKeyword(): Bool {
        let keyword = peek().upperText()
        keyword == 'FROM' || keyword == 'WHERE' || keyword == 'ORDER' || keyword == 'LIMIT' ||
            keyword == 'OFFSET' || keyword == 'GROUP' || keyword == 'HAVING' || keyword == 'UNION' ||
            keyword == 'JOIN' || keyword == 'INNER' || keyword == 'LEFT' || keyword == 'RIGHT' ||
            keyword == 'ON' || keyword == 'AS' || keyword == 'SET' || keyword == 'USING' ||
            keyword == 'RETURNING'
    }

    private func isJoinStart(): Bool {
        peek().isKeyword('join') || peek().isKeyword('inner') || peek().isKeyword('left') ||
            peek().isKeyword('right')
    }

    private func joinClause(): JoinClause {
        var joinType = JoinType.Inner
        if (matchKeyword('inner')) {
            joinType = JoinType.Inner
        } else if (matchKeyword('left')) {
            joinType = JoinType.Left
            matchKeyword('outer')
        } else if (matchKeyword('right')) {
            joinType = JoinType.Right
            matchKeyword('outer')
        }
        expectKeyword('join')
        let table = tableRef()
        let on = if (matchKeyword('on')) {
            Some(expression())
        } else {
            None<SqlExpression>
        }
        JoinClause(joinType, table, on)
    }

    // ==================== INSERT / UPDATE / DELETE ====================

    private func insert(): InsertStatement {
        expectKeyword('insert')
        expectKeyword('into')
        let table = tableRef(allowAlias: false)
        let columns = ArrayList<Identifier>()
        if (accept(TokenKind.LParen)) {
            columns.add(identifierOf(expectIdent('column')))
            while (accept(TokenKind.Comma)) {
                columns.add(identifierOf(expectIdent('column')))
            }
            expect(TokenKind.RParen, ')')
        }
        let values = ArrayList<Array<SqlExpression>>()
        let setPairs = ArrayList<(Identifier, SqlExpression)>()
        var fromSelect: ?SelectStatement = None
        if (matchKeyword('values') || matchKeyword('value')) {
            values.add(valueRow())
            while (accept(TokenKind.Comma)) {
                values.add(valueRow())
            }
        } else if (matchKeyword('set')) {
            setPairs.add(assignment())
            while (accept(TokenKind.Comma)) {
                setPairs.add(assignment())
            }
        } else if (peek().isKeyword('select')) {
            fromSelect = Some(select())
        } else {
            throw syntax('expect values / set / select after insert into', peek().position)
        }
        let returning = ArrayList<Identifier>()
        if (peek().isKeyword('returning')) {
            if (fromSelect.isSome()) {
                throw unsupported('insert ... select ... returning is not supported', peek().position)
            }
            next()
            returning.add(returningColumn())
            while (accept(TokenKind.Comma)) {
                returning.add(returningColumn())
            }
        }
        InsertStatement(table, columns.toArray(), values.toArray(), setPairs.toArray(), fromSelect,
            returning: returning.toArray())
    }

    /** `returning` 只接受列标识符：`*` / 函数 / 算术表达式一律 `UNSUPPORTED_SQL`。 */
    private func returningColumn(): Identifier {
        let token = peek()
        if (token.kind == TokenKind.Operator || token.kind == TokenKind.LParen) {
            throw unsupported('returning only accepts column identifiers', token.position)
        }
        let column = expectIdent('column')
        if (peek().kind == TokenKind.LParen || peek().kind == TokenKind.Dot ||
            peek().kind == TokenKind.Operator) {
            throw unsupported('returning only accepts column identifiers', peek().position)
        }
        identifierOf(column)
    }

    private func valueRow(): Array<SqlExpression> {
        expect(TokenKind.LParen, '(')
        let row = ArrayList<SqlExpression>()
        if (!accept(TokenKind.RParen)) {
            row.add(expression())
            while (accept(TokenKind.Comma)) {
                row.add(expression())
            }
            expect(TokenKind.RParen, ')')
        }
        row.toArray()
    }

    private func assignment(): (Identifier, SqlExpression) {
        let column = identifierOf(expectIdent('column'))
        expectOperator('=')
        (column, expression())
    }

    /**
     * `update/delete ... join (select ...)` 一律 `UNSUPPORTED_SQL`（D08）。
     *
     * `tableRef` 仍允许解析派生表，由这里统一拒绝，保证错误码一致；错误文案带当前位置。
     */
    private func validateNoDerivedInJoins(joins: Array<JoinClause>, kind: String): Unit {
        for (join in joins) {
            if (join.table.derived.isSome()) {
                throw unsupported('a derived table in ${kind} joins is not supported', peek().position)
            }
        }
    }

    private func update(): UpdateStatement {
        expectKeyword('update')
        let table = tableRef(allowAlias: true)
        let joins = ArrayList<JoinClause>()
        while (isJoinStart()) {
            joins.add(joinClause())
        }
        validateNoDerivedInJoins(joins.toArray(), 'update')
        expectKeyword('set')
        let assignments = ArrayList<(ColumnExpression, SqlExpression)>()
        assignments.add(updateAssignment())
        while (accept(TokenKind.Comma)) {
            assignments.add(updateAssignment())
        }
        let condition = if (matchKeyword('where')) {
            Some(expression())
        } else {
            None<SqlExpression>
        }
        UpdateStatement(table, joins.toArray(), assignments.toArray(), condition)
    }

    private func updateAssignment(): (ColumnExpression, SqlExpression) {
        let first = expectIdent('column')
        var table: ?String = None
        var quoted = first.quoted
        var column = first.text
        if (accept(TokenKind.Dot)) {
            table = Some(first.text)
            let second = expectIdent('column')
            column = second.text
            quoted = quoted || second.quoted
        }
        expectOperator('=')
        (ColumnExpression(table, column, quoted: quoted), expression())
    }

    private func delete(): DeleteStatement {
        expectKeyword('delete')
        expectKeyword('from')
        let table = tableRef(allowAlias: true)
        let joins = ArrayList<JoinClause>()
        while (isJoinStart()) {
            joins.add(joinClause())
        }
        validateNoDerivedInJoins(joins.toArray(), 'delete')
        let condition = if (matchKeyword('where')) {
            Some(expression())
        } else {
            None<SqlExpression>
        }
        DeleteStatement(table, joins.toArray(), condition)
    }

    // ==================== SHOW / DDL / EXPORT ====================

    private func show(): ShowStatement {
        expectKeyword('show')
        if (matchKeyword('databases') || matchKeyword('schemas')) {
            return ShowStatement(ShowKind.Databases, None, None)
        }
        if (matchKeyword('tables')) {
            var database: ?String = None
            if (peek().kind == TokenKind.Ident && !peek().isKeyword('like')) {
                database = Some(next().text)
            }
            var like: ?String = None
            if (matchKeyword('like')) {
                let token = expect(TokenKind.Text, 'pattern')
                like = Some(token.text)
            }
            return ShowStatement(ShowKind.Tables, database, like)
        }
        throw unsupported('show ${peek().text} is not supported', peek().position)
    }

    private func ddl(): DdlStatement {
        let sql = stripSemicolon(original.trimAscii())
        let keyword = next().upperText()
        var table: ?TableRef = None
        if (keyword == 'CREATE' || keyword == 'ALTER' || keyword == 'TRUNCATE') {
            if (matchKeyword('table')) {
                if (matchKeyword('if')) {
                    expectKeyword('not')
                    expectKeyword('exists')
                }
                table = Some(tableRef(allowAlias: false))
            }
        } else {
            // drop table [if exists] t
            if (matchKeyword('table')) {
                if (matchKeyword('if')) {
                    expectKeyword('exists')
                }
                table = Some(tableRef(allowAlias: false))
            }
        }
        cursor = tokens.size - 1
        DdlStatement(sql, table)
    }

    private func export(): ExportStatement {
        expectKeyword('export')
        let key = expect(TokenKind.Ident, 'key').text
        expectOperator('=')
        let token = peek()
        let value = if (token.kind == TokenKind.Text || token.kind == TokenKind.Ident ||
            token.kind == TokenKind.Number) {
            next()
            token.text
        } else {
            throw syntax('expect a value after export key', token.position)
        }
        ExportStatement(key, value)
    }

    // ==================== 表达式 ====================

    private func expression(): SqlExpression {
        orExpression()
    }

    private func orExpression(): SqlExpression {
        var left = andExpression()
        while (matchKeyword('or')) {
            left = BinaryExpression(BinaryOp.Or, left, andExpression())
        }
        left
    }

    private func andExpression(): SqlExpression {
        var left = notExpression()
        while (matchKeyword('and')) {
            left = BinaryExpression(BinaryOp.And, left, notExpression())
        }
        left
    }

    private func notExpression(): SqlExpression {
        if (matchKeyword('not')) {
            return NotExpression(notExpression())
        }
        comparison()
    }

    private func comparison(): SqlExpression {
        let left = additive()
        if (peek().kind == TokenKind.Operator) {
            let op = peek().text
            if (op == '=' || op == '<>' || op == '!=' || op == '<' || op == '<=' || op == '>' || op == '>=') {
                next()
                let binary = match (op) {
                    case '=' => BinaryOp.Eq
                    case '!=' => BinaryOp.Neq
                    case '<>' => BinaryOp.Neq
                    case '<' => BinaryOp.Lt
                    case '<=' => BinaryOp.Lte
                    case '>' => BinaryOp.Gt
                    case _ => BinaryOp.Gte
                }
                return BinaryExpression(binary, left, additive())
            }
        }
        if (matchKeyword('like')) {
            return BinaryExpression(BinaryOp.Like, left, additive())
        }
        if (matchKeyword('in')) {
            return inExpression(left, false)
        }
        if (matchKeyword('not')) {
            if (matchKeyword('in')) {
                return inExpression(left, true)
            }
            throw unsupported('not ... is not supported here', peek().position)
        }
        if (matchKeyword('between')) {
            let low = additive()
            expectKeyword('and')
            let high = additive()
            return BinaryExpression(BinaryOp.And,
                BinaryExpression(BinaryOp.Gte, left, low),
                BinaryExpression(BinaryOp.Lte, left, high))
        }
        left
    }

    private func inExpression(operand: SqlExpression, negated: Bool): InExpression {
        expect(TokenKind.LParen, '(')
        let values = ArrayList<SqlExpression>()
        values.add(expression())
        while (accept(TokenKind.Comma)) {
            values.add(expression())
        }
        expect(TokenKind.RParen, ')')
        InExpression(operand, values.toArray(), negated: negated)
    }

    private func additive(): SqlExpression {
        var left = multiplicative()
        while (true) {
            if (peek().kind == TokenKind.Operator && (peek().text == '+' || peek().text == '-')) {
                let op = if (next().text == '+') { BinaryOp.Add } else { BinaryOp.Sub }
                left = BinaryExpression(op, left, multiplicative())
            } else {
                break
            }
        }
        left
    }

    private func multiplicative(): SqlExpression {
        var left = factor()
        while (true) {
            if (peek().kind == TokenKind.Operator && (peek().text == '*' || peek().text == '/')) {
                let op = if (next().text == '*') { BinaryOp.Mul } else { BinaryOp.Div }
                left = BinaryExpression(op, left, factor())
            } else {
                break
            }
        }
        left
    }

    private func factor(): SqlExpression {
        let token = peek()
        match (token.kind) {
            case TokenKind.Number =>
                next()
                return LiteralExpression(numberOf(token))
            case TokenKind.Text =>
                next()
                return LiteralExpression(DataString(token.text))
            case TokenKind.HexText =>
                next()
                return HexLiteralExpression(token.text)
            case TokenKind.Question =>
                next()
                let index = parameterIndex
                parameterIndex += 1
                return ParameterExpression(index)
            case TokenKind.LParen =>
                next()
                let inner = expression()
                expect(TokenKind.RParen, ')')
                return inner
            case TokenKind.Operator =>
                if (token.text == '*') {
                    next()
                    return StarExpression()
                }
                if (token.text == '-') {
                    next()
                    let number = expect(TokenKind.Number, 'number')
                    return LiteralExpression(negatedNumberOf(number))
                }
                throw syntax('unexpected operator \'${token.text}\'', token.position)
            case TokenKind.Ident =>
                if (token.isKeyword('null')) {
                    next()
                    return LiteralExpression(DataNone.INSTANCE)
                }
                if (token.isKeyword('true') || token.isKeyword('false')) {
                    next()
                    return LiteralExpression(if (token.isKeyword('true')) { DataBool.TRUE } else { DataBool.FALSE })
                }
                next()
                if (accept(TokenKind.LParen)) {
                    // 只支持 count(*)；其余函数（含 count(1) / count(col)）保持拒绝
                    if (!token.quoted && token.isKeyword('count') &&
                        peek().kind == TokenKind.Operator && peek().text == '*') {
                        next()
                        expect(TokenKind.RParen, ')')
                        return CountExpression()
                    }
                    let args = ArrayList<SqlExpression>()
                    if (!accept(TokenKind.RParen)) {
                        args.add(expression())
                        while (accept(TokenKind.Comma)) {
                            args.add(expression())
                        }
                        expect(TokenKind.RParen, ')')
                    }
                    throw unsupported('function call \'${token.text}\' is not supported', token.position)
                }
                if (accept(TokenKind.Dot)) {
                    let column = expectIdent('column')
                    return ColumnExpression(Some(token.text), column.text,
                        quoted: token.quoted || column.quoted)
                }
                return ColumnExpression(None, token.text, quoted: token.quoted)
            case _ => throw syntax('unexpected token \'${token.text}\'', token.position)
        }
        throw syntax('unexpected token \'${token.text}\'', token.position)
    }

    /**
     * 数值字面量（D07）：`Int64` 优先；超出范围按**原文**交给 `Decimal`，不经 `Float64` 中转。
     * `Decimal` 不接受时才回退 `Float64`（记 WARN），仍失败 → `SQL_SYNTAX`。
     */
    private static func numberOf(token: Token): Data {
        let text = token.text
        if (!text.contains('.') && !text.contains('e') && !text.contains('E')) {
            match (Int64.tryParse(text)) {
                case Some(value) => return DataReal(value)
                case None => ()
            }
        }
        match (decimalOf(text)) {
            case Some(value) => return value
            case None => ()
        }
        match (Float64.tryParse(text)) {
            case Some(value) =>
                logger.warn('number \'${text}\' is not representable as Decimal, falling back to Float64')
                DataReal(value)
            case None => throw FdbmException(DbdErrorCode.SQL_SYNTAX,
                'illegal number \'${text}\' at position ${token.position}')
        }
    }

    private static func negatedNumberOf(token: Token): Data {
        let text = token.text
        if (!text.contains('.') && !text.contains('e') && !text.contains('E')) {
            match (Int64.tryParse(text)) {
                case Some(value) => return DataReal(-value)
                case None => ()
            }
        }
        match (decimalOf('-${text}')) {
            case Some(value) => return value
            case None => ()
        }
        match (Float64.tryParse(text)) {
            case Some(value) =>
                logger.warn('number \'-${text}\' is not representable as Decimal, falling back to Float64')
                DataReal(-value)
            case None => throw FdbmException(DbdErrorCode.SQL_SYNTAX,
                'illegal number \'${text}\' at position ${token.position}')
        }
    }

    private static func decimalOf(text: String): ?Data {
        try {
            Some(DataReal(text))
        } catch (_: Exception) {
            None<Data>
        }
    }

    // ==================== 基础 ====================

    private func tableRef(allowAlias!: Bool = true): TableRef {
        if (allowAlias && peek().kind == TokenKind.LParen) {
            let start = peek().position
            next()
            if (!peek().isKeyword('select')) {
                throw syntax('expect select in a derived table', peek().position)
            }
            let inner = select()
            expect(TokenKind.RParen, ')')
            var alias: ?String = None
            if (matchKeyword('as')) {
                alias = Some(expectIdent('alias').text)
            } else if (peek().kind == TokenKind.Ident && !isClauseKeyword()) {
                alias = Some(next().text)
            }
            match (alias) {
                case Some(value) => return TableRef(None, '', alias, currentDatabase,
                    derived: Some(inner))
                case None => throw syntax('a derived table requires an alias', start)
            }
        }
        let first = expectIdent('table name')
        var database: ?String = None
        var name = first.text
        if (accept(TokenKind.Dot)) {
            database = Some(first.text)
            name = expectIdent('table name').text
        }
        var alias: ?String = None
        if (allowAlias) {
            if (matchKeyword('as')) {
                alias = Some(expectIdent('alias').text)
            } else if (peek().kind == TokenKind.Ident && !isClauseKeyword()) {
                alias = Some(next().text)
            }
        }
        TableRef(database, name, alias, currentDatabase, quoted: first.quoted)
    }

    private static func identifierOf(token: Token): Identifier {
        Identifier(token.text, quoted: token.quoted)
    }

    private func integerLiteral(): Int64 {
        let token = expect(TokenKind.Number, 'number')
        match (Int64.tryParse(token.text)) {
            case Some(value) => value
            case None => throw syntax('expect an integer, got \'${token.text}\'', token.position)
        }
    }

    private func peek(): Token {
        tokens[cursor]
    }

    private func next(): Token {
        let token = tokens[cursor]
        if (cursor < tokens.size - 1) {
            cursor += 1
        }
        token
    }

    private func accept(kind: TokenKind): Bool {
        if (peek().kind == kind) {
            next()
            return true
        }
        false
    }

    private func matchKeyword(word: String): Bool {
        if (peek().isKeyword(word)) {
            next()
            return true
        }
        false
    }

    private func expect(kind: TokenKind, what: String): Token {
        if (peek().kind != kind) {
            throw syntax('expect ${what}, got \'${peek().text}\'', peek().position)
        }
        next()
    }

    private func expectOperator(text: String): Token {
        if (peek().kind != TokenKind.Operator || peek().text != text) {
            throw syntax('expect \'${text}\', got \'${peek().text}\'', peek().position)
        }
        next()
    }

    private func expectKeyword(word: String): Token {
        if (!peek().isKeyword(word)) {
            throw syntax('expect ${word}, got \'${peek().text}\'', peek().position)
        }
        next()
    }

    private func expectIdent(what: String): Token {
        if (peek().kind != TokenKind.Ident) {
            throw syntax('expect ${what}, got \'${peek().text}\'', peek().position)
        }
        next()
    }

    private static func stripSemicolon(text: String): String {
        let trimmed = text.trimAscii()
        if (trimmed.endsWith(';')) {
            return trimmed[0..trimmed.size - 1].trimAscii()
        }
        trimmed
    }

    private static func syntax(message: String, position: Int64): FdbmException {
        FdbmException(DbdErrorCode.SQL_SYNTAX, '${message} at position ${position}')
    }

    private static func unsupported(message: String, position: Int64): FdbmException {
        FdbmException(DbdErrorCode.UNSUPPORTED_SQL, '${message} at position ${position}')
    }
}
