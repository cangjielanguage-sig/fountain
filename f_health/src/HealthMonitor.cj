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

import std.collection.concurrent.ConcurrentHashMap
import fountain::f_data.*
import fountain::f_log.*

public interface HealthMonitor {
    prop name: String
    func emit(data: HealthData): Unit
}

public struct HealthMonitorHub {
    private static let monitors = ConcurrentHashMap<String, HealthMonitor>()

    public static func register(monitor: HealthMonitor): Unit {
        monitors[monitor.name] = monitor
    }
    static func emit(monitor: String, data: HealthData): Unit {
        monitors.get(monitor)?.emit(data)
    }
}
public struct HealthLogMonitor <: HealthMonitor {
    private static let log = LoggerFactory.getLogger<HealthLogMonitor>()
    static init(){
        HealthMonitorHub.register(HealthLogMonitor())
    }
    private init(){}
    public prop name: String{
        get(){
            'log'
        }
    }
    public func emit(data: HealthData): Unit{
        log.info{"HealthData: ${(JsonValue.tryFromData(data.toData()) as JsonValue).getOrThrow()}"}
    }
}