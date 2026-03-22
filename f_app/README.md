包括应用启动的子命令、加载应用的动态链接库、初始化应用的API等
---
## 导入
```cj
import fountain::f_app.*
main(args: Array<String>): Unit {
    App(args).boot()
}
```

## 子命令

### run [path] --dylibPattern='<正则表达式>'
启动应用，此命令会指定路径目录和子目录里的所有文件，并加载文件名符合正则表达式的仓颉动态链接库。如果没有指定路径，会遍历工作目录。

### module <module_name>
在当前目录创建一个模块

### `workspace <name> <FountainVersion>`
在工作目录创建workspace项目
`<name>`可以是一个标识符，将在当前目录创建仓颉workspace项目；也可以是绝对路径，将在`<name>`表示的路径初始化workspace项目；也可以相对路径，将在`<name>`表示的相对于当前目录的子目录初始化workspace项目
`<FountainVersion>`是即将创建的项目所依赖的fountain版本号，此命令将自动添加`fountain::f_base`和`fountain::f_version`中心仓依赖。

### cleanUpdate 
工作目录是仓颉项目，并为此项目执行`cjpm clean; cjpm update`

### build
工作目录是仓颉项目，并为此项目执行`cjpm build`

### count
计数工作目录的代码量，包括模块数、包数、文件名、行数
- --ignoreComments 忽略所有注释
- --ignoreBrackets 忽略单独成行的各种括号

### version
显示当前应用的版本

### version <x.y.z> <'message'> tag
修改当前目录的cjpm.toml版本号，并创建git 版本，以message作为版本消息

## 应用初始化
```cj
/**
 * 应用初始化API。应用代码通常不需要实现本接口。
 */
public interface Initializer <: Resource {
    /**
     * 待初始化的功能名称
     * 有些功能只能显式地调用函数完成初始化，fountain::f_bean fountain::f_mvc fountain::f_orm fountain::f_ticktock都是这类
     * @return
     */
    prop name: String
    /**
     * 依赖项，必须在这些功能初始化后才能初始化当前功能
     * @return
     */
    prop dependencies: Array<String> {
        get(){
            []
        }
    }
    /**
     * 调用本函数实现完成初始化
     */
    func initialize(): Unit
    /**
     * 返回启动函数，调用返回的函数是否阻塞取决于具体实现，比如调用mvc的启动函数会启动http服务并一直阻塞。
     */
    func starter(): ?() -> Unit {
        None
    }
    /**
     * 应当只关闭初始化器本身。不要把模块资源的释放放在这里。
     */
    func close(): Unit {}
    func isClosed(): Bool {
        false
    }
}
```

## 应用初始化函数的集合
```cj
public struct InitializerCollection {
    private static let dependencies = ConcurrentHashMap<String, ArrayList<String>>()//VALUE依赖KEY
    /**
     * 注册模块的初始化函数。通常应用APP不需要调用它。
     */
    public static func register(initializer: Initializer): Unit
}
```