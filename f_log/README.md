# 日志

## 配置
```bash
    # export cjHeapSize=4GB
    # pattern可省略，有默认值
    # %level 记录当前日志级别
    # %name 记录当前日志名称
    # %d 记录当前日志时间，花括号内是时间格式
    # %m 记录当前日志消息文本
    # %tid 记录当前线程ID
    # %pid 记录当前进程ID
#    export loggerAsyncBufsize=2 # 异步日志缓存池的初始化大小，默认是1024
    export logger_appender_console=FDemoConsole # 这是控制台日志记录器的名称，可以任意起名，名称得符合标识符规范
    export logger_appender_FDemoConsole_level=DEBUG # 控制台日志名
    export logger_appender_FDemoConsole_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%tid;%m' # 控制台日志格式，可以不指定这个是默认值
    export logger_appender_file=FDemoFile # 这是文件日志记录器的名称，可以任意起名
    export logger_appender_FDemoFile_level=INFO # 文件日志名
    export logger_appender_FDemoFile_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%tid;%m' # 文件日志格式，这个是默认值
    export logger_appender_FDemoFile_path=./log/fdemo.log # 日志文件路径
    export logger_appender_FDemoFile_rotateDuration=DAY # 按自然天切割日志
#    export logger_appender_FDemoFile_rotateSize=100000000 # 按日志文件大小切割日志，日志文件字节数达到这个值将重命名并创建新的日志文件
```

```cj
import fountain::f_log.*
private static let log1 = LoggerFactory.getLogger<TypeName>()
private static let log2 = LoggerFactory.getLogger('LoggerName')

public func foo(name: String): Unit {
    try{
        log1.info{'log message: ${name}'}
        log1.info('log message')
        log1.debug{'log message: ${name}'}
        log1.debug('log message')
        log1.warn{'log message: ${name}'}
        log1.warn('log message')
    }catch(e: Exception){
        log1.error(e){'log message: ${name}'}
        log1.error('log message', e)
        log1.warn(e){'log message: ${name}'}
        log1.warn('log message', e)
        log1.info(e){'log message: ${name}'}
        log1.info('log message', e)
        log1.debug(e){'log message: ${name}'}
        log1.debug('log message', e)
    }
}
```