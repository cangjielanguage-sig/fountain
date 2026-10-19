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
package fountain::fdbm.server

import fountain::f_log.AbstractLogger
import fountain::fdbm.execute.ExecutorDispatcher

/** 服务端依赖容器（设计 §10.2）：handler 只从这里取依赖，便于用例替换。 */
protected class ServerContext {
    public let sessions: SessionRegistry
    public let dispatcher: ExecutorDispatcher
    public let custom: CustomExtensions
    public let logger: AbstractLogger

    public init(sessions: SessionRegistry, dispatcher: ExecutorDispatcher,
        custom: CustomExtensions, logger: AbstractLogger) {
        this.sessions = sessions
        this.dispatcher = dispatcher
        this.custom = custom
        this.logger = logger
    }
}
