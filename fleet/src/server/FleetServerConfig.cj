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
package fountain::fleet.server

import fountain::f_config.*
import fountain::f_process.getAbsoluteCommandDir

internal struct FleetServerConfig {
    private static const CONF_PREFIX = FleetConfig.CONF_PREFIX
    public static const FLEET_SERVER_PORT = CONF_PREFIX + '_port'
    public static const FLEET_SERVER_STORE_PATH = CONF_PREFIX + '_storePath'
    public static const FLEET_SERVER_BUFFER_QUEUE_SIZE = CONF_PREFIX + '_bufferQueueSize'
    public static const FLEET_SERVER_CONNECTION_CHECK_DURATION = CONF_PREFIX + '_connectionCheckDuration'
    
    private init(){}

    /**
     * 获取FleetServer监听的端口号，默认是2350
     */
    public static prop port: UInt16 {
        get() {
            Config.getValue<UInt16>(FLEET_SERVER_PORT) ?? 2350u16
        }
    }
    /**
     * 获取FleetServer存储路径，默认是fboot可执行文件
     */
    public static prop storePath: Path {
        get() {
            let p = if(let Some(p) <- Config.getString(FLEET_SERVER_STORE_PATH)){
                Path(p)
            } else {
                let p = getAbsoluteCommandDir()
                if(!p.toString().contains('/fountain')){
                    if(p.fileName == 'bin'){
                        p.parent
                    }else{
                        p
                    }.join('fountain')
                }else if (p.fileName == 'bin'){
                    p.parent
                }else{
                    p
                }.join('fleet/store')
            }
            Director.create(p, recursive: true)
            p
        }
    }
    /**
     * 获取FleetServer缓存队列大小，默认是1024
     */
    public static prop bufferQueueSize: Int64 {
        get() {
            Config.getValue<Int64>(FLEET_SERVER_BUFFER_QUEUE_SIZE) ?? 1024
        }
    }
    /**
     * 获取FleetServer连接检查间隔，默认是1000毫秒
     */
    public static prop connectionCheckDuration: Duration {
        get() {
            Duration.millisecond * (Config.getValue<Int64>(FLEET_SERVER_CONNECTION_CHECK_DURATION) ?? 1000)
        }
    }
    public static prop hosts: Array<String> {
        get() {
            FleetConfig.hosts
        }
    }
}