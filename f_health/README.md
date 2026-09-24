进程健康检查
---

## 配置
```cj
public struct HealthConfig {
    public static const HEALTH_PREFIX = 'health'
    public static const HEALTH_ENABLED = HEALTH_PREFIX + '_enabled'
    public static const HEALTH_LOG_MONITOR_PERIOD = HEALTH_PREFIX + '_logMonitorPeriod'
    /**
     * 启用的监控器名称
     */
    public static prop enabled: Array<String> 
    /**
     * 日志监控周期，默认1秒，配置值小于1秒时，使用1秒
     */
    public static prop logMonitorPeriod: Duration 
}
```

## 健康数据
```cj
import std.runtime.*
import fountain::f_data.*
import fountain::f_data.macros.*

@DataAssist[fields]
public class HealthData {
    public prop allocatedHeapSize: Int64 
    // 已分配的堆
    public prop heapPhysicalMemory: Int64 
    // 阻塞状态的线程数
    public prop blockingThreadCount: Int64 
    // gc次数
    public prop gcCount: Int64 
    // GC后成功回收的内存
    public prop gcFreedSize: Int64 
    // GC总耗时
    public prop gcTime: Int64 
    // 最大堆大小
    public prop maxHeapSize: Int64 
    // 系统线程数
    public prop nativeThreadCount: Int64 
    // 处理器数量
    public prop processorCount: Int64 
    // 仓颉线程数
    public prop threadCount: Int64
    // 已使用的堆大小
    public prop usedHeapSize: Int64 
}
```

## 监控器
```cj
public interface HealthMonitor {
    prop name: String // 监控器名称
    func emit(data: HealthData): Unit // 输出数据
}
```

### 监控器HUB
```cj
public struct HealthMonitorHub {
    // 注册监控器
    public static func register(monitor: HealthMonitor): Unit 
}
```

### 日志监控器
```cj
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
```