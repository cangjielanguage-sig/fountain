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
package fountain::f_health

import std.sync.Timer
import fountain::f_app.*

public struct HealthInitializer <: Initializer {
    static init(){
        InitializerCollection.register(HealthInitializer())
    }
    private init(){}
    public prop name: String {
        get(){
            ''
        }
    }
    public prop dependencies: Array<String> {
        get(){
            []
        }
    }
    public func initialize(): Unit {
        let period = HealthConfig.logMonitorPeriod
        let enabled = HealthConfig.enabled
        Timer.repeat(period, period, {=> 
            let data = HealthData()
            for(e in enabled){
                HealthMonitorHub.emit(e, data)
            }
        })
    }
}