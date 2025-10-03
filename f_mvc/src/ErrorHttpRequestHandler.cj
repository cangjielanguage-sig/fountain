/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package f_mvc

public interface ErrorHttpRequestHandler <: HttpRequestHandler {
    prop status: HttpStatus
    func response(): Any
    func handle(ctx: HttpContext): Unit {
        let status = this.status
        let b = ctx.responseBuilder.status(status.value)
        var accept = ''
        if(let Some(x) <- ctx.request.headers.getFirst('Accept')) {
            b.header("Content-Type", x)
            accept = x
        }
        match(response()){
            case x: String => b.body(x)
            case x: ToString => b.body(x.toString())
            case x: InputStream => b.body(x)
            case x: Array<Byte> => b.body(x)
            case x: ToData where accept.size > 0 => match(MediaTypes.tryParse(accept)){
                case Some(mt) => b.body(mt.fromData(x.toData()))
                case _ => b.body(status.reasonPhrase)
            }
            case _ => b.body(status.reasonPhrase)
        }
    }
}