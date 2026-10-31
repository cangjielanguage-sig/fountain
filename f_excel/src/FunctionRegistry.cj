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

internal type FnImpl = (Evaluator, Array<Expr>) -> CalcValue

/** 函数注册项：`maxArgs = -1` 表示可变参数。 */
internal struct FnEntry {
    public let name: String
    public let minArgs: Int64
    public let maxArgs: Int64
    public let impl: FnImpl

    public init(name: String, minArgs: Int64, maxArgs: Int64, impl: FnImpl) {
        this.name = name
        this.minArgs = minArgs
        this.maxArgs = maxArgs
        this.impl = impl
    }
}

/** 按名查找（大小写不敏感）；未注册返回 `None`。 */
internal func lookupFunction(rawName: String): ?FnEntry {
    let name = rawName.toAsciiUpper()
    match (name) {
        // 数学
        case "SUM" => Some(FnEntry(name, 1, -1, { ev, args => fnSum(ev, args) }))
        case "PRODUCT" => Some(FnEntry(name, 1, -1, { ev, args => fnProduct(ev, args) }))
        case "ABS" => Some(FnEntry(name, 1, 1, { ev, args => fnUnaryMath(ev, args, "abs") }))
        case "SIGN" => Some(FnEntry(name, 1, 1, { ev, args => fnUnaryMath(ev, args, "sign") }))
        case "SQRT" => Some(FnEntry(name, 1, 1, { ev, args => fnUnaryMath(ev, args, "sqrt") }))
        case "INT" => Some(FnEntry(name, 1, 1, { ev, args => fnUnaryMath(ev, args, "int") }))
        case "ROUND" => Some(FnEntry(name, 1, 2, { ev, args => fnRound(ev, args, "round") }))
        case "ROUNDUP" => Some(FnEntry(name, 1, 2, { ev, args => fnRound(ev, args, "up") }))
        case "ROUNDDOWN" => Some(FnEntry(name, 1, 2, { ev, args => fnRound(ev, args, "down") }))
        case "TRUNC" => Some(FnEntry(name, 1, 2, { ev, args => fnRound(ev, args, "down") }))
        case "MOD" => Some(FnEntry(name, 2, 2, { ev, args => fnMod(ev, args) }))
        case "POWER" => Some(FnEntry(name, 2, 2, { ev, args => fnPower(ev, args) }))
        case "SUMIF" => Some(FnEntry(name, 2, 3, { ev, args => fnSumIf(ev, args) }))
        case "SUMIFS" => Some(FnEntry(name, 3, -1, { ev, args => fnSumIfs(ev, args) }))
        // 统计
        case "AVERAGE" => Some(FnEntry(name, 1, -1, { ev, args => fnAverage(ev, args) }))
        case "AVERAGEIF" => Some(FnEntry(name, 2, 3, { ev, args => fnAverageIf(ev, args) }))
        case "COUNT" => Some(FnEntry(name, 1, -1, { ev, args => fnCount(ev, args) }))
        case "COUNTA" => Some(FnEntry(name, 1, -1, { ev, args => fnCountA(ev, args) }))
        case "COUNTBLANK" => Some(FnEntry(name, 1, 1, { ev, args => fnCountBlank(ev, args) }))
        case "COUNTIF" => Some(FnEntry(name, 2, 2, { ev, args => fnCountIf(ev, args) }))
        case "COUNTIFS" => Some(FnEntry(name, 2, -1, { ev, args => fnCountIfs(ev, args) }))
        case "MIN" => Some(FnEntry(name, 1, -1, { ev, args => fnMinMax(ev, args, true) }))
        case "MAX" => Some(FnEntry(name, 1, -1, { ev, args => fnMinMax(ev, args, false) }))
        case "MEDIAN" => Some(FnEntry(name, 1, -1, { ev, args => fnMedian(ev, args) }))
        // 逻辑
        case "IF" => Some(FnEntry(name, 1, 3, { ev, args => fnIf(ev, args) }))
        case "IFS" => Some(FnEntry(name, 2, -1, { ev, args => fnIfs(ev, args) }))
        case "AND" => Some(FnEntry(name, 1, -1, { ev, args => fnAndOr(ev, args, true) }))
        case "OR" => Some(FnEntry(name, 1, -1, { ev, args => fnAndOr(ev, args, false) }))
        case "NOT" => Some(FnEntry(name, 1, 1, { ev, args => fnNot(ev, args) }))
        case "XOR" => Some(FnEntry(name, 1, -1, { ev, args => fnXor(ev, args) }))
        case "IFERROR" => Some(FnEntry(name, 2, 2, { ev, args => fnIfError(ev, args, false) }))
        case "IFNA" => Some(FnEntry(name, 2, 2, { ev, args => fnIfError(ev, args, true) }))
        case "SWITCH" => Some(FnEntry(name, 3, -1, { ev, args => fnSwitch(ev, args) }))
        // 文本
        case "CONCATENATE" => Some(FnEntry(name, 1, -1, { ev, args => fnConcat(ev, args) }))
        case "CONCAT" => Some(FnEntry(name, 1, -1, { ev, args => fnConcat(ev, args) }))
        case "LEN" => Some(FnEntry(name, 1, 1, { ev, args => fnLen(ev, args) }))
        case "LEFT" => Some(FnEntry(name, 1, 2, { ev, args => fnLeftRight(ev, args, true) }))
        case "RIGHT" => Some(FnEntry(name, 1, 2, { ev, args => fnLeftRight(ev, args, false) }))
        case "MID" => Some(FnEntry(name, 3, 3, { ev, args => fnMid(ev, args) }))
        case "TRIM" => Some(FnEntry(name, 1, 1, { ev, args => fnTrim(ev, args) }))
        case "UPPER" => Some(FnEntry(name, 1, 1, { ev, args => fnCase(ev, args, true) }))
        case "LOWER" => Some(FnEntry(name, 1, 1, { ev, args => fnCase(ev, args, false) }))
        case "TEXT" => Some(FnEntry(name, 2, 2, { ev, args => fnText(ev, args) }))
        case "VALUE" => Some(FnEntry(name, 1, 1, { ev, args => fnValue(ev, args) }))
        // 日期
        case "DATE" => Some(FnEntry(name, 3, 3, { ev, args => fnDate(ev, args) }))
        case "YEAR" => Some(FnEntry(name, 1, 1, { ev, args => fnDatePart(ev, args, "year") }))
        case "MONTH" => Some(FnEntry(name, 1, 1, { ev, args => fnDatePart(ev, args, "month") }))
        case "DAY" => Some(FnEntry(name, 1, 1, { ev, args => fnDatePart(ev, args, "day") }))
        case "HOUR" => Some(FnEntry(name, 1, 1, { ev, args => fnDatePart(ev, args, "hour") }))
        case "MINUTE" => Some(FnEntry(name, 1, 1, { ev, args => fnDatePart(ev, args, "minute") }))
        case "SECOND" => Some(FnEntry(name, 1, 1, { ev, args => fnDatePart(ev, args, "second") }))
        case "TODAY" => Some(FnEntry(name, 0, 0, { ev, args => CalcValue.Number(ev.todaySerial()) }))
        case "NOW" => Some(FnEntry(name, 0, 0, { ev, args => CalcValue.Number(ev.nowSerial()) }))
        // 查找
        case "VLOOKUP" => Some(FnEntry(name, 3, 4, { ev, args => fnVLookup(ev, args) }))
        case "INDEX" => Some(FnEntry(name, 2, 3, { ev, args => fnIndex(ev, args) }))
        case "MATCH" => Some(FnEntry(name, 2, 3, { ev, args => fnMatch(ev, args) }))
        // 信息
        case "ISBLANK" => Some(FnEntry(name, 1, 1, { ev, args => fnIsType(ev, args, "blank") }))
        case "ISERROR" => Some(FnEntry(name, 1, 1, { ev, args => fnIsType(ev, args, "error") }))
        case "ISNUMBER" => Some(FnEntry(name, 1, 1, { ev, args => fnIsType(ev, args, "number") }))
        case "ISTEXT" => Some(FnEntry(name, 1, 1, { ev, args => fnIsType(ev, args, "text") }))
        case "ISLOGICAL" => Some(FnEntry(name, 1, 1, { ev, args => fnIsType(ev, args, "logical") }))
        case "ISNA" => Some(FnEntry(name, 1, 1, { ev, args => fnIsType(ev, args, "na") }))
        // 统计扩展
        case "STDEV.P" => Some(FnEntry(name, 1, -1, { ev, args => fnStdev(ev, args, false) }))
        case "STDEV.S" => Some(FnEntry(name, 1, -1, { ev, args => fnStdev(ev, args, true) }))
        case "VAR.P" => Some(FnEntry(name, 1, -1, { ev, args => fnVariance(ev, args, false) }))
        case "VAR.S" => Some(FnEntry(name, 1, -1, { ev, args => fnVariance(ev, args, true) }))
        case "LARGE" => Some(FnEntry(name, 2, 2, { ev, args => fnLargeSmall(ev, args, true) }))
        case "SMALL" => Some(FnEntry(name, 2, 2, { ev, args => fnLargeSmall(ev, args, false) }))
        case "RANK" => Some(FnEntry(name, 2, 3, { ev, args => fnRank(ev, args) }))
        case "PERCENTILE" => Some(FnEntry(name, 2, 2, { ev, args => fnPercentile(ev, args) }))
        case "QUARTILE" => Some(FnEntry(name, 2, 2, { ev, args => fnQuartile(ev, args) }))
        case "MODE" => Some(FnEntry(name, 1, -1, { ev, args => fnMode(ev, args) }))
        case "CORREL" => Some(FnEntry(name, 2, 2, { ev, args => fnCorrel(ev, args) }))
        case "SLOPE" => Some(FnEntry(name, 2, 2, { ev, args => fnSlopeIntercept(ev, args, true) }))
        case "INTERCEPT" => Some(FnEntry(name, 2, 2, { ev, args => fnSlopeIntercept(ev, args, false) }))
        case "FORECAST" => Some(FnEntry(name, 3, 3, { ev, args => fnForecast(ev, args) }))
        // 查找扩展
        case "HLOOKUP" => Some(FnEntry(name, 3, 4, { ev, args => fnHLookup(ev, args) }))
        case "LOOKUP" => Some(FnEntry(name, 2, 3, { ev, args => fnLookup(ev, args) }))
        case "XLOOKUP" => Some(FnEntry(name, 3, 6, { ev, args => fnXLookup(ev, args) }))
        case "CHOOSE" => Some(FnEntry(name, 2, -1, { ev, args => fnChoose(ev, args) }))
        case "OFFSET" => Some(FnEntry(name, 3, 5, { ev, args => fnOffset(ev, args) }))
        case "INDIRECT" => Some(FnEntry(name, 1, 2, { ev, args => fnIndirect(ev, args) }))
        case "ROW" => Some(FnEntry(name, 0, 1, { ev, args => fnRowColumn(ev, args, true) }))
        case "COLUMN" => Some(FnEntry(name, 0, 1, { ev, args => fnRowColumn(ev, args, false) }))
        case "ROWS" => Some(FnEntry(name, 1, 1, { ev, args => fnRowsColumns(ev, args, true) }))
        case "COLUMNS" => Some(FnEntry(name, 1, 1, { ev, args => fnRowsColumns(ev, args, false) }))
        case "TRANSPOSE" => Some(FnEntry(name, 1, 1, { ev, args => fnTranspose(ev, args) }))
        // 文本扩展
        case "SUBSTITUTE" => Some(FnEntry(name, 3, 4, { ev, args => fnSubstitute(ev, args) }))
        case "REPLACE" => Some(FnEntry(name, 4, 4, { ev, args => fnReplace(ev, args) }))
        case "FIND" => Some(FnEntry(name, 2, 3, { ev, args => fnFindSearch(ev, args, true) }))
        case "SEARCH" => Some(FnEntry(name, 2, 3, { ev, args => fnFindSearch(ev, args, false) }))
        case "REPT" => Some(FnEntry(name, 2, 2, { ev, args => fnRept(ev, args) }))
        case "TEXTJOIN" => Some(FnEntry(name, 3, -1, { ev, args => fnTextJoin(ev, args) }))
        case "EXACT" => Some(FnEntry(name, 2, 2, { ev, args => fnExact(ev, args) }))
        case "PROPER" => Some(FnEntry(name, 1, 1, { ev, args => fnProper(ev, args) }))
        case "CLEAN" => Some(FnEntry(name, 1, 1, { ev, args => fnClean(ev, args) }))
        case "CHAR" => Some(FnEntry(name, 1, 1, { ev, args => fnCharCode(ev, args, true) }))
        case "CODE" => Some(FnEntry(name, 1, 1, { ev, args => fnCharCode(ev, args, false) }))
        case "UNICHAR" => Some(FnEntry(name, 1, 1, { ev, args => fnCharCode(ev, args, true) }))
        case "UNICODE" => Some(FnEntry(name, 1, 1, { ev, args => fnCharCode(ev, args, false) }))
        case "T" => Some(FnEntry(name, 1, 1, { ev, args => fnT(ev, args) }))
        // 数学扩展
        case "SUMPRODUCT" => Some(FnEntry(name, 1, -1, { ev, args => fnSumProduct(ev, args) }))
        case "CEILING" => Some(FnEntry(name, 1, 2, { ev, args => fnCeilingFloor(ev, args, true) }))
        case "FLOOR" => Some(FnEntry(name, 1, 2, { ev, args => fnCeilingFloor(ev, args, false) }))
        case "MROUND" => Some(FnEntry(name, 2, 2, { ev, args => fnMround(ev, args) }))
        case "RAND" => Some(FnEntry(name, 0, 0, { ev, args => fnRand(ev, args) }))
        case "RANDBETWEEN" => Some(FnEntry(name, 2, 2, { ev, args => fnRandBetween(ev, args) }))
        case "LOG" => Some(FnEntry(name, 1, 2, { ev, args => fnLogBase(ev, args, -1.0) }))
        case "LOG10" => Some(FnEntry(name, 1, 1, { ev, args => fnLogBase(ev, args, 10.0) }))
        case "LN" => Some(FnEntry(name, 1, 1, { ev, args => fnLogBase(ev, args, 2.718281828459045) }))
        case "EXP" => Some(FnEntry(name, 1, 1, { ev, args => fnExp(ev, args) }))
        case "PI" => Some(FnEntry(name, 0, 0, { ev, args => fnPi(ev, args) }))
        case "SIN" => Some(FnEntry(name, 1, 1, { ev, args => fnTrig(ev, args, "sin") }))
        case "COS" => Some(FnEntry(name, 1, 1, { ev, args => fnTrig(ev, args, "cos") }))
        case "TAN" => Some(FnEntry(name, 1, 1, { ev, args => fnTrig(ev, args, "tan") }))
        case "DEGREES" => Some(FnEntry(name, 1, 1, { ev, args => fnTrig(ev, args, "degrees") }))
        case "RADIANS" => Some(FnEntry(name, 1, 1, { ev, args => fnTrig(ev, args, "radians") }))
        case "GCD" => Some(FnEntry(name, 1, -1, { ev, args => fnGcdLcm(ev, args, true) }))
        case "LCM" => Some(FnEntry(name, 1, -1, { ev, args => fnGcdLcm(ev, args, false) }))
        case "FACT" => Some(FnEntry(name, 1, 1, { ev, args => fnFact(ev, args) }))
        // 日期扩展
        case "DATEVALUE" => Some(FnEntry(name, 1, 1, { ev, args => fnDateValue(ev, args) }))
        case "TIMEVALUE" => Some(FnEntry(name, 1, 1, { ev, args => fnTimeValue(ev, args) }))
        case "EDATE" => Some(FnEntry(name, 2, 2, { ev, args => fnEdate(ev, args, false) }))
        case "EOMONTH" => Some(FnEntry(name, 2, 2, { ev, args => fnEdate(ev, args, true) }))
        case "WEEKDAY" => Some(FnEntry(name, 1, 2, { ev, args => fnWeekday(ev, args) }))
        case "WEEKNUM" => Some(FnEntry(name, 1, 2, { ev, args => fnWeeknum(ev, args) }))
        case "DATEDIF" => Some(FnEntry(name, 3, 3, { ev, args => fnDatedif(ev, args) }))
        case "DAYS" => Some(FnEntry(name, 2, 2, { ev, args => fnDays(ev, args) }))
        case "DAYS360" => Some(FnEntry(name, 2, 3, { ev, args => fnDays360(ev, args) }))
        case "NETWORKDAYS" => Some(FnEntry(name, 2, 3, { ev, args => fnNetworkdays(ev, args) }))
        case "WORKDAY" => Some(FnEntry(name, 2, 3, { ev, args => fnWorkday(ev, args) }))
        // 财务
        case "PMT" => Some(FnEntry(name, 3, 5, { ev, args => fnPmt(ev, args) }))
        case "FV" => Some(FnEntry(name, 3, 5, { ev, args => fnFv(ev, args) }))
        case "PV" => Some(FnEntry(name, 3, 5, { ev, args => fnPv(ev, args) }))
        case "NPER" => Some(FnEntry(name, 3, 5, { ev, args => fnNper(ev, args) }))
        case "SLN" => Some(FnEntry(name, 3, 3, { ev, args => fnSln(ev, args) }))
        case "NPV" => Some(FnEntry(name, 2, -1, { ev, args => fnNpv(ev, args) }))
        case "IPMT" => Some(FnEntry(name, 4, 6, { ev, args => fnIpmt(ev, args) }))
        case "PPMT" => Some(FnEntry(name, 4, 6, { ev, args => fnPpmt(ev, args) }))
        // 信息扩展
        case "ISERR" => Some(FnEntry(name, 1, 1, { ev, args => fnIsErr(ev, args) }))
        case "NA" => Some(FnEntry(name, 0, 0, { ev, args => fnNa(ev, args) }))
        case "TYPE" => Some(FnEntry(name, 1, 1, { ev, args => fnType(ev, args) }))
        case "ERROR.TYPE" => Some(FnEntry(name, 1, 1, { ev, args => fnErrorType(ev, args) }))
        // 动态数组（M3-b）
        case "FILTER" => Some(FnEntry(name, 2, 3, { ev, args => fnFilter(ev, args) }))
        case "SORT" => Some(FnEntry(name, 1, 3, { ev, args => fnSort(ev, args) }))
        case "UNIQUE" => Some(FnEntry(name, 1, 1, { ev, args => fnUnique(ev, args) }))
        case "SEQUENCE" => Some(FnEntry(name, 1, 4, { ev, args => fnSequence(ev, args) }))
        // 数学/工程扩展（M3-c 第一批）
        case "ACOS" => Some(FnEntry(name, 1, 1, { ev, args => fnTrigExt(ev, args, "acos") }))
        case "ACOSH" => Some(FnEntry(name, 1, 1, { ev, args => fnTrigExt(ev, args, "acosh") }))
        case "ASIN" => Some(FnEntry(name, 1, 1, { ev, args => fnTrigExt(ev, args, "asin") }))
        case "ASINH" => Some(FnEntry(name, 1, 1, { ev, args => fnTrigExt(ev, args, "asinh") }))
        case "ATAN" => Some(FnEntry(name, 1, 1, { ev, args => fnTrigExt(ev, args, "atan") }))
        case "ATANH" => Some(FnEntry(name, 1, 1, { ev, args => fnTrigExt(ev, args, "atanh") }))
        case "ATAN2" => Some(FnEntry(name, 2, 2, { ev, args => fnAtan2(ev, args) }))
        case "COSH" => Some(FnEntry(name, 1, 1, { ev, args => fnTrigExt(ev, args, "cosh") }))
        case "SINH" => Some(FnEntry(name, 1, 1, { ev, args => fnTrigExt(ev, args, "sinh") }))
        case "TANH" => Some(FnEntry(name, 1, 1, { ev, args => fnTrigExt(ev, args, "tanh") }))
        case "SEC" => Some(FnEntry(name, 1, 1, { ev, args => fnTrigExt(ev, args, "sec") }))
        case "SECH" => Some(FnEntry(name, 1, 1, { ev, args => fnTrigExt(ev, args, "sech") }))
        case "CSC" => Some(FnEntry(name, 1, 1, { ev, args => fnTrigExt(ev, args, "csc") }))
        case "CSCH" => Some(FnEntry(name, 1, 1, { ev, args => fnTrigExt(ev, args, "csch") }))
        case "COT" => Some(FnEntry(name, 1, 1, { ev, args => fnTrigExt(ev, args, "cot") }))
        case "COTH" => Some(FnEntry(name, 1, 1, { ev, args => fnTrigExt(ev, args, "coth") }))
        case "EVEN" => Some(FnEntry(name, 1, 1, { ev, args => fnEvenOdd(ev, args, true) }))
        case "ODD" => Some(FnEntry(name, 1, 1, { ev, args => fnEvenOdd(ev, args, false) }))
        case "QUOTIENT" => Some(FnEntry(name, 2, 2, { ev, args => fnQuotient(ev, args) }))
        case "COMBIN" => Some(FnEntry(name, 2, 2, { ev, args => fnCombin(ev, args, false) }))
        case "COMBINA" => Some(FnEntry(name, 2, 2, { ev, args => fnCombin(ev, args, true) }))
        case "PERMUT" => Some(FnEntry(name, 2, 2, { ev, args => fnPermut(ev, args, false) }))
        case "PERMUTATIONA" => Some(FnEntry(name, 2, 2, { ev, args => fnPermut(ev, args, true) }))
        case "MULTINOMIAL" => Some(FnEntry(name, 1, -1, { ev, args => fnMultinomial(ev, args) }))
        case "FACTDOUBLE" => Some(FnEntry(name, 1, 1, { ev, args => fnFactDouble(ev, args) }))
        case "SQRTPI" => Some(FnEntry(name, 1, 1, { ev, args => fnSqrtPi(ev, args) }))
        case "SUMSQ" => Some(FnEntry(name, 1, -1, { ev, args => fnSumSq(ev, args) }))
        case "SUMX2MY2" => Some(FnEntry(name, 2, 2, { ev, args => fnSumX2(ev, args, "my") }))
        case "SUMX2PY2" => Some(FnEntry(name, 2, 2, { ev, args => fnSumX2(ev, args, "py") }))
        case "SUMXMY2" => Some(FnEntry(name, 2, 2, { ev, args => fnSumX2(ev, args, "my2") }))
        case "SERIESSUM" => Some(FnEntry(name, 4, 4, { ev, args => fnSeriesSum(ev, args) }))
        case "CEILING.MATH" => Some(FnEntry(name, 1, 3, { ev, args => fnCeilingMath(ev, args, true, false) }))
        case "FLOOR.MATH" => Some(FnEntry(name, 1, 3, { ev, args => fnCeilingMath(ev, args, false, false) }))
        case "CEILING.PRECISE" => Some(FnEntry(name, 1, 2, { ev, args => fnCeilingMath(ev, args, true, true) }))
        case "FLOOR.PRECISE" => Some(FnEntry(name, 1, 2, { ev, args => fnCeilingMath(ev, args, false, true) }))
        case "ISO.CEILING" => Some(FnEntry(name, 1, 2, { ev, args => fnCeilingMath(ev, args, true, true) }))
        case "BASE" => Some(FnEntry(name, 2, 3, { ev, args => fnBaseConvert(ev, args, true) }))
        case "DECIMAL" => Some(FnEntry(name, 2, 2, { ev, args => fnBaseConvert(ev, args, false) }))
        case "BITAND" => Some(FnEntry(name, 2, 2, { ev, args => fnBitwise(ev, args, "and") }))
        case "BITOR" => Some(FnEntry(name, 2, 2, { ev, args => fnBitwise(ev, args, "or") }))
        case "BITXOR" => Some(FnEntry(name, 2, 2, { ev, args => fnBitwise(ev, args, "xor") }))
        case "BITLSHIFT" => Some(FnEntry(name, 2, 2, { ev, args => fnBitwise(ev, args, "lshift") }))
        case "BITRSHIFT" => Some(FnEntry(name, 2, 2, { ev, args => fnBitwise(ev, args, "rshift") }))
        case "ROMAN" => Some(FnEntry(name, 1, 2, { ev, args => fnRoman(ev, args) }))
        case "ARABIC" => Some(FnEntry(name, 1, 1, { ev, args => fnArabic(ev, args) }))
        case "RANDARRAY" => Some(FnEntry(name, 0, 5, { ev, args => fnRandArray(ev, args) }))
        case "DEC2BIN" => Some(FnEntry(name, 1, 2, { ev, args => fnEngBase(ev, args, "dec2bin") }))
        case "DEC2HEX" => Some(FnEntry(name, 1, 2, { ev, args => fnEngBase(ev, args, "dec2hex") }))
        case "DEC2OCT" => Some(FnEntry(name, 1, 2, { ev, args => fnEngBase(ev, args, "dec2oct") }))
        case "BIN2DEC" => Some(FnEntry(name, 1, 1, { ev, args => fnEngBase(ev, args, "bin2dec") }))
        case "BIN2HEX" => Some(FnEntry(name, 1, 2, { ev, args => fnEngBase(ev, args, "bin2hex") }))
        case "BIN2OCT" => Some(FnEntry(name, 1, 2, { ev, args => fnEngBase(ev, args, "bin2oct") }))
        case "HEX2BIN" => Some(FnEntry(name, 1, 2, { ev, args => fnEngBase(ev, args, "hex2bin") }))
        case "HEX2DEC" => Some(FnEntry(name, 1, 1, { ev, args => fnEngBase(ev, args, "hex2dec") }))
        case "HEX2OCT" => Some(FnEntry(name, 1, 2, { ev, args => fnEngBase(ev, args, "hex2oct") }))
        case "OCT2BIN" => Some(FnEntry(name, 1, 2, { ev, args => fnEngBase(ev, args, "oct2bin") }))
        case "OCT2DEC" => Some(FnEntry(name, 1, 1, { ev, args => fnEngBase(ev, args, "oct2dec") }))
        case "OCT2HEX" => Some(FnEntry(name, 1, 2, { ev, args => fnEngBase(ev, args, "oct2hex") }))
        case "DELTA" => Some(FnEntry(name, 1, 2, { ev, args => fnDeltaStep(ev, args, true) }))
        case "GESTEP" => Some(FnEntry(name, 1, 2, { ev, args => fnDeltaStep(ev, args, false) }))
        case "ERF" => Some(FnEntry(name, 1, 1, { ev, args => fnErf(ev, args, false) }))
        case "ERFC" => Some(FnEntry(name, 1, 1, { ev, args => fnErf(ev, args, true) }))
        // 统计/信息/文本扩展（M3-c 第二批）
        case "AVEDEV" => Some(FnEntry(name, 1, -1, { ev, args => fnAveDev(ev, args) }))
        case "DEVSQ" => Some(FnEntry(name, 1, -1, { ev, args => fnDevSq(ev, args) }))
        case "GEOMEAN" => Some(FnEntry(name, 1, -1, { ev, args => fnGeoMean(ev, args) }))
        case "HARMEAN" => Some(FnEntry(name, 1, -1, { ev, args => fnHarMean(ev, args) }))
        case "KURT" => Some(FnEntry(name, 1, -1, { ev, args => fnSkewKurt(ev, args, "kurt") }))
        case "SKEW" => Some(FnEntry(name, 1, -1, { ev, args => fnSkewKurt(ev, args, "skew") }))
        case "SKEW.P" => Some(FnEntry(name, 1, -1, { ev, args => fnSkewKurt(ev, args, "skewp") }))
        case "TRIMMEAN" => Some(FnEntry(name, 2, 2, { ev, args => fnTrimMean(ev, args) }))
        case "PERCENTRANK" => Some(FnEntry(name, 2, 3, { ev, args => fnPercentRank(ev, args, false) }))
        case "PERCENTRANK.INC" => Some(FnEntry(name, 2, 3, { ev, args => fnPercentRank(ev, args, false) }))
        case "PERCENTRANK.EXC" => Some(FnEntry(name, 2, 3, { ev, args => fnPercentRank(ev, args, true) }))
        case "QUARTILE.INC" => Some(FnEntry(name, 2, 2, { ev, args => fnQuartile(ev, args) }))
        case "QUARTILE.EXC" => Some(FnEntry(name, 2, 2, { ev, args => fnQuartileExclusive(ev, args) }))
        case "STDEVA" => Some(FnEntry(name, 1, -1, { ev, args => fnDevA(ev, args, true) }))
        case "STDEVPA" => Some(FnEntry(name, 1, -1, { ev, args => fnDevA(ev, args, false) }))
        case "VARA" => Some(FnEntry(name, 1, -1, { ev, args => fnVarianceA(ev, args, true) }))
        case "VARPA" => Some(FnEntry(name, 1, -1, { ev, args => fnVarianceA(ev, args, false) }))
        case "COVARIANCE.P" => Some(FnEntry(name, 2, 2, { ev, args => fnCovariance(ev, args, false) }))
        case "COVARIANCE.S" => Some(FnEntry(name, 2, 2, { ev, args => fnCovariance(ev, args, true) }))
        case "FISHER" => Some(FnEntry(name, 1, 1, { ev, args => fnFisher(ev, args, false) }))
        case "FISHERINV" => Some(FnEntry(name, 1, 1, { ev, args => fnFisher(ev, args, true) }))
        case "STANDARDIZE" => Some(FnEntry(name, 3, 3, { ev, args => fnStandardize(ev, args) }))
        case "RSQ" => Some(FnEntry(name, 2, 2, { ev, args => fnR(ev, args, true) }))
        case "PEARSON" => Some(FnEntry(name, 2, 2, { ev, args => fnR(ev, args, false) }))
        case "AVERAGEA" => Some(FnEntry(name, 1, -1, { ev, args => fnAverageA(ev, args) }))
        case "MAXA" => Some(FnEntry(name, 1, -1, { ev, args => fnMinMaxA(ev, args, false) }))
        case "MINA" => Some(FnEntry(name, 1, -1, { ev, args => fnMinMaxA(ev, args, true) }))
        case "MODE.SNGL" => Some(FnEntry(name, 1, -1, { ev, args => fnMode(ev, args) }))
        case "MODE.MULT" => Some(FnEntry(name, 1, -1, { ev, args => fnModeMult(ev, args) }))
        case "RANK.EQ" => Some(FnEntry(name, 2, 3, { ev, args => fnRank(ev, args) }))
        case "RANK.AVG" => Some(FnEntry(name, 2, 3, { ev, args => fnRankAvg(ev, args) }))
        case "ISEVEN" => Some(FnEntry(name, 1, 1, { ev, args => fnIsEvenOdd(ev, args, true) }))
        case "ISODD" => Some(FnEntry(name, 1, 1, { ev, args => fnIsEvenOdd(ev, args, false) }))
        case "ISREF" => Some(FnEntry(name, 1, 1, { ev, args => fnIsRef(ev, args) }))
        case "N" => Some(FnEntry(name, 1, 1, { ev, args => fnN(ev, args) }))
        case "SHEET" => Some(FnEntry(name, 0, 1, { ev, args => fnSheetCount(ev, args, false) }))
        case "SHEETS" => Some(FnEntry(name, 0, 1, { ev, args => fnSheetCount(ev, args, true) }))
        case "TEXTBEFORE" => Some(FnEntry(name, 2, 3, { ev, args => fnTextBeforeAfter(ev, args, true) }))
        case "TEXTAFTER" => Some(FnEntry(name, 2, 3, { ev, args => fnTextBeforeAfter(ev, args, false) }))
        case "TEXTSPLIT" => Some(FnEntry(name, 2, 3, { ev, args => fnTextSplit(ev, args) }))
        case "NUMBERVALUE" => Some(FnEntry(name, 1, 3, { ev, args => fnNumberValue(ev, args) }))
        case "DOLLAR" => Some(FnEntry(name, 1, 2, { ev, args => fnDollarFixed(ev, args, true) }))
        case "FIXED" => Some(FnEntry(name, 1, 3, { ev, args => fnDollarFixed(ev, args, false) }))
        case "WIDECHAR" => Some(FnEntry(name, 1, 1, { ev, args => fnWideAsc(ev, args) }))
        case "ASC" => Some(FnEntry(name, 1, 1, { ev, args => fnWideAsc(ev, args) }))
        case "LEFTB" => Some(FnEntry(name, 1, 2, { ev, args => fnByteText(ev, args, "leftb") }))
        case "RIGHTB" => Some(FnEntry(name, 1, 2, { ev, args => fnByteText(ev, args, "rightb") }))
        case "MIDB" => Some(FnEntry(name, 3, 3, { ev, args => fnByteText(ev, args, "midb") }))
        case "LENB" => Some(FnEntry(name, 1, 1, { ev, args => fnByteText(ev, args, "lenb") }))
        case "VALUETOTEXT" => Some(FnEntry(name, 1, 1, { ev, args => fnValueToText(ev, args, false) }))
        case "ARRAYTOTEXT" => Some(FnEntry(name, 1, 1, { ev, args => fnValueToText(ev, args, true) }))
        // 动态/查找/日期/财务扩展（M3-c 第三批）
        case "SORTBY" => Some(FnEntry(name, 2, -1, { ev, args => fnSortBy(ev, args) }))
        case "TAKE" => Some(FnEntry(name, 2, 3, { ev, args => fnTakeDrop(ev, args, true) }))
        case "DROP" => Some(FnEntry(name, 2, 3, { ev, args => fnTakeDrop(ev, args, false) }))
        case "CHOOSEROWS" => Some(FnEntry(name, 2, -1, { ev, args => fnChooseRowsCols(ev, args, true) }))
        case "CHOOSECOLS" => Some(FnEntry(name, 2, -1, { ev, args => fnChooseRowsCols(ev, args, false) }))
        case "EXPAND" => Some(FnEntry(name, 2, 4, { ev, args => fnExpand(ev, args) }))
        case "VSTACK" => Some(FnEntry(name, 1, -1, { ev, args => fnStack(ev, args, true) }))
        case "HSTACK" => Some(FnEntry(name, 1, -1, { ev, args => fnStack(ev, args, false) }))
        case "TOCOL" => Some(FnEntry(name, 1, 1, { ev, args => fnToLine(ev, args, true) }))
        case "TOROW" => Some(FnEntry(name, 1, 1, { ev, args => fnToLine(ev, args, false) }))
        case "WRAPROWS" => Some(FnEntry(name, 2, 2, { ev, args => fnWrap(ev, args, true) }))
        case "WRAPCOLS" => Some(FnEntry(name, 2, 2, { ev, args => fnWrap(ev, args, false) }))
        case "ADDRESS" => Some(FnEntry(name, 2, 5, { ev, args => fnAddress(ev, args) }))
        case "AREAS" => Some(FnEntry(name, 1, 1, { ev, args => fnAreas(ev, args) }))
        case "HYPERLINK" => Some(FnEntry(name, 1, 2, { ev, args => fnHyperlink(ev, args) }))
        case "XMATCH" => Some(FnEntry(name, 2, 4, { ev, args => fnXMatch(ev, args) }))
        case "TIME" => Some(FnEntry(name, 3, 3, { ev, args => fnTime(ev, args) }))
        case "ISOWEEKNUM" => Some(FnEntry(name, 1, 1, { ev, args => fnIsoWeeknum(ev, args) }))
        case "YEARFRAC" => Some(FnEntry(name, 2, 3, { ev, args => fnYearFrac(ev, args) }))
        case "NETWORKDAYS.INTL" => Some(FnEntry(name, 2, 4, { ev, args => fnNetworkdaysIntl(ev, args) }))
        case "WORKDAY.INTL" => Some(FnEntry(name, 2, 4, { ev, args => fnWorkdayIntl(ev, args) }))
        case "DB" => Some(FnEntry(name, 4, 5, { ev, args => fnDb(ev, args) }))
        case "DDB" => Some(FnEntry(name, 4, 5, { ev, args => fnDdb(ev, args) }))
        case "SYD" => Some(FnEntry(name, 4, 4, { ev, args => fnSyd(ev, args) }))
        case "EFFECT" => Some(FnEntry(name, 2, 2, { ev, args => fnEffectNominal(ev, args, true) }))
        case "NOMINAL" => Some(FnEntry(name, 2, 2, { ev, args => fnEffectNominal(ev, args, false) }))
        case "FVSCHEDULE" => Some(FnEntry(name, 2, 2, { ev, args => fnFvSchedule(ev, args) }))
        case "PDURATION" => Some(FnEntry(name, 3, 3, { ev, args => fnPduration(ev, args) }))
        case "RRI" => Some(FnEntry(name, 3, 3, { ev, args => fnRri(ev, args) }))
        case "ISPMT" => Some(FnEntry(name, 4, 4, { ev, args => fnIspmt(ev, args) }))
        case "CUMIPMT" => Some(FnEntry(name, 6, 6, { ev, args => fnCumPayment(ev, args, false) }))
        case "CUMPRINC" => Some(FnEntry(name, 6, 6, { ev, args => fnCumPayment(ev, args, true) }))
        case "DOLLARDE" => Some(FnEntry(name, 2, 2, { ev, args => fnDollarDeFr(ev, args, true) }))
        case "DOLLARFR" => Some(FnEntry(name, 2, 2, { ev, args => fnDollarDeFr(ev, args, false) }))
        case "IRR" => Some(FnEntry(name, 1, 2, { ev, args => fnIrr(ev, args) }))
        case "RATE" => Some(FnEntry(name, 3, 6, { ev, args => fnRate(ev, args) }))
        case "MIRR" => Some(FnEntry(name, 3, 3, { ev, args => fnMirr(ev, args) }))
        // 分布/数据库/杂项（M3-c 第四批）
        case "NORM.DIST" => Some(FnEntry(name, 4, 4, { ev, args => fnNormalDist(ev, args, false) }))
        case "NORM.INV" => Some(FnEntry(name, 3, 3, { ev, args => fnNormalInv(ev, args, false) }))
        case "NORM.S.DIST" => Some(FnEntry(name, 2, 2, { ev, args => fnNormalDist(ev, args, true) }))
        case "NORM.S.INV" => Some(FnEntry(name, 1, 1, { ev, args => fnNormalInv(ev, args, true) }))
        case "LOGNORM.DIST" => Some(FnEntry(name, 4, 4, { ev, args => fnLogNormalDist(ev, args, false) }))
        case "LOGNORM.INV" => Some(FnEntry(name, 3, 3, { ev, args => fnLogNormalDist(ev, args, true) }))
        case "EXPON.DIST" => Some(FnEntry(name, 3, 3, { ev, args => fnExponDist(ev, args) }))
        case "POISSON.DIST" => Some(FnEntry(name, 3, 3, { ev, args => fnPoissonDist(ev, args) }))
        case "BINOM.DIST" => Some(FnEntry(name, 4, 4, { ev, args => fnBinomDist(ev, args) }))
        case "BINOM.INV" => Some(FnEntry(name, 3, 3, { ev, args => fnBinomInv(ev, args) }))
        case "NEGBINOM.DIST" => Some(FnEntry(name, 4, 4, { ev, args => fnNegBinomDist(ev, args) }))
        case "HYPGEOM.DIST" => Some(FnEntry(name, 5, 5, { ev, args => fnHypGeomDist(ev, args) }))
        case "WEIBULL.DIST" => Some(FnEntry(name, 4, 4, { ev, args => fnWeibullDist(ev, args) }))
        case "GAMMA" => Some(FnEntry(name, 1, 1, { ev, args => fnGamma(ev, args, false) }))
        case "GAMMALN" => Some(FnEntry(name, 1, 1, { ev, args => fnGamma(ev, args, true) }))
        case "CONFIDENCE.NORM" => Some(FnEntry(name, 3, 3, { ev, args => fnConfidenceNorm(ev, args) }))
        case "Z.TEST" => Some(FnEntry(name, 2, 3, { ev, args => fnZTest(ev, args) }))
        case "PERCENTILE.EXC" => Some(FnEntry(name, 2, 2, { ev, args => fnPercentileExc(ev, args) }))
        case "PERCENTILE.INC" => Some(FnEntry(name, 2, 2, { ev, args => fnPercentile(ev, args) }))
        case "FREQUENCY" => Some(FnEntry(name, 2, 2, { ev, args => fnFrequency(ev, args) }))
        case "DSUM" => Some(FnEntry(name, 3, 3, { ev, args => fnDatabase(ev, args, "sum") }))
        case "DCOUNT" => Some(FnEntry(name, 3, 3, { ev, args => fnDatabase(ev, args, "count") }))
        case "DCOUNTA" => Some(FnEntry(name, 3, 3, { ev, args => fnDatabase(ev, args, "counta") }))
        case "DAVERAGE" => Some(FnEntry(name, 3, 3, { ev, args => fnDatabase(ev, args, "average") }))
        case "DMAX" => Some(FnEntry(name, 3, 3, { ev, args => fnDatabase(ev, args, "max") }))
        case "DMIN" => Some(FnEntry(name, 3, 3, { ev, args => fnDatabase(ev, args, "min") }))
        case "DGET" => Some(FnEntry(name, 3, 3, { ev, args => fnDatabase(ev, args, "get") }))
        case "DPRODUCT" => Some(FnEntry(name, 3, 3, { ev, args => fnDatabase(ev, args, "product") }))
        case "DSTDEV" => Some(FnEntry(name, 3, 3, { ev, args => fnDatabase(ev, args, "stdev") }))
        case "DSTDEVP" => Some(FnEntry(name, 3, 3, { ev, args => fnDatabase(ev, args, "stdevp") }))
        case "DVAR" => Some(FnEntry(name, 3, 3, { ev, args => fnDatabase(ev, args, "var") }))
        case "DVARP" => Some(FnEntry(name, 3, 3, { ev, args => fnDatabase(ev, args, "varp") }))
        case "SUBTOTAL" => Some(FnEntry(name, 2, -1, { ev, args => fnSubtotal(ev, args) }))
        case "AGGREGATE" => Some(FnEntry(name, 3, -1, { ev, args => fnAggregate(ev, args) }))
        case "CONVERT" => Some(FnEntry(name, 3, 3, { ev, args => fnConvert(ev, args) }))
        case "ERF.PRECISE" => Some(FnEntry(name, 1, 1, { ev, args => fnErf(ev, args, false) }))
        case "ERFC.PRECISE" => Some(FnEntry(name, 1, 1, { ev, args => fnErf(ev, args, true) }))
        case "ISFORMULA" => Some(FnEntry(name, 1, 1, { ev, args => fnFormulaText(ev, args, false) }))
        case "FORMULATEXT" => Some(FnEntry(name, 1, 1, { ev, args => fnFormulaText(ev, args, true) }))
        case "CELL" => Some(FnEntry(name, 1, 2, { ev, args => fnCell(ev, args) }))
        case "INFO" => Some(FnEntry(name, 1, 1, { ev, args => fnInfo(ev, args) }))
        case "MUNIT" => Some(FnEntry(name, 1, 1, { ev, args => fnMunit(ev, args) }))
        case "MDETERM" => Some(FnEntry(name, 1, 1, { ev, args => fnMdeterm(ev, args) }))
        case "MINVERSE" => Some(FnEntry(name, 1, 1, { ev, args => fnMinverse(ev, args) }))
        case "XNPV" => Some(FnEntry(name, 3, 3, { ev, args => fnXnpv(ev, args) }))
        case "XIRR" => Some(FnEntry(name, 2, 3, { ev, args => fnXirr(ev, args) }))
        case "TBILLPRICE" => Some(FnEntry(name, 3, 3, { ev, args => fnTbillPrice(ev, args) }))
        case "SEARCHB" => Some(FnEntry(name, 2, 3, { ev, args => fnFindSearch(ev, args, false) }))
        case "FINDB" => Some(FnEntry(name, 2, 3, { ev, args => fnFindSearch(ev, args, true) }))
        case "REPLACEB" => Some(FnEntry(name, 4, 4, { ev, args => fnReplace(ev, args) }))
        case "PHONETIC" => Some(FnEntry(name, 1, 1, { ev, args => fnPhonetic(ev, args) }))
        case "COUNTUNIQUE" => Some(FnEntry(name, 1, -1, { ev, args => fnCountUnique(ev, args) }))
        case "PROB" => Some(FnEntry(name, 3, 4, { ev, args => fnProb(ev, args) }))
        case _ => None<FnEntry>
    }
}

/** M2-c 新增的函数名（测试与文档用）。 */
internal let EXTENDED_FUNCTION_NAMES: Array<String> = [
    "STDEV.P", "STDEV.S", "VAR.P", "VAR.S", "LARGE", "SMALL", "RANK", "PERCENTILE",
    "QUARTILE", "MODE", "CORREL", "SLOPE", "INTERCEPT", "FORECAST",
    "HLOOKUP", "LOOKUP", "XLOOKUP", "CHOOSE", "OFFSET", "INDIRECT", "ROW", "COLUMN",
    "ROWS", "COLUMNS", "TRANSPOSE",
    "SUBSTITUTE", "REPLACE", "FIND", "SEARCH", "REPT", "TEXTJOIN", "EXACT", "PROPER",
    "CLEAN", "CHAR", "CODE", "UNICHAR", "UNICODE", "T",
    "SUMPRODUCT", "CEILING", "FLOOR", "MROUND", "RAND", "RANDBETWEEN", "LOG", "LOG10",
    "LN", "EXP", "PI", "SIN", "COS", "TAN", "DEGREES", "RADIANS", "GCD", "LCM", "FACT",
    "DATEVALUE", "TIMEVALUE", "EDATE", "EOMONTH", "WEEKDAY", "WEEKNUM", "DATEDIF", "DAYS",
    "DAYS360", "NETWORKDAYS", "WORKDAY",
    "PMT", "FV", "PV", "NPER", "SLN", "NPV", "IPMT", "PPMT",
    "ISERR", "NA", "TYPE", "ERROR.TYPE"
]

/** M3-c 第一批：数学/工程。 */
internal let MATH_ENG_FUNCTION_NAMES: Array<String> = [
    "ACOS", "ACOSH", "ASIN", "ASINH", "ATAN", "ATANH", "ATAN2", "COSH", "SINH", "TANH",
    "SEC", "SECH", "CSC", "CSCH", "COT", "COTH", "EVEN", "ODD", "QUOTIENT", "COMBIN",
    "COMBINA", "PERMUT", "PERMUTATIONA", "MULTINOMIAL", "FACTDOUBLE", "SQRTPI", "SUMSQ",
    "SUMX2MY2", "SUMX2PY2", "SUMXMY2", "SERIESSUM", "CEILING.MATH", "FLOOR.MATH",
    "CEILING.PRECISE", "FLOOR.PRECISE", "ISO.CEILING", "BASE", "DECIMAL", "BITAND", "BITOR",
    "BITXOR", "BITLSHIFT", "BITRSHIFT", "ROMAN", "ARABIC", "RANDARRAY",
    "DEC2BIN", "DEC2HEX", "DEC2OCT", "BIN2DEC", "BIN2HEX", "BIN2OCT", "HEX2BIN", "HEX2DEC",
    "HEX2OCT", "OCT2BIN", "OCT2DEC", "OCT2HEX", "DELTA", "GESTEP", "ERF", "ERFC"
]

/** M3-c 第二批：统计/信息/文本。 */
internal let STAT_TEXT_FUNCTION_NAMES: Array<String> = [
    "AVEDEV", "DEVSQ", "GEOMEAN", "HARMEAN", "KURT", "SKEW", "SKEW.P", "TRIMMEAN",
    "PERCENTRANK", "PERCENTRANK.INC", "PERCENTRANK.EXC", "QUARTILE.INC", "QUARTILE.EXC",
    "STDEVA", "STDEVPA", "VARA", "VARPA", "COVARIANCE.P", "COVARIANCE.S", "FISHER",
    "FISHERINV", "STANDARDIZE", "RSQ", "PEARSON", "AVERAGEA", "MAXA", "MINA", "MODE.SNGL",
    "MODE.MULT", "RANK.EQ", "RANK.AVG", "ISEVEN", "ISODD", "ISREF", "N", "SHEET", "SHEETS",
    "TEXTBEFORE", "TEXTAFTER", "TEXTSPLIT", "NUMBERVALUE", "DOLLAR", "FIXED", "WIDECHAR",
    "ASC", "LEFTB", "RIGHTB", "MIDB", "LENB", "VALUETOTEXT", "ARRAYTOTEXT"
]

/** M3-c 第三批：动态/查找/日期/财务。 */
internal let DYN_FIN_FUNCTION_NAMES: Array<String> = [
    "SORTBY", "TAKE", "DROP", "CHOOSEROWS", "CHOOSECOLS", "EXPAND", "VSTACK", "HSTACK",
    "TOCOL", "TOROW", "WRAPROWS", "WRAPCOLS", "ADDRESS", "AREAS", "HYPERLINK", "XMATCH",
    "TIME", "ISOWEEKNUM", "YEARFRAC", "NETWORKDAYS.INTL", "WORKDAY.INTL",
    "DB", "DDB", "SYD", "EFFECT", "NOMINAL", "FVSCHEDULE", "PDURATION", "RRI", "ISPMT",
    "CUMIPMT", "CUMPRINC", "DOLLARDE", "DOLLARFR", "IRR", "RATE", "MIRR"
]

/** M3-c 第四批：分布/数据库/杂项。 */
internal let DIST_DB_FUNCTION_NAMES: Array<String> = [
    "NORM.DIST", "NORM.INV", "NORM.S.DIST", "NORM.S.INV", "LOGNORM.DIST", "LOGNORM.INV",
    "EXPON.DIST", "POISSON.DIST", "BINOM.DIST", "BINOM.INV", "NEGBINOM.DIST", "HYPGEOM.DIST",
    "WEIBULL.DIST", "GAMMA", "GAMMALN", "CONFIDENCE.NORM", "Z.TEST", "PERCENTILE.EXC",
    "PERCENTILE.INC", "FREQUENCY",
    "DSUM", "DCOUNT", "DCOUNTA", "DAVERAGE", "DMAX", "DMIN", "DGET", "DPRODUCT", "DSTDEV",
    "DSTDEVP", "DVAR", "DVARP",
    "SUBTOTAL", "AGGREGATE", "CONVERT", "ERF.PRECISE", "ERFC.PRECISE", "ISFORMULA",
    "FORMULATEXT", "CELL", "INFO", "MUNIT", "MDETERM", "MINVERSE", "XNPV", "XIRR",
    "TBILLPRICE", "SEARCHB", "FINDB", "REPLACEB", "PHONETIC", "COUNTUNIQUE", "PROB"
]

/** 当前注册的函数个数（测试用）。 */
internal let CORE_FUNCTION_NAMES: Array<String> = [
    "SUM", "PRODUCT", "ABS", "SIGN", "SQRT", "INT", "ROUND", "ROUNDUP", "ROUNDDOWN", "TRUNC",
    "MOD", "POWER", "SUMIF", "SUMIFS", "AVERAGE", "AVERAGEIF", "COUNT", "COUNTA", "COUNTBLANK",
    "COUNTIF", "COUNTIFS", "MIN", "MAX", "MEDIAN", "IF", "IFS", "AND", "OR", "NOT", "XOR",
    "IFERROR", "IFNA", "SWITCH", "CONCATENATE", "CONCAT", "LEN", "LEFT", "RIGHT", "MID", "TRIM",
    "UPPER", "LOWER", "TEXT", "VALUE", "DATE", "YEAR", "MONTH", "DAY", "HOUR", "MINUTE", "SECOND",
    "TODAY", "NOW", "VLOOKUP", "INDEX", "MATCH", "ISBLANK", "ISERROR", "ISNUMBER", "ISTEXT",
    "ISLOGICAL", "ISNA"
]

// ---------------------------------------------------------------- 实参辅助

/** 一批实参里的数字：区域只取数字（忽略文本/布尔/空），标量允许隐式转换。 */
internal func numbersOf(ev: Evaluator, args: Array<Expr>, index: Int64): (ArrayList<Float64>, ?CalcError) {
    let out = ArrayList<Float64>()
    let value = ev.arg(args, index)
    match (value) {
        case Error(e) => return (out, Some(e))
        case ArrayValue(rows) =>
            for (row in rows) {
                for (item in row) {
                    match (item) {
                        case Number(v) => out.add(v)
                        case Error(e) => return (out, Some(e))
                        case _ => ()
                    }
                }
            }
        case Empty => ()
        case _ => match (calcToNumber(value)) {
            case Some(v) => out.add(v)
            case None => return (out, Some(CalcError.Value))
        }
    }
    (out, None<CalcError>)
}

/** 展平一个实参（区域 → 全部标量）。 */
internal func scalarsOf(ev: Evaluator, args: Array<Expr>, index: Int64): ArrayList<CalcValue> {
    flattenValues(ev.arg(args, index))
}

/** 判定一个值是否满足条件（`">3"`、`"<>x"`、`"a*"` 仅支持前两种与相等）。 */
internal func criteriaMatch(value: CalcValue, criteria: CalcValue): Bool {
    let item = scalarize(value)
    match (criteria) {
        case Text(raw) =>
            let text = raw
            let ops = [">=", "<=", "<>", ">", "<", "="]
            var op = ""
            var rest = text
            for (candidate in ops) {
                if (text.startsWith(candidate)) {
                    op = candidate
                    rest = text[candidate.size..]
                    break
                }
            }
            if (op.isEmpty()) {
                return compareCalc(item, CalcValue.Text(text)) == Some(0)
            }
            let rhs = if (isNumericText(rest)) {
                CalcValue.Number(parseNumberText(rest).getOrThrow())
            } else {
                CalcValue.Text(rest)
            }
            let order = match (compareCalc(item, rhs)) {
                case Some(v) => v
                case None => return false
            }
            match (op) {
                case ">=" => order >= 0
                case "<=" => order <= 0
                case "<>" => order != 0
                case ">" => order > 0
                case "<" => order < 0
                case _ => order == 0
            }
        case _ => compareCalc(item, criteria) == Some(0)
    }
}

internal func isNumericText(text: String): Bool {
    parseNumberText(text).isSome()
}

/** 按行优先遍历一个区域的标量（含空）。 */
internal func gridOf(value: CalcValue): Array<Array<CalcValue>> {
    match (value) {
        case ArrayValue(rows) => rows
        case Empty => Array<Array<CalcValue>>()
        case _ => [[value]]
    }
}
