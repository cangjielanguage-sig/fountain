# f_cmd

解析`env.getCommandLine()`，提供全局单例式的命令行参数查询。

```cj
public class CmdArgs {
    // 得到CmdArgs实例（首次访问时快照一次命令行）
    public static let instance: CmdArgs
    //得到以prefix开头的命令行参数
    public func getAllKeys(prefix: String): Array<String> 
    //判断指定命令行参数是否存在
    public func contains(name: String): Bool 
    //得到指定名称的命令行参数值列表
    public func getArgs(name: String): Option<ArrayList<String>> 
    // 得到指定名称的命令行参数值
    public func getArg(name: String): Option<String> 
    //得到进程名
    public func getAppName(): String 
    //得到进程文件所在路径
    public prop commandPath: Path
    //得到当前工作目录
    public prop currentWorkingDirectory: Path 
    //得到指定名称的命令行参数值
    public func getArgValue<T>(name: String): Option<T> where T <: Parsable<T> 
}
```

异常：`fountain::f_cmd.exception.CmdException`。

## 解析规则

| 命令行形态 | 键 | 值 |
|---|---|---|
| `--k=v` | `k`（去掉`--`） | `v`；同名重复出现时追加到列表 |
| `--flag` | `flag`（去掉`--`） | 空列表；已存在时不重置 |
| `-x` | `-x`（**保留**`-`） | 空列表；重复出现时重置为空 |
| 位置参数 | 最近一个`-x`/`--x`的键 | 追加到该键的值列表 |

因此`--db.host=127.0.0.1`要按`getArg('db.host')`查询，而`-p 8080`要按`getArgs('-p')`查询。

## 使用示例

```cj
import fountain::f_cmd.CmdArgs
// 命令行：myapp --db.host=127.0.0.1 --db.port=5432 --verbose -p 8080 a.txt
let args = CmdArgs.instance
let host = args.getArg('db.host')              // Some("127.0.0.1")
let port = args.getArgValue<Int64>('db.port')  // Some(5432)
let on = args.contains('verbose')              // true
let keys = args.getAllKeys(prefix: 'db')       // ["db.host", "db.port"]，顺序不保证
let pl = args.getArgs('-p')                    // Some(["8080", "a.txt"])
```

## 注意事项

- `instance`是懒初始化的静态单例：命令行在**首次访问`CmdArgs`**时快照一次，`currentWorkingDirectory`同样只在那一刻缓存（之后`cd`不生效）；`commandPath`相反是每次访问现算。
- `getAllKeys`的结果顺序来自`HashMap.keys()`，不保证是命令行顺序。
- 不支持`--`终止符、不支持组合短选项（`-abc`会被当作整键`-abc`）。
- 位置参数必须跟在某个`-x`/`--x`之后；出现在任何选项之前的位置参数没有归属键，不要依赖。
