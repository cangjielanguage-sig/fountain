# f_app

**注意⚠️**：本模块为kill 15和CTRL+C注册了信号处理函数。如果不注册信号处理函数也不导入本模块，atExit注册的进程退出函数不会生效。


## 导入

- [导入](doc/导入.md)

## 子命令

- [子命令](doc/子命令.md)

## 应用初始化

- [应用初始化](doc/应用初始化.md)

## 应用初始化函数的集合

- [应用初始化函数的集合](doc/应用初始化函数的集合.md)

## 注册信号处理函数
只有linux有效，其它操作系统是空函数体。
与std.runtime.registerSignalHandler(signal: Signal, handler: (Int32) -> Bool)拥有相同的意义
```cj
public func registerSignalHandler(signals: Array<Signal>, handler: () -> Bool): Unit{}
public func registerSignalHandler(signals: Array<Signal>, handler: (Int32) -> Bool): Unit {}
public func registerSignalHandler(signal: Signal, handler: () -> Bool): Unit {}
```