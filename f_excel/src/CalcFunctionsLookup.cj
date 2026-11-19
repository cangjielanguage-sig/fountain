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

internal func fnVLookup(ev: Evaluator, args: Array<Expr>): CalcValue {
    let lookup = scalarize(ev.arg(args, 0))
    let tableValue = ev.arg(args, 1)
    let colValue = ev.arg(args, 2)
    match (firstError([lookup, tableValue, colValue])) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let grid = gridOf(tableValue)
    if (grid.size == 0) {
        return CalcValue.Error(CalcError.NotAvailable)
    }
    let colIndex = match (calcToNumber(scalarize(colValue))) {
        case Some(v) => Int64(v)
        case None => return CalcValue.Error(CalcError.Value)
    }
    if (colIndex < 1 || colIndex > grid[0].size) {
        return CalcValue.Error(CalcError.Ref)
    }
    var approximate = true
    if (args.size > 3) {
        let flag = ev.arg(args, 3)
        match (firstError([flag])) {
            case Some(e) => return CalcValue.Error(e)
            case None => ()
        }
        approximate = match (calcToBool(scalarize(flag))) {
            case Some(v) => v
            case None => return CalcValue.Error(CalcError.Value)
        }
    }
    var bestRow: Int64 = -1
    for (row in 0..grid.size) {
        if (grid[row].size == 0) {
            continue
        }
        let order = compareCalc(grid[row][0], lookup)
        match (order) {
            case Some(0) => return grid[row][colIndex - 1]
            case Some(v) =>
                if (approximate && v < 0) {
                    bestRow = row
                }
            case None => ()
        }
    }
    if (approximate && bestRow >= 0) {
        return grid[bestRow][colIndex - 1]
    }
    CalcValue.Error(CalcError.NotAvailable)
}

internal func fnIndex(ev: Evaluator, args: Array<Expr>): CalcValue {
    let grid = gridOf(ev.arg(args, 0))
    let rowValue = ev.arg(args, 1)
    match (firstError([rowValue])) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let rowIndex = match (calcToNumber(scalarize(rowValue))) {
        case Some(v) => Int64(v)
        case None => return CalcValue.Error(CalcError.Value)
    }
    if (grid.size == 0) {
        return CalcValue.Error(CalcError.Ref)
    }
    let isSingleRow = grid.size == 1
    let isSingleCol = grid[0].size == 1
    var row = rowIndex
    var col: Int64 = 1
    if (args.size > 2) {
        let colValue = ev.arg(args, 2)
        match (firstError([colValue])) {
            case Some(e) => return CalcValue.Error(e)
            case None => ()
        }
        col = match (calcToNumber(scalarize(colValue))) {
            case Some(v) => Int64(v)
            case None => return CalcValue.Error(CalcError.Value)
        }
    } else if (isSingleRow) {
        col = rowIndex
        row = 1
    }
    if (row < 1 || col < 1 || row > grid.size || col > grid[0].size) {
        if (isSingleRow && args.size == 2 && col >= 1 && col <= grid[0].size) {
            return grid[0][col - 1]
        }
        if (isSingleCol && args.size == 2 && rowIndex >= 1 && rowIndex <= grid.size) {
            return grid[rowIndex - 1][0]
        }
        return CalcValue.Error(CalcError.Ref)
    }
    grid[row - 1][col - 1]
}

internal func fnMatch(ev: Evaluator, args: Array<Expr>): CalcValue {
    let lookup = scalarize(ev.arg(args, 0))
    let grid = gridOf(ev.arg(args, 1))
    match (firstError([lookup])) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    var mode: Int64 = 1
    if (args.size > 2) {
        let modeValue = ev.arg(args, 2)
        match (firstError([modeValue])) {
            case Some(e) => return CalcValue.Error(e)
            case None => ()
        }
        mode = match (calcToNumber(scalarize(modeValue))) {
            case Some(v) => Int64(v)
            case None => return CalcValue.Error(CalcError.Value)
        }
    }
    let items = ArrayList<CalcValue>()
    if (grid.size == 1) {
        for (item in grid[0]) {
            items.add(item)
        }
    } else if (grid.size > 0 && grid[0].size == 1) {
        for (row in grid) {
            items.add(row[0])
        }
    } else {
        for (row in grid) {
            for (item in row) {
                items.add(item)
            }
        }
    }
    var best: Int64 = -1
    for (i in 0..items.size) {
        let orderValue = compareCalc(items[i], lookup)
        if (orderValue.isNone()) {
            continue
        }
        let order = orderValue.getOrThrow()
        if (order == 0) {
            return CalcValue.Number(Float64(i + 1))
        }
        if (mode > 0 && order < 0) {
            best = i
        }
        if (mode < 0 && order > 0 && best < 0) {
            best = i
        }
    }
    if (mode != 0 && best >= 0) {
        return CalcValue.Number(Float64(best + 1))
    }
    CalcValue.Error(CalcError.NotAvailable)
}
