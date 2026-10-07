# f_cmd

Parses `env.getCommandLine()` and provides global-singleton-style command line argument queries.

```cj
public class CmdArgs {
    // Get the CmdArgs instance (the command line is snapshotted on first access)
    public static let instance: CmdArgs
    //Get the command line arguments starting with prefix
    public func getAllKeys(prefix: String): Array<String> 
    //Check whether the specified command line argument exists
    public func contains(name: String): Bool 
    //Get the list of values of the command line argument with the given name
    public func getArgs(name: String): Option<ArrayList<String>> 
    // Get the value of the command line argument with the given name
    public func getArg(name: String): Option<String> 
    //Get the process name
    public func getAppName(): String 
    //Get the path where the process file is located
    public prop commandPath: Path
    //Get the current working directory
    public prop currentWorkingDirectory: Path 
    //Get the value of the command line argument with the given name
    public func getArgValue<T>(name: String): Option<T> where T <: Parsable<T> 
}
```

Exception: `fountain::f_cmd.exception.CmdException`.

## Parsing rules

| Command line form | Key | Value |
|---|---|---|
| `--k=v` | `k` (with `--` removed) | `v`; appended to the list when repeated with the same name |
| `--flag` | `flag` (with `--` removed) | Empty list; not reset if it already exists |
| `-x` | `-x` (**keeps** the `-`) | Empty list; reset to empty when it appears again |
| Positional argument | Key of the nearest `-x`/`--x` | Appended to that key's value list |

Therefore `--db.host=127.0.0.1` must be queried with `getArg('db.host')`, while `-p 8080` must be queried with `getArgs('-p')`.

## Usage example

```cj
import fountain::f_cmd.CmdArgs
// Command line: myapp --db.host=127.0.0.1 --db.port=5432 --verbose -p 8080 a.txt
let args = CmdArgs.instance
let host = args.getArg('db.host')              // Some("127.0.0.1")
let port = args.getArgValue<Int64>('db.port')  // Some(5432)
let on = args.contains('verbose')              // true
let keys = args.getAllKeys(prefix: 'db')       // ["db.host", "db.port"], order not guaranteed
let pl = args.getArgs('-p')                    // Some(["8080", "a.txt"])
```

## Notes

- `instance` is a lazily initialized static singleton: the command line is snapshotted on the **first access to `CmdArgs`**, and `currentWorkingDirectory` is cached at that same moment only (a later `cd` has no effect); `commandPath`, by contrast, is computed on every access.
- The order of the result of `getAllKeys` comes from `HashMap.keys()` and is not guaranteed to be the command line order.
- The `--` terminator is not supported, nor are combined short options (`-abc` is treated as the single key `-abc`).
- A positional argument must follow some `-x`/`--x`; a positional argument appearing before any option has no owning key and must not be relied on.
