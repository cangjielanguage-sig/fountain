/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_mvc

public enum RequestMethod <: Hashable & Equatable<RequestMethod> & ToString & Parsable<RequestMethod> & DataParsable<RequestMethod> {
    | GET
    | POST
    | PUT
    | DELETE
    | PATCH
    | OPTIONS
    | HEAD

    public func hashCode(): Int64 {
        toString().hashCode()
    }

    public operator func ==(other: RequestMethod) {
        match ((this, other)) {
            case (GET, GET) | (POST, POST) | (PUT, PUT) | (DELETE, DELETE) | (PATCH, PATCH) | (OPTIONS, OPTIONS)
                | (HEAD, HEAD) => true
            case _ => false
        }
    }
    public func toString() {
        match (this) {
            case GET => "GET"
            case PUT => "PUT"
            case POST => "POST"
            case DELETE => "DELETE"
            case PATCH => "PATCH"
            case OPTIONS => "OPTIONS"
            case HEAD => "HEAD"
        }
    }
    public static func tryParse(value: String): ?RequestMethod {
        match (value.toAsciiUpper()) {
            case "GET" => GET
            case "PUT" => PUT
            case "POST" => POST
            case "DELETE" => DELETE
            case "PATCH" => PATCH
            case "OPTIONS" => OPTIONS
            case "HEAD" => HEAD
            case _ => None
        }
    }
    public static func parse(value: String): RequestMethod {
        tryParse(value).getOrThrow {IllegalArgumentException("${value} is an illegal http request method")}
    }
}
