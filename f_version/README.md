# f_version


## STDX依赖

配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

本模块向框架提供应用项目的版本号和fountain工具库的版本号


## fountain版本号

```cj
//使用fboot构建fountain时会把版本号替换成最新版本号
public const FountainVersion: String = "fountain(1.1.2)"
```


## 应用项目版本号

```cj
//使用fboot构建应用项目，会创建一个模块并把项目版本填充到这个模块。fountain::f_app.App会从这个模块读取项目名和版本号。
public struct AppVersion {
    public static func set(banner: String, name: String, version: String): Unit
}
```
