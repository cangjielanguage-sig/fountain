# f_version

## STDX依赖

配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

本模块向框架提供应用项目的版本号和fountain工具库的版本号，以及进程启动时刻。

## fountain版本号

```cj
//使用fboot构建fountain时会把版本号替换成最新版本号
public const Version = "1.3.7"
public const FountainVersion: String = "fountain(" + Version + ")"
```

`Version` 是发布时由 `fboot version x.y.z` 或 `cangjie.sh` 脚本写入的常量，不要手工改。

## 应用项目版本号

使用fboot构建应用项目，会创建一个模块并把项目版本填充到这个模块。fountain::f_app.App会从这个模块读取项目名和版本号。

```cj
public struct AppVersion {
    /**由fboot生成的应用信息模块调用，进程内只应调用一次*/
    public static func set(banner: String, name: String, version: String): Unit
    /**应用的启动BANNER，未调用set时为空字符串*/
    public static prop banner: String
    /**应用名，未调用set时为空字符串*/
    public static prop name: String
    /**应用版本号，未调用set时为空字符串*/
    public static prop version: String
}
```

`AppVersion` 的三个属性未调用 `set` 时返回空字符串（不抛异常），调用方需要自己判断是否为空。`f_log` 的 `%app`、`%appver` 占位符就是从这三个属性取值。

## 进程启动时刻

```cj
/**f_version包初始化时求值，作为应用启动耗时的起点*/
public let AppStarts: MonoTime
```

`AppStarts` 是顶层 `let`，在 `f_version` 包初始化时求值，`f_app` 用它计算应用启动耗时。
