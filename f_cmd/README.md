# f_cmd
```cj
public class CmdArgs {
    // 得到CmdArgs实例
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