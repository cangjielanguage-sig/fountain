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