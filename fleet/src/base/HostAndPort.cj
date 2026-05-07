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
package fountain::fleet.base

import std.convert.*

public struct HostAndPort {
    public let host: String
    public let port: UInt16

    public init(host: String) {
        if (let Some(idx) <- host.indexOf(':')) {
            this.host = host[0..idx]
            this.port = UInt16.parse(host[idx + 1..])
        } else {
            this.host = host
            this.port = 1203
        }
    }
}
