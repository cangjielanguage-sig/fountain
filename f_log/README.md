# f_log

## STDX依赖

配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

日志模块：`LoggerFactory`按名称或类型取`Logger`，日志通过appender（控制台、文件、轮转文件、Unix域套接字、UDP、TCP等）输出，记录动作默认异步执行。

也可以使用`fountain::fountain.log`包使用本模块的同名API。

## 配置

```bash
    # export cjHeapSize=4GB
    # pattern可省略，有默认值
    # %level 记录当前日志级别
    # %name 记录当前日志名称
    # %app 记录应用名（f_version.AppVersion.name）
    # %appver 记录应用版本号（f_version.AppVersion.version）
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

配置键的统一形态是`logger_appender_<配置名>=<appender名>`声明一个appender，再用`logger_appender_<appender名>_<字段>`配置它的字段。

## 使用

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

## Appender类型

`logger_appender_<kind>`是以逗号分隔的appender名列表（`kind`见下标），再用`logger_appender_<appender名>_<字段>`配置每个appender：

| kind | 参数类 | 输出目标 | 专有配置字段 |
|---|---|---|---|
| `console` | `ConsoleLoggerParams` | 标准输出 | `pattern`、`level`、`closable` |
| `file` | `FileLoggerParams`（基类`RotatableFileParams`） | 文件 | `path`（默认`<工作目录>/logs/<命令名>.log`）、`rotateDuration`（默认`DAY`）、`rotateSize`（默认`Int64.Max`）、`compressFormat`、`url`；参数类公开字段`fileSize`/`timeunit`/`compress` |
| `unix` | `UnixLoggerParams` | Unix域套接字 | `host`/`port` |
| `unixDatagram` | `UnixDatagramLoggerParams` | Unix域数据报 | `host`/`port` |
| `udp` | `UdpLoggerParams` | UDP | `host`、`port` |
| `tcp` | `TcpLoggerParams` | TCP | `host`、`port` |
| （程序内） | `NoneLogAppender` | 丢弃 | `closable` |

其他配置项：`loggerAsyncBufsize`（异步缓冲池初始大小，默认1024）、`logger_asyncWaitTimeout`（等待异步队列的时间）；`LoggerConfig.filter`可设置`LogFilter`。

`LogPattern`/`LogPart`是日志格式的可编程形式；`LogFileCompressFormat`用于指定轮转文件的压缩格式（含`NonCompression`）。

## 注意事项

- 日志写入走异步队列（`LoggerAppenderFacade <: AsyncLogger`），队列满时会按策略丢弃而不是阻塞业务线程；`loggerAsyncBufsize`只影响缓冲池初始化大小。
- `Logger.level`是`mut prop`，可以在运行期调整；`traceEnabled`/`debugEnabled`/... 用于避免构造昂贵的日志参数。
- `%app`/`%appver`取自`f_version.AppVersion`，应用未调用`AppVersion.set`时为空字符串。
