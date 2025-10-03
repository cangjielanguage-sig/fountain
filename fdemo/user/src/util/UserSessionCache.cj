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

import fountain.cache.*

public class UserSessionCache {
    private static let cache = HeapCache<UserSession>(maxLife: Duration.hour)
    private init(){}
    public static func set(userId: Int64, token: String) {
        cache.set('${userId}', UserSession(userId, token))
    }
    public static func check(userId: Int64, token: String): Bool {
        if(let Some(s) <- cache.get('${userId}')){
            s.token == token
        } else {
            false
        }
    }
    public static func remove(userId: Int64) {
        cache.remove('${userId}')
    }
}
public class UserSession {
    UserSession(public let userId: Int64, public let token: String){}
}