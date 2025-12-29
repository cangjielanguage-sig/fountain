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
package user.util

import std.convert.*
import fountain.base.*
import fountain.cache.*
import fountain.jwt.JWT
import fountain.mvc.CurrentHttpContext
import fountain.util.UUID

public class UserSessionCache {
    private static let cache = HeapCache<UserSession>(maxLife: Duration.hour)
    private static let expire = Duration.hour
    private init(){}
    public static func generate(userId: Int64): String {
        let session = UserSession(userId, UUID.random().toHexString())
        cache.set('${userId}', session)
        hmacKey(JWT.encoder(), session).keyId(session.userId.toString()).expire(expire).sign()
    }
    public static func verify(jwtStr: String): Bool {
        let jwt = JWT.verifier(jwtStr)
        if(let Some(userIdStr) <- jwt.getKeyId() && userIdStr.size > 0 && 
            let Some(userId) <- Int64.tryParse(userIdStr) && userId > 0 && 
            let Some(session) <- cache.get(userIdStr)){
            hmacKey(jwt, session)
            jwt.verify()
        } else {
            false
        }
    }
    public static func verify(): Bool {
        if(let Some(jwt) <- CurrentHttpContext.instance.request.headers.getFirst('Authorization')){
            verify(jwt)
        }else{
            false
        }
    }
    private static func hmacKey<T>(jwt: T, session: UserSession): T where T <: JWT {
        jwt.hmacMD5(session.toBytes())
    }
    public static func remove(userId: Int64) {
        cache.remove('${userId}')
    }
}
public class UserSession {
    UserSession(public let userId: Int64, public let key: String){}

    public func toBytes() {
        '${userId}_${key}'.unsafeBytes()
    }
}
