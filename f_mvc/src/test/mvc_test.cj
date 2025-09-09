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
package f_mvc.test

import f_mvc.*
import f_mvc.macros.*

@Controller
public class UserController {
    private static let log = LoggerFactory.getLogger<UserController>()
    @PostMapping[path: '/user/session',
                 consumes: 'application/json',
                 produces: 'application/json']
    public func login(@RequestBody request: LoginRequest){
        log.info('user login request: name:{name}', request)
        ...
    }
}

@WSEndPoint['/ws/chat']
public class ChatEndPoint{
    @OnWSText['text/plain', TextWebFrame]
    public func onBinary(text: String): String {
        text
    }
}