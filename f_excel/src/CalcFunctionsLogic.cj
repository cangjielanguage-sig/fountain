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
package fountain::f_excel

import std.collection.ArrayList

// ---------------------------------------------------------------- 逻辑

internal func fnIf(ev: Evaluator, args: Array<Expr>): CalcValue {
    let condition = ev.arg(args, 0)
    match (firstError([condition])) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let truth = match (calcToBool(scalarize(condition))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    if (args.size == 1) {
        return CalcValue.Boolean(truth)
    }
    if (truth) {
        return ev.arg(args, 1)
    }
    if (args.size > 2) {
        ev.arg(args, 2)
    } else {
        CalcValue.Boolean(false)
    }
}

internal func fnIfs(ev: Evaluator, args: Array<Expr>): CalcValue {
    var i: Int64 = 0
    while (i + 1 < args.size) {
        let condition = ev.arg(args, i)
        match (firstError([condition])) {
            case Some(e) => return CalcValue.Error(e)
            case None => ()
        }
        let truth = match (calcToBool(scalarize(condition))) {
            case Some(v) => v
            case None => return CalcValue.Error(CalcError.Value)
        }
        if (truth) {
            return ev.arg(args, i + 1)
        }
        i += 2
    }
    if (i < args.size) {
        return ev.arg(args, i)
    }
    CalcValue.Error(CalcError.NotAvailable)
}

internal func fnAndOr(ev: Evaluator, args: Array<Expr>, andMode: Bool): CalcValue {
    var trues: Int64 = 0
    var total: Int64 = 0
    for (i in 0..args.size) {
        let value = ev.arg(args, i)
        let items = flattenValues(value)
        if (items.size == 0) {
            match (value) {
                case Error(e) => return CalcValue.Error(e)
                case Empty => ()
                case _ =>
                    let truth = match (calcToBool(scalarize(value))) {
                        case Some(v) => v
                        case None => return CalcValue.Error(CalcError.Value)
                    }
                    total++
                    if (truth) {
                        trues++
                    }
            }
            continue
        }
        for (item in items) {
            match (item) {
                case Error(e) => return CalcValue.Error(e)
                case Empty => ()
                case _ =>
                    let truth = match (calcToBool(item)) {
                        case Some(v) => v
                        case None => return CalcValue.Error(CalcError.Value)
                    }
                    total++
                    if (truth) {
                        trues++
                    }
            }
        }
    }
    if (total == 0) {
        return CalcValue.Error(CalcError.Value)
    }
    if (andMode) {
        return CalcValue.Boolean(trues == total)
    }
    CalcValue.Boolean(trues > 0)
}

internal func fnNot(ev: Evaluator, args: Array<Expr>): CalcValue {
    let value = ev.arg(args, 0)
    match (firstError([value])) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    match (calcToBool(scalarize(value))) {
        case Some(v) => CalcValue.Boolean(!v)
        case None => CalcValue.Error(CalcError.Value)
    }
}

internal func fnXor(ev: Evaluator, args: Array<Expr>): CalcValue {
    var trues: Int64 = 0
    for (i in 0..args.size) {
        for (item in flattenValues(ev.arg(args, i))) {
            match (item) {
                case Error(e) => return CalcValue.Error(e)
                case Empty => ()
                case _ => match (calcToBool(item)) {
                    case Some(v) => if (v) {
                        trues++
                    }
                    case None => return CalcValue.Error(CalcError.Value)
                }
            }
        }
    }
    CalcValue.Boolean(trues % 2 == 1)
}

internal func fnIfError(ev: Evaluator, args: Array<Expr>, naOnly: Bool): CalcValue {
    let value = ev.arg(args, 0)
    match (value) {
        case Error(e) =>
            if (naOnly && e != CalcError.NotAvailable) {
                CalcValue.Error(e)
            } else {
                ev.arg(args, 1)
            }
        case ArrayValue(rows) =>
            if (rows.size == 1 && rows[0].size == 1) {
                match (rows[0][0]) {
                    case Error(e) =>
                        if (naOnly && e != CalcError.NotAvailable) {
                            rows[0][0]
                        } else {
                            ev.arg(args, 1)
                        }
                    case other => other
                }
            } else {
                value
            }
        case _ => value
    }
}

internal func fnSwitch(ev: Evaluator, args: Array<Expr>): CalcValue {
    let target = scalarize(ev.arg(args, 0))
    match (firstError([target])) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    var i: Int64 = 1
    while (i + 1 < args.size) {
        let candidate = ev.arg(args, i)
        if (compareCalc(target, scalarize(candidate)) == Some(0)) {
            return ev.arg(args, i + 1)
        }
        i += 2
    }
    if (i < args.size) {
        return ev.arg(args, i)
    }
    CalcValue.Error(CalcError.NotAvailable)
}

// ---------------------------------------------------------------- 信息

internal func fnIsType(ev: Evaluator, args: Array<Expr>, kind: String): CalcValue {
    let value = scalarize(ev.arg(args, 0))
    match (kind) {
        case "blank" => CalcValue.Boolean(match (value) {
            case Empty => true
            case _ => false
        })
        case "error" => CalcValue.Boolean(match (value) {
            case Error(_) => true
            case _ => false
        })
        case "number" => CalcValue.Boolean(match (value) {
            case Number(_) => true
            case _ => false
        })
        case "text" => CalcValue.Boolean(match (value) {
            case Text(_) => true
            case _ => false
        })
        case "logical" => CalcValue.Boolean(match (value) {
            case Boolean(_) => true
            case _ => false
        })
        case _ => CalcValue.Boolean(match (value) {
            case Error(e) => e == CalcError.NotAvailable
            case _ => false
        })
    }
}
