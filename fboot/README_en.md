## Installation
```bash
cjpm install "fountain::fboot"="a.b.c" --root /path/to/install # replace a.b.c with the actual version number
export PATH=$PATH:/path/to/install/bin
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/path/to/install/libs/fboot
```

## Startup
```bash
fboot run --dylibPattern=<REGEX_OF_PROJECT_DYLIB_FILENAMES> # see the boot.sh script of the project's fdemo module for details
```

## Creating a project and adding dependencies
After installing `fboot`, you can run `fboot workspace` to initialize the current directory as a Cangjie workspace project; see the subcommand list below for details.
The compilation target of every module under the workspace must be a **dynamic library**.
Add any module the project needs to the cjpm.toml in the project root directory. Take `f_base` as an example:
```toml
[dependencies]
"fountain::f_base" = "a.b.c" # replace a.b.c with the actual version number
```

## fboot command list

```
1.  An application project only needs to be compiled into a dynamic library; add the application's dynamic library to LD_LIBRARY_PATH
2.  fboot run [PATH] --dylibPattern=<DYNAMIC_LIB_NAME_REGEX_WITHOUT_EXTNAME> can be used to start an application project
3.  fboot workspace initializes the current directory as a Cangjie workspace
4.  fboot workspace <spacename> creates a subdirectory named <spacename> in the current directory and initializes it as a Cangjie workspace
5.  fboot workspace <direct_path> creates an absolute path as a Cangjie workspace
6.  fboot module initializes the current directory as a Cangjie dynamic project
7.  fboot module <module_name> creates a subdirectory named <module_name> in the current directory, initializes it as a Cangjie dynamic module, and adds the module to the cjpm.toml of the current directory
8.  fboot build compiles an application project developed with fountain
9.  fboot count counts the number of Cangjie code modules, packages, files and lines in the current directory, and the time taken
10. fboot pub <version> publishes the Cangjie module under the current path
11. fboot <subcmd> --dylibPattern=<DYNAMIC_LIB_NAME_REGEX_WITHOUT_EXTNAME> runs a subcommand that implements `fountain::f_app.SubCommand`
==============The commands below manage fountain itself===================
12. fboot version shows the current fountain version number
13. fboot help shows the command list
```
