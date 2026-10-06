# f_process

## STDX依赖

配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

本模块给`String`和`std.process.SubProcess`补上进程扩展：命令行字符串直接启动子进程、用`|`把子进程串成管道、把子进程接到任意`InputStream`/`OutputStream`，以及当前进程的标准流读写器与可执行文件路径。

**本模块不经过shell**：`exec`只按空格切分参数，`piped`只按字面`|`切分命令串，因此没有引号、转义、通配符展开。

## String扩展

```cj
extend String <: ExtendProcess {
    /**按空格切分命令行并启动子进程，默认stdIn/stdOut为Pipe、stdErr为Inherit*/
    public func exec(workingDirectory!: ?Path = getWorkingDirectory(),
        environment!: ?Map<String, String> = enviromentVariables, stdIn!: ProcessRedirect = Pipe,
        stdOut!: ProcessRedirect = Pipe, stdErr!: ProcessRedirect = Inherit): SubProcess
    /**把子进程接到给定的InputStream/OutputStream，内部用asyncPipe协程异步搬运，返回Unit*/
    public func piped(workingDirectory!: ?Path = getWorkingDirectory(),
        environment!: ?Map<String, String> = enviromentVariables, stdIn!: InputStream, stdOut!: OutputStream,
        bufSize!: Int64 = 4096, stdErr!: ProcessRedirect = Inherit): Unit
    /**只接管stdOut*/
    public func piped(workingDirectory!: ?Path = getWorkingDirectory(),
        environment!: ?Map<String, String> = enviromentVariables, stdOut!: OutputStream, bufSize!: Int64 = 4096,
        stdIn!: ProcessRedirect = Pipe, stdErr!: ProcessRedirect = Inherit): SubProcess
    /**只接管stdIn*/
    public func piped(workingDirectory!: ?Path = getWorkingDirectory(),
        environment!: ?Map<String, String> = enviromentVariables, stdIn!: InputStream, bufSize!: Int64 = 4096,
        stdOut!: ProcessRedirect = Pipe, stdErr!: ProcessRedirect = Inherit): SubProcess
    /**按字面`|`切分命令串，逐段启动并用管道连接，返回(第一个子进程, 最后一个子进程)*/
    public func piped(workingDirectory!: ?Path = getWorkingDirectory(),
        environment!: ?Map<String, String> = enviromentVariables, stdIn!: ProcessRedirect = Pipe,
        stdOut!: ProcessRedirect = Pipe, stdErr!: ProcessRedirect = Inherit): (?SubProcess, ?SubProcess)
    /**等价于 this.exec() | next */
    public operator func |(next: SubProcess): SubProcess
    /**等价于 this.exec() | next.exec() */
    public operator func |(next: String): SubProcess
}
```

## SubProcess扩展

```cj
extend SubProcess <: ExtendSubProcess {
    /**同步把this的stdOutPipe搬运到next的stdInPipe，返回next*/
    public operator func |(next: SubProcess): SubProcess
    public operator func |(next: String): SubProcess
}
```

## 当前进程

```cj
/**当前进程标准输入的文本读入器，默认UTF8*/
public func stdReader(charset!: Charset = Charsets.UTF8): TextReader
/**当前进程标准输出/标准错误的文本写出器，默认UTF8*/
public func stdOutWriter(charset!: Charset = Charsets.UTF8): TextWriter
public func stdErrWriter(charset!: Charset = Charsets.UTF8): TextWriter
/**当前可执行文件的绝对路径，及其父目录*/
public func getAbsoluteCommand(): Path
public func getAbsoluteCommandDir(): Path
```

## 使用示例

```cj
import fountain::f_process.*

main() {
    //字符串管道：等价于 ls -l | grep .cj
    let p = 'ls -l' | 'grep .cj'
    p.wait()

    //子进程输出接到任意OutputStream
    let w = stdOutWriter()
    'git status --short'.piped(stdOut: w, bufSize: 8192)
    w.flush()

    //一次拿到首尾两个子进程
    let (first, last) = 'cat a.txt | wc -l'.piped()
    last.getOrThrow().wait()
}
```

## 注意事项

- `exec`的参数切分是`split(' ', removeEmpty: true)`，参数里带空格无法表达，需要时改用`launch`自行传参。
- 返回`Unit`的`piped`重载会丢弃两个`SubProcess`句柄（只能靠对端流关闭来结束子进程），需要`wait`/`kill`时请用返回`SubProcess`的重载。
- `SubProcess | SubProcess`是**同步**搬运（`f_io.pipe`），在调用线程里阻塞拷贝；大输出量时注意死锁风险。
- 默认`environment`是调用进程环境变量的副本，默认`workingDirectory`是当前工作目录。
