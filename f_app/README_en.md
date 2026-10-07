# fountain::f_app API reference

> This document is compiled from the current source of the `f_app` module: the version follows `f_app/cjpm.toml` (currently `1.3.7`, kept in sync with `f_version/src/FountainVersion.cj`), and the output type is `dynamic`.
> Dependent packages: `f_base`, `f_concurrent`, `f_data`, `f_log`, `f_random`, `f_version`, plus `std.env` / `std.fs` / `std.process` / `std.regex` / `std.random` / `stdx.net.http` / `stdx.net.tls` (queried by `pub` for the artifact repository and for random strings).
> All types live in the single package `fountain::f_app` (there is no subpackage such as `f_app.SubCommand`).

## Contents

1. [Quick start](#1-quick-start)
2. [`App`: the application launcher](#2-app-the-application-launcher)
3. [Built-in subcommand reference](#3-built-in-subcommand-reference)
4. [Custom subcommands](#4-custom-subcommands)
5. [Application initialization](#5-application-initialization)
6. [`pub`: publishing modules in bulk](#6-pub-publishing-modules-in-bulk)
7. [Other public types](#7-other-public-types)
8. [Internal implementation](#8-internal-implementation)

---

## 1. Quick start

```cangjie
import fountain::f_app.*

main(args: Array<String>): Int64 {
    App(args, dynamic: true).boot()
}
```

That is exactly how the entry point of `fboot` itself (`fboot/src/main.cj`) is written.

## 2. `App`: the application launcher

```cangjie
public struct App {
    public App(
        private let args: Array<String>,                 // Command line arguments; args[0] is the subcommand name
        private let appHomeIsWorkingPath!: Bool = true,  // Not involved in any logic in the current source
        private let dynamic!: Bool = true,               // Whether to scan a directory and load the dynamic libraries in it (see section 4)
        private let name!: String = ''                   // Overrides the startup banner and the application name
    ) {}

    public func boot(): Int64                            // Dispatches on args[0]
    public static func start(args: Array<String>): Int64 // Equivalent to App(['run', ...args]).boot()
}
```

Dispatch rule: built-in subcommands are matched first (`run` / `shutdown` / `restart` / `module` / `workspace` / `cleanUpdate` / `build` / `test` / `count` / `version` / `help`); if none matches, the call goes to `SubCommandMediator.exec(args[0], args[1..])` (see section 4).

**Only `run` / `restart` / `test` and the "no command matched" path go through `load()`** (scan and load dynamic libraries →
`InitializerCollection.initialize()` → register the exit callback); `shutdown` / `version` / `help` / `count` / `build` and so on
neither scan nor initialize. `InitializerCollection.initialize()` is one-shot (it clears itself when it ends).

```cangjie
// Start the application with your own main function (the run subcommand is added automatically)
main(args: Array<String>): Int64 {
    App.start(args)
}
```

The arguments passed to `App.start(args)` look like `--dylibPattern='<dylib_name_regex_to_load>'` (that is, they are given from the point of view of the `run` subcommand).

Application name and banner:

* The application name is taken from the `name` argument; when it is not given, it is inferred from the load path (the result of `confirmTargetPath(args)`) —— if the path ends with `/target/release` the project directory name is used, if it ends with `/release` the name of the parent directory is used, otherwise the directory name of the path itself is used.
* At startup `run` prints `AppVersion.banner` + `'<application name>(<version>) started by <fountain version> in <elapsed time>'`; if a non-empty `banner.txt` exists in the current directory, the `build` stage takes it as the banner of `AppVersion` (see 3.6).

## 3. Built-in subcommand reference

| Subcommand | Form | Behavior |
| --- | --- | --- |
| `run` | `fboot run [PATH] --dylibPattern=<regex>` | Load the matching dynamic libraries under `PATH` (the current directory by default) → initialize all `Initializer`s → print the startup banner → `spawn` each `start()` in a new thread → **block forever** (`while(true){ sleep(Duration.Max) }`), so this command never returns |
| `shutdown` | `fboot shutdown <PID>` | `findProcess(pid).terminate()` and poll until the process exits; the `atExit` callbacks of the terminated process (the wrap-up logic registered by the modules) run as the process exits |
| `restart` | `fboot restart <PID> [PATH] --dylibPattern=<regex>` | `shutdown` first, then `run` |
| `module` | `fboot module [name]` | Run `cjpm init --type=dynamic` in the `name` directory (the current directory by default); if the target directory is the current directory or a direct subdirectory of it, the module name is added to the `members` of the `cjpm.toml` of the **parent directory** (that `cjpm.toml` must already exist); then `src/<module name>.cj` is written (content `package <module name>`) |
| `workspace` | `fboot workspace [dir]` | Run `cjpm init --workspace` in `dir` (the current directory by default) and rewrite its `cjpm.toml`: `[workspace] version = "1.0.0"` (a fixed value), the `f_base` / `f_version` dependencies take the version of the current fboot, the empty `compile-option` is replaced with `--dy-std -Woff all`, and the target and `path-option` configuration for each platform is filled in |
| `cleanUpdate` | `fboot cleanUpdate [PATH]` | Print the command, then run `cjpm clean --target-dir=<...>`, delete `cjpm.lock`, and run `cjpm update` |
| `build` | `fboot build [PATH] [args...]` | See 3.6 |
| `test` | `fboot test [PATH] [args...] --dylibPattern=<regex>` | Overlay `PATH/cjpm.toml` with `PATH/test/cjpm.toml`, `build` first and then start with `run`; when `--dylibPattern` is missing it throws `BootException("arg --dylibPattern='...' in command line is required")` |
| `count` | `fboot count [PATH] [--ext=cj] [--ignoreBrackets] [--ignoreComments]` | Count modules (`*.toml`), packages (directories whose path contains `/src/`), files and lines (by `--ext=cj` by default; pure bracket lines and comments can be ignored), and print the elapsed time |
| `version` | `fboot version [x.y.z] [msg] [tag [tagmsg]]` | See 3.7 (used to manage fountain itself) |
| `help` | `fboot help` | Print the help text (the descriptions of the built-in commands are hard-coded in `App.cj` and differ slightly from this section: it does not contain `test`, and the `module` entry says "the current directory" while it actually modifies the parent directory) |
| `pub` | `fboot pub <x.y.z> [--skip-lint] [--skip-test]` | A subcommand registered by `PublishCommand`, see section 6 |
| `randhex` | `fboot randhex <n>` | Registered by `RandHexCommand`: prints an `n`-digit random lower-case hexadecimal string (`RandomString().randomLowerHex(n)`) |

### 3.6 Details of `build`

* `[PATH]` must be the first argument after `build` and may only be the path itself; the current directory is the default.
* The remaining arguments fall into two kinds: the `--key=value` form is turned into an **environment variable** passed to the `cjpm build` child process (merged with the current process environment), and the other arguments are passed as command line arguments of `cjpm build` unchanged.
* Before building, a version module `<module name>_stAtIc__` is generated temporarily in the project directory (`.` and `-` in the module name are replaced with `_`): `src/<module name>_AppVersion.cj` is written with the content `AppVersion.set(<banner>, <name>, <version>)`, and the module is temporarily added to the `members` of the workspace; when the process exits (`atExit`) the original `cjpm.toml` is restored and the temporary module is deleted.
* What is finally executed is `cjpm build --target-dir=<targetDir> <other arguments>` (`targetDir` is derived from `PATH` and the working directory).

### 3.7 Details of `version`

Only used to manage fountain itself (requires password-less git access):

* `fboot version`: prints `FountainVersion` (the `f_version` module).
* `fboot version x.y.z [msg] [tag [tagmsg]]`: `git pull` → recursively rewrite the `version` of every `cjpm.toml` under the working directory to `x.y.z`, and update `cjc-version` to the version reported by `cjc -v` → if the working directory belongs to the `fountain` / `fboot` project, replace the `fountain(x.y.z)` and `release-x.y.z` in `f_version/src/FountainVersion.cj` → `git add .` → `git commit` (when `msg` is absent the message is `Some codes were changed, version: x.y.z`) → as soon as a `tag` argument is present, run `git tag -a release-x.y.z -m <commit message>` (an extra `tagmsg` is only concatenated as an additional line; the `tagmsg` given by the user is not actually used directly) → `git push` and `git push origin release-x.y.z`.
* When the version number does not match `x.y.z`, only a message is printed and nothing is executed.

## 4. Custom subcommands

```cangjie
package fountain::f_app

public interface SubCommand {
    /**
     * Subcommand name, i.e. fboot <subcommand>
     */
    prop command: String
    /**
     * Execution; args are the command line arguments after the subcommand name has been removed
     */
    func exec(args: Array<String>): Int64
}

public struct SubCommandMediator {
    /**
     * Register a subcommand (recommended in the static init() of the implementing type)
     */
    public static func register(command: SubCommand): Unit
    public static func exec(command: String, args: Array<String>): Int64
}
```

The execution path of `SubCommandMediator.exec`:

1. A registered command is hit → execute it directly;
2. No hit → call `load(args, true)`: scan the directory and load the matching dynamic libraries (the matching rule is in section 8); the `static init` of the libraries completes `SubCommandMediator.register`, and then it **retries** once;
3. Still no hit → throw `BootException`, whose message lists the built-in commands and the registered command names.

### Reference implementation

Compile the subcommand into a dynamic library, put the library in some directory, and then run the following in that directory:

```
fboot <subcommand name> [PATH] --dylibPattern='<dylib_name_regex_to_load>'
```

```cangjie
package org::module.pkg

import fountain::f_app.{SubCommand, SubCommandMediator}

public struct NewSubCommand <: SubCommand {
    static init() {
        SubCommandMediator.register(NewSubCommand())
    }
    public prop command: String {
        get() {
            'newcmd'
        }
    }
    public func exec(args: Array<String>): Int64 {
        // do something
        0
    }
}
```

When `dynamic` is `false` (`App(..., dynamic: false)`) no dynamic library scan takes place, and only the built-in commands and the subcommands statically linked into the process are available.

## 5. Application initialization

```cangjie
/**
 * Application initialization API. Application code usually does not need to implement this interface.
 */
public interface Initializer {
    /**
     * Name of the functionality to initialize
     * Some functionality can only be initialized by explicitly calling a function; fountain::f_bean, fountain::f_mvc,
     * fountain::f_orm and fountain::f_ticktock are all of this kind
     */
    prop name: String
    /**
     * Dependencies; the current functionality may only be initialized after these have been initialized
     */
    prop dependencies: Array<String> {
        get() {
            []
        }
    }
    /**
     * Call this function to complete the initialization
     */
    func initialize(): Unit
    /**
     * Return the start function. Whether calling the returned function blocks depends on the implementation; for
     * example, calling the start function of mvc starts the http service and blocks forever.
     * Therefore the start functions of different modules or functionalities must not depend on one another, otherwise
     * initialization could not complete successfully if two start implementations block.
     */
    func start(): Unit {}
}
```

```cangjie
public struct InitializerCollection {
    /**
     * Register the initialization function of a module. An application APP usually does not need to call it.
     */
    public static func register(initializer: Initializer): Unit
    // initialize() is a package-level function called by App during the loading stage; it returns all the collected start functions
}
```

Behavior:

* `register` is thread safe (an internal `Mutex`); registration records the "is depended on" relations of `dependencies`.
* Initialization order: as long as **some module in the `dependencies` of an `Initializer` has not finished initializing**, it is put back into the queue to wait, so the dependency chain is topologically sorted automatically; after `initialize()` completes, its `start()` is collected.
* The collected `start()` functions are `spawn`ed one by one onto new threads by `App.run()`, after which the main thread blocks forever; whether `start()` blocks is up to each module.
* The customary approach of other modules: define `<module name>Initializer <: Initializer` and call `InitializerCollection.register(...)` in `static init()` (for example the `BeanInitializer` of `f_bean`, the `MVCInitializer` of `f_mvc`, the `ORMInitializer` of `f_orm`). When the dynamic libraries are loaded during the `run` stage, these `static init()` functions run automatically to complete registration, and application code usually does not need to call them by hand.
* The `AppVersion` of the `f_version` module (carried by the `<module name>_stAtIc__` generated by `build`) provides the startup banner and the application version, part of the same "effective as soon as it is loaded" mechanism.

## 6. `pub`: publishing modules in bulk

```
fboot pub <x.y.z> [--skip-test] [--skip-lint]
```

* Implemented by `PublishCommand` (a `SubCommand` of `f_app` itself; since `fboot` depends on `f_app`, executing it requires no extra dynamic library).
* The first positional argument must be a version number of the form `x.y.z`, otherwise an exception is thrown; if the arguments immediately after it start with `--` (such as `--skip-test`, `--skip-lint`), they are passed to `cjpm bundle` unchanged (that is, `cjpm bundle --skip-test --skip-lint` is executed), otherwise only `cjpm bundle` is run.
* When publishing several modules in a row, a `.modules` file can be placed in the project root to select the scope:

```
[include]
# One module name per line,
# If the current directory is also a module to publish, use . to refer to it
# Lines starting with # are comments

[exclude]
# These are ignored modules; only one of [include] and [exclude] may be given

[detention]
# The modules here are not published but temporarily retained; unfinished module names can be put here so that,
# once they are finished later, you will not forget to add them to include or exclude
```

* `[include]` and `[exclude]` **must not be given at the same time** (otherwise an exception is thrown); you may also omit both (publish every module that is traversed). Empty lines and lines starting with `#` are ignored.
* Validation: the modules in `[include]` must exist in the module tree of the working directory; if a module to publish depends on a module of the same project that is **not part of the publishing scope**, an exception is thrown with a hint; a module depending on itself also throws.
* Publishing order: automatically sorted by the dependencies between modules —— as long as there is a depended-on module "in the same project and not yet published completely", the current module is put back into the queue to wait.
* Steps for each module:
  1. `checkPublished(..., once: true)` first probes whether that version already exists in the artifact repository and skips the actual publishing if it does (`https://pkg.cangjie-lang.cn/v1/artifact/getPackageMetadata?...`);
     note that a failed probe (response parsing error, empty body) is **swallowed and treated as "not published"**, retrying forever with backoff; `once=true` also does not make it return false because of a failure;
  2. Rewrite the `version` of its `cjpm.toml` to the publishing version and rewrite the same-project `path` / `git` dependencies into `"x.y.z"`,
     and only then back up the current content as `cjpm.toml.bak` (the backup is restored in `finally` when publishing ends ⇒ **the restored `version` is still the publishing version**);
  3. `cjpm clean` → delete `cjpm.lock` → `cjpm bundle ...` → `cjpm publish`;
  4. If the module is depended on by other modules, poll the repository with Fibonacci backoff until that version can be installed,
     after which `checkPublished` itself runs `cjpm install <organization>::<module>-<version>`;
  5. The success or failure of each step is judged by capturing fixed lines on the stdout of the child process (such as `cjpm clean success`), **not by the exit code**; a failure in any step prints the stack and retries the whole flow.
* At the end it prints `publish completed in <elapsed time>`.

## 7. Other public types

| Type | Description |
| --- | --- |
| `BootException <: Exception` | `init(message: String)`; used for unknown subcommands, a missing `--dylibPattern` in `test`, and similar cases |
| `ModuleInfo` | Module metadata for `pub`: `public var dependenced: Int64` (number of dependents), `public var organization: String = 'default'`, `public let dependencing = ArrayList<String>()` (list of depended-on modules) |
| `PublishCommand <: SubCommand` | The `pub` subcommand implementation, `command = 'pub'`, registered by `static init()` |
| `RandHexCommand <: SubCommand` | The `randhex` subcommand implementation, `command = 'randhex'`, registered by `static init()` |

## 8. Internal implementation

The following symbols are package-visible (internal) and are listed here to make troubleshooting easier:

| Symbol | Description |
| --- | --- |
| `internal func load(args: Array<String>, dynamic: Bool): (Path, ArrayList<() -> Unit>)` | Determine the target path (`confirmTargetPath`) → choose the extension by platform (Windows `.dll` / macOS `.dylib` / others `.so`; the library search path variable is not actually set) → when `dynamic` is true, recursively scan and `PackageInfo.load` the libraries whose file names match `^lib.*(<value of --dylibPattern>\|.+_stAtIc__).*$` → call `InitializerCollection.initialize()` → register `ExitCallbacks.toExitGracefully()`. Note that the extraction of `--dylibPattern` (`extractPattern`) is "take the next index after the first non-`--dylibPattern=` argument" and then slice ⇒ only the form "the regex immediately follows the first positional argument" works; omitting `PATH` or giving no positional argument causes an out-of-bounds index |
| `internal const APP_STATIC_RESOURCE_SUFFIX = '_stAtIc__'` | Fixed suffix of the version module; the `<module name>_stAtIc__` generated during the `build` stage is loaded together with the main library to carry `AppVersion` |
| `internal func confirmTargetPath(args: Array<String>): Path` | When `args[1]` does not start with `-` it is taken as the path (created if it does not exist), otherwise the current working directory is used; returns the normalized absolute path |
| `internal let log` | `LoggerFactory.getLogger<App>()` |

> Behavior not covered by this document follows `f_app/src/**/*.cj` (the previous topic-based excerpts under `f_app/doc/*.md` have been deleted; this README is the only source).
