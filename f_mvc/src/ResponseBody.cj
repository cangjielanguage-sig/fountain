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

public func responseBody<T>(ctx: HttpContext, data: T): Unit where T <: Object & DataObject<T> {
    let d = data.toData()
    let mediaType = ctx
        .request
        .headers
        .getFirst("Accept")
        .getOrThrow {HttpRequestHeaderException("current request header does not contain Accept")}
    let bytes = MediaTypes.parse(mediaType).fromData(d)
    HttpResponseWriter(ctx).write(bytes)
}
