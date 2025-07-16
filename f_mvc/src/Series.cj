/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_mvc

/**
 * HTTP status series.
 * Retrievable via HttpStatus series.
 */
public class Series <: Equatable<Series> {
    public static let INFORMATIONAL = Series(1)
    public static let SUCCESSFUL = Series(2)
    public static let REDIRECTION = Series(3)
    public static let CLIENT_ERROR = Series(4)
    public static let SERVER_ERROR = Series(5)

    private static let series = HashMap<Int64, Series>()
    static init() {
        for (s in [INFORMATIONAL, SUCCESSFUL, REDIRECTION, CLIENT_ERROR, SERVER_ERROR]) {
            series[s.value] = s
        }
    }

    private Series(public let value: Int64) {}

    public static prop values: Array<Series> {
        get() {
            [INFORMATIONAL, SUCCESSFUL, REDIRECTION, CLIENT_ERROR, SERVER_ERROR]
        }
    }
    public operator func ==(series: Series) {
        this.value == series.value
    }

    public static func valueOf(status: HttpStatus): Series {
        return status.series
    }

    public static func valueOf(status: Int64): Series {
        let series = resolve(status)
        match (series) {
            case Some(s) => s
            case _ => throw IllegalArgumentException("No matching constant for [${status}]")
        }
    }

    public static func resolve(status: Int64): Option<Series> {
        let code = status / 100
        series.get(code)
    }
}
