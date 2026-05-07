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
package fountain::fleet.config

import std.convert.*
import fountain::f_config.Config
import fountain::fleet.base.HostAndPort
import fountain::fleet.exception.InvalidConfigException

public class SyncConfig {
    public static const sync: String = 'sync'
    public static const hosts: String = sync + '_hosts'
    public static const dataPath: String = sync + '_dataPath'

    public static func getHosts(): Array<HostAndPort> {
        if (let Some(hostsStr) <- Config.getString(hosts)) {
            let parts = hostsStr.split(',')
            Array<HostAndPort>(parts.size) { i => HostAndPort(parts[i]) }
        } else {
            throw InvalidConfigException('sync_hosts is required')
        }
    }

    public static func getDataPath(): String {
        Config.getString(dataPath) ?? '/tmp/fleet'
    }
}
