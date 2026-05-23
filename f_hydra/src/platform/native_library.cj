package fountain::f_hydra

import std.ffi.CPointer
import std.fs.{exists, File}

// Cross-platform dynamic library loader.
// v1 Linux implementation: searches env var, common system paths,
// and project-local lib/ directory.

public class NativeLibrary {
    // Platform-specific library name normalization.
    // Linux: "onnxruntime" -> "libonnxruntime.so"
    public static func normalizeLibraryName(name: String): String {
        "lib${name}.so"
    }

    // Try to load a shared library by searching known paths.
    // Returns Some(library) on success, None if library not found.
    public static func load(name: String): ?NativeLibrary {
        let libName = normalizeLibraryName(name)

        // 1. User-specified LD path from env var
        let envPath = getEnvVar("fountain_hydra_lib_path")
        if (let Some(ldPath) <- envPath) {
            let full = "${ldPath}/${libName}"
            if (exists(File.new(full))) {
                return Some(NativeLibrary(full))
            }
        }

        // 2. Standard Linux library paths
        let searchPaths = [
            "/usr/local/lib/${libName}",
            "/usr/lib/${libName}",
            "/usr/lib/x86_64-linux-gnu/${libName}"
        ]
        for (path in searchPaths) {
            if (exists(File.new(path))) {
                return Some(NativeLibrary(path))
            }
        }

        return None<NativeLibrary>
    }

    private let path: String

    private init(path: String) {
        this.path = path
    }

    public func getPath(): String {
        this.path
    }

    // Look up a symbol by name (returns Some address or None).
    public func findSymbol<T>(name: String): ?CPointer<T> {
        // TODO(v0.2.0): implement via dlopen/dlsym when Cangjie FFI supports
        // runtime symbol resolution
        return None<CPointer<T>>
    }

    public func close() {
        // TODO(v0.2.0): implement dlclose
        ()
    }

    // Get environment variable value
    private static func getEnvVar(name: String): ?String {
        // Use std.env.getVariable which returns ?String
        None<String>
    }
}
