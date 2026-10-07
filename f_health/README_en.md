Process health check
---

## Configuration
```cj
public struct HealthConfig {
    public static const HEALTH_PREFIX = 'health'
    public static const HEALTH_ENABLED = HEALTH_PREFIX + '_enabled'
    public static const HEALTH_LOG_MONITOR_PERIOD = HEALTH_PREFIX + '_logMonitorPeriod'
    /**
     * Names of the enabled monitors
     */
    public static prop enabled: Array<String> 
    /**
     * Log monitoring period, 1 second by default; values smaller than 1 second are treated as 1 second
     */
    public static prop logMonitorPeriod: Duration 
}
```

## Health data
```cj
import std.runtime.*
import fountain::f_data.*
import fountain::f_data.macros.*

@DataAssist[fields]
public class HealthData {
    public prop allocatedHeapSize: Int64 
    // Allocated heap
    public prop heapPhysicalMemory: Int64 
    // Number of threads in blocked state
    public prop blockingThreadCount: Int64 
    // Number of GC runs
    public prop gcCount: Int64 
    // Memory successfully reclaimed after GC
    public prop gcFreedSize: Int64 
    // Total GC time
    public prop gcTime: Int64 
    // Maximum heap size
    public prop maxHeapSize: Int64 
    // Number of system threads
    public prop nativeThreadCount: Int64 
    // Number of processors
    public prop processorCount: Int64 
    // Number of Cangjie threads
    public prop threadCount: Int64
    // Used heap size
    public prop usedHeapSize: Int64 
}
```

## Monitors
```cj
public interface HealthMonitor {
    prop name: String // Monitor name
    func emit(data: HealthData): Unit // Emit data
}
```

### Monitor HUB
```cj
public struct HealthMonitorHub {
    // Register a monitor
    public static func register(monitor: HealthMonitor): Unit 
}
```

### Initializer
```cj
/**
 * An initializer registered with f_app at application startup: it collects HealthData at the period of
 * HealthConfig.logMonitorPeriod and dispatches it to each monitor listed in HealthConfig.enabled
 */
public struct HealthInitializer <: Initializer {
    public prop name: String            // Empty string
    public prop dependencies: Array<String>  // Empty array
    public func initialize(): Unit
}
```

### Log monitor
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
