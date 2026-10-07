# f_log

## STDX dependency

Configure the environment variable: `export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

Logging module: `LoggerFactory` fetches a `Logger` by name or by type, logs are output through appenders (console, file, rotating file, Unix domain socket, UDP, TCP, etc.), and the logging action is asynchronous by default.

You can also use the same-named APIs of this module through the `fountain::fountain.log` package.

## Configuration

```bash
    # export cjHeapSize=4GB
    # pattern may be omitted; there is a default value
    # %level records the current log level
    # %name records the current log name
    # %app records the application name (f_version.AppVersion.name)
    # %appver records the application version number (f_version.AppVersion.version)
    # %d records the current log time; the braces contain the time format
    # %m records the current log message text
    # %tid records the current thread ID
    # %pid records the current process ID
#    export loggerAsyncBufsize=2 # Initial size of the asynchronous log buffer pool, 1024 by default
    export logger_appender_console=FDemoConsole # Name of this console log appender; any name is allowed as long as it is a valid identifier
    export logger_appender_FDemoConsole_level=DEBUG # Console log level
    export logger_appender_FDemoConsole_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%tid;%m' # Console log format; you may omit this, it is the default
    export logger_appender_file=FDemoFile # Name of this file log appender; any name is allowed
    export logger_appender_FDemoFile_level=INFO # File log level
    export logger_appender_FDemoFile_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%tid;%m' # File log format; this is the default
    export logger_appender_FDemoFile_path=./log/fdemo.log # Log file path
    export logger_appender_FDemoFile_rotateDuration=DAY # Rotate the log by calendar day
#    export logger_appender_FDemoFile_rotateSize=100000000 # Rotate the log by file size; once the log file reaches this many bytes it is renamed and a new log file is created
```

The uniform shape of the configuration keys is `logger_appender_<config name>=<appender name>` to declare an appender, and then `logger_appender_<appender name>_<field>` to configure its fields.

## Usage

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

## Appender types

`logger_appender_<kind>` is a comma-separated list of appender names (`kind` is given in the table below), and then `logger_appender_<appender name>_<field>` configures each appender:

| kind | Parameter class | Output target | Dedicated configuration fields |
|---|---|---|---|
| `console` | `ConsoleLoggerParams` | Standard output | `pattern`, `level`, `closable` |
| `file` | `FileLoggerParams` (base class `RotatableFileParams`) | File | `path` (default `<working directory>/logs/<command name>.log`), `rotateDuration` (default `DAY`), `rotateSize` (default `Int64.Max`), `compressFormat`, `url`; the parameter class exposes the fields `fileSize`/`timeunit`/`compress` |
| `unix` | `UnixLoggerParams` | Unix domain socket | `host`/`port` |
| `unixDatagram` | `UnixDatagramLoggerParams` | Unix domain datagram | `host`/`port` |
| `udp` | `UdpLoggerParams` | UDP | `host`, `port` |
| `tcp` | `TcpLoggerParams` | TCP | `host`, `port` |
| (in-process) | `NoneLogAppender` | Discard | `closable` |

Other configuration items: `loggerAsyncBufsize` (initial size of the asynchronous buffer pool, 1024 by default), `logger_asyncWaitTimeout` (time to wait for the asynchronous queue); `LoggerConfig.filter` can set a `LogFilter`.

`LogPattern`/`LogPart` are the programmable form of the log format; `LogFileCompressFormat` specifies the compression format of rotated files (including `NonCompression`).

## Notes

- Log writes go through an asynchronous queue (`LoggerAppenderFacade <: AsyncLogger`); when the queue is full, entries are dropped according to the policy instead of blocking business threads; `loggerAsyncBufsize` only affects the initial size of the buffer pool.
- `Logger.level` is a `mut prop` and can be adjusted at runtime; `traceEnabled`/`debugEnabled`/... are used to avoid building expensive log arguments.
- `%app`/`%appver` come from `f_version.AppVersion` and are empty strings when the application has not called `AppVersion.set`.
