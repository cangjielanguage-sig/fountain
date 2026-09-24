## 安装
```bash
cjpm install "fountain::fboot"="a.b.c" --root /path/to/install # 把a.b.c换成具体的版本号
export PATH=$PATH:/path/to/install/bin
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/path/to/install/libs/fboot
```

## 启动
```bash
fboot run --dylibPattern=<REGEX_OF_PROJECT_DYLIB_FILENAMES> # 具体查看项目的fdemo模块的boot.sh脚本
```

## 创建项目与添加依赖
安装`fboot`之后，可以执行`fboot workspace`将当前目录初始化为仓颉workspace项目，详细见下面的子命令列表。
workspace下的每个模块的编译目标务必是**动态链接库**。
项目需要的任何模块都在项目根目录的cjpm.toml添加。以`f_base`为例：
```toml
[dependencies]
"fountain::f_base" = "a.b.c" # 把a.b.c换成具体的版本号
```

## fboot命令列表

```
1.  应用项目只需要编译为动态链接库，把应用的动态链接库加入LD_LIBRARY_PATH
2.  fboot run [PATH] --dylibPattern=<DYNAMIC_LIB_NAME_REGEX_WITHOUT_EXTNAME> 可以用来启动应用项目
3.  fboot workspace 将当前目录初始化为仓颉workspace
4.  fboot workspace <spacename> 在当前目录创建名为<spacename>的子目录，并将它初始化为仓颉workspace
5.  fboot workspace <direct_path> 将绝对路径创建为仓颉workspace
6.  fboot module 将当前目录初始化为仓颉dynamic项目
7.  fboot module <module_name> 在当前目录创建名为<module_name>的子目录，并初始化为仓颉dynamic模块，并把模块加入当前目录的cjpm.toml
8.  fboot build 编译使用fountain开发的应用项目
9.  fboot count 数当前目录的仓颉代码模块数、包数、文件数、行数、计数耗时
10. fboot pub <version> 发布当前路径下的仓颉模块
11. fboot <subcmd> --dylibPattern=<DYNAMIC_LIB_NAME_REGEX_WITHOUT_EXTNAME> 运行实现了`fountain::f_app.SubCommand`的子命令
==============下面的命令用来管理fountain本身===================
12. fboot version 显示当前fountain版本号
13. fboot help 显示命令列表
```
