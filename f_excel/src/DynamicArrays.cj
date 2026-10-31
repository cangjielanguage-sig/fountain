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

/** `FILTER(array, include, [if_empty])`：按行或按列筛选。 */
internal func fnFilter(ev: Evaluator, args: Array<Expr>): CalcValue {
    let grid = gridOf(ev.arg(args, 0))
    let include = gridOf(ev.arg(args, 1))
    if (grid.size == 0 || include.size == 0) {
        return CalcValue.Error(CalcError.Value)
    }
    var emptyFallback: ?CalcValue = None
    if (args.size > 2) {
        emptyFallback = Some(ev.arg(args, 2))
    }
    let rows = ArrayList<Array<CalcValue>>()
    if (include.size == grid.size && (include[0].size == 1 || include[0].size == grid[0].size)) {
        if (include[0].size == 1) {
            for (row in 0..grid.size) {
                let keep = match (calcToBool(scalarize(include[row][0]))) {
                    case Some(v) => v
                    case None => return CalcValue.Error(CalcError.Value)
                }
                if (keep) {
                    rows.add(grid[row])
                }
            }
        } else {
            let keepCols = ArrayList<Int64>()
            for (col in 0..include[0].size) {
                let keep = match (calcToBool(scalarize(include[0][col]))) {
                    case Some(v) => v
                    case None => return CalcValue.Error(CalcError.Value)
                }
                if (keep) {
                    keepCols.add(col)
                }
            }
            for (row in 0..grid.size) {
                let line = ArrayList<CalcValue>()
                for (col in keepCols) {
                    line.add(if (col < grid[row].size) { grid[row][col] } else { CalcValue.Empty })
                }
                rows.add(line.toArray())
            }
        }
    } else {
        return CalcValue.Error(CalcError.Value)
    }
    if (rows.size == 0 || rows[0].size == 0) {
        return match (emptyFallback) {
            case Some(value) => value
            case None => CalcValue.Error(CalcError.Calc)
        }
    }
    CalcValue.ArrayValue(rows.toArray())
}

/** `SORT(array, [sort_index], [order])`：按某列排序行。 */
internal func fnSort(ev: Evaluator, args: Array<Expr>): CalcValue {
    let grid = gridOf(ev.arg(args, 0))
    if (grid.size == 0) {
        return CalcValue.ArrayValue(Array<Array<CalcValue>>())
    }
    var sortIndex: Int64 = 1
    if (args.size > 1) {
        sortIndex = match (calcToNumber(scalarize(ev.arg(args, 1)))) {
            case Some(v) => Int64(v)
            case None => return CalcValue.Error(CalcError.Value)
        }
    }
    var order: Int64 = 1
    if (args.size > 2) {
        order = match (calcToNumber(scalarize(ev.arg(args, 2)))) {
            case Some(v) => Int64(v)
            case None => return CalcValue.Error(CalcError.Value)
        }
    }
    if (sortIndex < 1 || sortIndex > grid[0].size || (order != 1 && order != -1)) {
        return CalcValue.Error(CalcError.Value)
    }
    let rows = ArrayList<Array<CalcValue>>()
    for (row in grid) {
        rows.add(row)
    }
    for (i in 1..rows.size) {
        let key = rows[i]
        let keyValue = key[sortIndex - 1]
        var j = i - 1
        while (j >= 0) {
            let orderValue = compareCalc(rows[j][sortIndex - 1], keyValue)
            let cmp = match (orderValue) {
                case Some(v) => v
                case None => 0
            }
            let shouldMove = if (order > 0) { cmp > 0 } else { cmp < 0 }
            if (!shouldMove) {
                break
            }
            rows[j + 1] = rows[j]
            j--
        }
        rows[j + 1] = key
    }
    CalcValue.ArrayValue(rows.toArray())
}

/** `UNIQUE(array)`：按整行去重，保留首次出现顺序。 */
internal func fnUnique(ev: Evaluator, args: Array<Expr>): CalcValue {
    let grid = gridOf(ev.arg(args, 0))
    let seen = ArrayList<String>()
    let rows = ArrayList<Array<CalcValue>>()
    for (row in grid) {
        let key = rowKey(row)
        if (!seen.contains(key)) {
            seen.add(key)
            rows.add(row)
        }
    }
    CalcValue.ArrayValue(rows.toArray())
}

private func rowKey(row: Array<CalcValue>): String {
    var out = ""
    for (item in row) {
        out += item.toString()
        out += "\u{1F}"
    }
    out
}

/** `SEQUENCE(rows, [cols], [start], [step])`。 */
internal func fnSequence(ev: Evaluator, args: Array<Expr>): CalcValue {
    let rows = match (calcToNumber(scalarize(ev.arg(args, 0)))) {
        case Some(v) => Int64(v)
        case None => return CalcValue.Error(CalcError.Value)
    }
    var cols: Int64 = 1
    if (args.size > 1) {
        cols = match (calcToNumber(scalarize(ev.arg(args, 1)))) {
            case Some(v) => Int64(v)
            case None => return CalcValue.Error(CalcError.Value)
        }
    }
    var start = 1.0
    if (args.size > 2) {
        start = match (calcToNumber(scalarize(ev.arg(args, 2)))) {
            case Some(v) => v
            case None => return CalcValue.Error(CalcError.Value)
        }
    }
    var step = 1.0
    if (args.size > 3) {
        step = match (calcToNumber(scalarize(ev.arg(args, 3)))) {
            case Some(v) => v
            case None => return CalcValue.Error(CalcError.Value)
        }
    }
    if (rows < 1 || cols < 1 || rows * cols > 1_048_576) {
        return CalcValue.Error(CalcError.Num)
    }
    let out = ArrayList<Array<CalcValue>>()
    var value = start
    for (_ in 0..rows) {
        let line = ArrayList<CalcValue>()
        for (_ in 0..cols) {
            line.add(CalcValue.Number(value))
            value += step
        }
        out.add(line.toArray())
    }
    CalcValue.ArrayValue(out.toArray())
}
