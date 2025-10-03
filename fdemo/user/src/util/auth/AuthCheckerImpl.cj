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
package user.util.auth

import std.convert.*
import fountain.bean.*
import fountain.bean.macros.*
import fountain.mvc.*
import fountain.jwt.*
import user.util.*

@Bean
public class AuthCheckerImpl <: AuthChecker {
    public func check(ctx: HttpContext, patterns: HttpRequestPathPatterns): Bool {
        if(let Some(jwt) <- ctx.request.headers.getFirst('Authorization')){
            UserSessionCache.verify(jwt)
        }else{
            false
        }
    }
}