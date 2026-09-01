# f_app

**注意⚠️**：本模块为kill 15和CTRL+C注册了信号处理函数。如果不注册信号处理函数也不导入本模块，atExit注册的进程退出函数不会生效。


## 导入

```cj
import fountain::f_app.*
main(args: Array<String>): Unit {
    App(args).boot()
}
```


## 子命令

如果需要为fboot实现新的子命令可以实现以下接口
```cj
package fountain::f_app.SubCommand
public interface SubCommand{
    /**
     * 子命令名，即fboot <subcommand> 
     */
    prop command: String
    /**
     * 执行，args是去掉了首个参数的命令行实参。首个命令行参数就是子命令的名字
     */
    func exec(args: Array<String>): Int64
}
```

### 参考实现
创建动态链接库项目，实现SubCommand。
在项目的动态链接库目录执行`fboot newcmd --dylibPattern='dylib_name_regex_to_load'`
```cj
package org::module.pkg

import fountain::f_app.{SubCommand, SubCommandMediator}
public struct NewSubCommand <: SubCommand {
    static init(){
        SubCommandMediator.register(NewSubCommand())
    }
    public prop command: String{
        get(){
            'newcmd'
        }
    }
    public func exec(args: Array<String>): Int64 {
        //do something
    }
}
```

### 发布子命令
这也是SubCommand的一个实现，由于它本身属于`fountain::f_app`模块的实现，而fboot依赖`fountain::f_app`，执行本命令不需要额外加载动态链接库
fboot pub <x.y.z> [--skip-test] [--skip-lint]

--skip-* 参数可选。

如果要一次连续发布多个模块可以使用这个。
如果要选择发布项目内的部分模块可以项目根目录添加.modules文件。
在文件内添加
```
[include]
# 后面一个模块名一行，
# 如果当前目录也是一个要发布的模块，用.指代
# 开头的行是注释，本命令会忽略这些模块
# 这是要发布的模块

[exclude]
# 这是忽略的模块，[include] [exclude]只能指定一个

[detention]
# 这里的模块不发布，只是临时保留，未开发完成的模块名可放在此处，以免将来开发完成了忘记添加到include或exclude
```

## 应用初始化

```cj
/**
 * 应用初始化API。应用代码通常不需要实现本接口。
 */
public interface Initializer {
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
     * 因此不同模块或功能的启动函数不应有依赖关系，否则如果有两个start实现是阻塞的，就无法顺利完成初始化了。
     */
    func start(): Unit {}
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


## 注册信号处理函数
只有linux有效，其它操作系统是空函数体。
与std.runtime.registerSignalHandler(signal: Signal, handler: (Int32) -> Bool)拥有相同的意义
```cj
//注册新的信号处理函数，不清空相同信号的其它处理函数
public func registerSignalHandler(signals: Array<Signal>, handler: () -> Bool): Unit{}
public func registerSignalHandler(signals: Array<Signal>, handler: (Int32) -> Bool): Unit {}
public func registerSignalHandler(signal: Signal, handler: () -> Bool): Unit {}

// 注册前先清空相同信号的其它处理函数
public func resetAndRegisterSignalHandler(signals: Array<Signal>, handler: () -> Bool): Unit{}
public func resetAndRegisterSignalHandler(signals: Array<Signal>, handler: (Int32) -> Bool): Unit {}
public func resetAndRegisterSignalHandler(signal: Signal, handler: () -> Bool): Unit {}
```

## 使用main函数启动应用的简便方法
如果开发者想使用自己开发的main函数启动应用，可以调用本模块的以下API。
目前这个API只支持run子命令。
如果使用fboot命令启动应用的参数是`fboot run --dylibPattern='<dylib_name_regex_to_load>'`，使用以下API传的main函数参数就是`--dylibPattern='<dylib_name_regex_to_load>'`，App.start函数会自动加上run子命令。
```cj
main(args: Array<String>): Int64 {
    App.start(args)
}
```