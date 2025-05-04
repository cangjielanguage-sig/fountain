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

public class RequestMeta <: HttpRequestHandler {
    private let consumes = HashSet<String>()
    private let produces = HashSet<String>()
    private let headOnly = ThreadLocal<Bool>()
    private var pathPattern = None<PathPattern>

    public RequestMeta(
        consumes!: Array<String> = [],
        produces!: Array<String> = [],
        public let ignoreAuth!: Bool = false,
        public let ignorePrivilege!: Bool = false,
        public let method!: RequestMethod,
        public let path!: String = "",
        private let handler!: (HttpContext, Bool, PathPattern) -> Unit){
            for(c in consumes){
                this.consumes.add(c.trimAscii())
            }
            for(p in produces){
                this.produces.add(p.trimAscii())
            }
    }
    func acceptable(accept: String){
        produces.contains(accept)
    }
    func supportedMediaType(mediaType: String) {
        consumes.contains(mediaType)
    }
    func setPathPattern(pattern: PathPattern){
        this.pathPattern = pattern
    }
    public func addConsumes(mediaType: Array<String>): Unit {
        consumes.add(all: mediaType)
    }
    public func addProduces(mediaType: Array<String>): Unit {
        produces.add(all: mediaType)
    }
    func setHeadOnly(){
        headOnly.set(true)
    }
    public func handle(ctx: HttpContext): Unit {
        try{
            handler(ctx, headOnly.get() ?? false, pathPattern.getOrThrow())
        } finally {
            headOnly.set(None)
        }
    }
}
