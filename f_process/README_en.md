# f_process

## STDX dependency

Configure the environment variable: `export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

This module adds process extensions to `String` and `std.process.SubProcess`: starting a child process directly from a command line string, chaining child processes into a pipeline with `|`, connecting child processes to any `InputStream`/`OutputStream`, plus standard stream readers/writers and the executable path of the current process.

**This module does not go through a shell**: `exec` only splits arguments on spaces, and `piped` only splits the command string on literal `|`, so there are no quotes, escapes or wildcard expansion.

## String extension

`ExtendProcess` / `ExtendSubProcess` are the extension interfaces declared by this module (`public interface`, see `src/process.cj`): the former declares the command-line methods and pipe operators added to `String`, the latter declares the pipe operators added to `SubProcess`; the `extend String <: ExtendProcess` / `extend SubProcess <: ExtendSubProcess` blocks below are their implementations inside this module.

```cj
extend String <: ExtendProcess {
    /**Split the command line on spaces and start a child process; stdIn/stdOut default to Pipe and stdErr to Inherit*/
    public func exec(workingDirectory!: ?Path = getWorkingDirectory(),
        environment!: ?Map<String, String> = enviromentVariables, stdIn!: ProcessRedirect = Pipe,
        stdOut!: ProcessRedirect = Pipe, stdErr!: ProcessRedirect = Inherit): SubProcess
    /**Connect the child process to the given InputStream/OutputStream; internally an asyncPipe coroutine moves data; returns Unit*/
    public func piped(workingDirectory!: ?Path = getWorkingDirectory(),
        environment!: ?Map<String, String> = enviromentVariables, stdIn!: InputStream, stdOut!: OutputStream,
        bufSize!: Int64 = 4096, stdErr!: ProcessRedirect = Inherit): Unit
    /**Takes over stdOut only*/
    public func piped(workingDirectory!: ?Path = getWorkingDirectory(),
        environment!: ?Map<String, String> = enviromentVariables, stdOut!: OutputStream, bufSize!: Int64 = 4096,
        stdIn!: ProcessRedirect = Pipe, stdErr!: ProcessRedirect = Inherit): SubProcess
    /**Takes over stdIn only*/
    public func piped(workingDirectory!: ?Path = getWorkingDirectory(),
        environment!: ?Map<String, String> = enviromentVariables, stdIn!: InputStream, bufSize!: Int64 = 4096,
        stdOut!: ProcessRedirect = Pipe, stdErr!: ProcessRedirect = Inherit): SubProcess
    /**Split the command string on the literal `|`, start each segment and connect them with pipes; returns (first child process, last child process)*/
    public func piped(workingDirectory!: ?Path = getWorkingDirectory(),
        environment!: ?Map<String, String> = enviromentVariables, stdIn!: ProcessRedirect = Pipe,
        stdOut!: ProcessRedirect = Pipe, stdErr!: ProcessRedirect = Inherit): (?SubProcess, ?SubProcess)
    /**Equivalent to this.exec() | next*/
    public operator func |(next: SubProcess): SubProcess
    /**Equivalent to this.exec() | next.exec()*/
    public operator func |(next: String): SubProcess
}
```

## SubProcess extension

```cj
extend SubProcess <: ExtendSubProcess {
    /**Synchronously move the stdOutPipe of this into the stdInPipe of next, and return next*/
    public operator func |(next: SubProcess): SubProcess
    public operator func |(next: String): SubProcess
}
```

## Current process

```cj
/**Text reader for the standard input of the current process, UTF8 by default*/
public func stdReader(charset!: Charset = Charsets.UTF8): TextReader
/**Text writer for the standard output/standard error of the current process, UTF8 by default*/
public func stdOutWriter(charset!: Charset = Charsets.UTF8): TextWriter
public func stdErrWriter(charset!: Charset = Charsets.UTF8): TextWriter
/**Absolute path of the current executable file, and its parent directory*/
public func getAbsoluteCommand(): Path
public func getAbsoluteCommandDir(): Path
```

## Usage example

```cj
import fountain::f_process.*

main() {
    //String pipeline: equivalent to ls -l | grep .cj
    let p = 'ls -l' | 'grep .cj'
    p.wait()

    //Connect the output of a child process to any OutputStream
    let w = stdOutWriter()
    'git status --short'.piped(stdOut: w, bufSize: 8192)
    w.flush()

    //Get the first and last child processes at once
    let (first, last) = 'cat a.txt | wc -l'.piped()
    last.getOrThrow().wait()
}
```

## Notes

- `exec` splits arguments with `split(' ', removeEmpty: true)`, so arguments containing spaces cannot be expressed; use `launch` and pass the arguments yourself when needed.
- The `piped` overloads that return `Unit` drop both `SubProcess` handles (the child processes can then only be ended by closing the peer stream); when you need `wait`/`kill`, use the overloads that return `SubProcess`.
- `SubProcess | SubProcess` moves data **synchronously** (`f_io.pipe`) and copies in the calling thread; beware of deadlock risk with large output volumes.
- The default `environment` is a copy of the environment variables of the calling process, and the default `workingDirectory` is the current working directory.
