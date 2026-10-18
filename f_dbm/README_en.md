# f_dbm

Extension **interface library** for the database middleware. fdbm is an executable
module, so third-party code cannot import its declarations; the extension contracts
live here instead. An extension only depends on this module (plus `f_app`'s
`Initializer`), is compiled into a dynamic library and dropped into fdbm's `custom/`
directory.

## Interfaces

```cangjie
package fountain::f_dbm

public interface PartitionAlgorithm {
    prop name: String                 // algorithm name used by fdbm_partition__<table>
    func partition<K>(key: K): String // returns the physical database name
}

public interface IdGenerator {
    prop name: String                 // value of fdbm_idmaker
    func nextStringId(): String       // throws IdGeneratorException by default
    func nextIntId(): Int64           // throws IdGeneratorException by default
}
```

- Partition algorithms are instantiated by fdbm at startup according to the table
  configuration (`PartitionAlgorithmFactory`). Built-ins (`step`, `hash`, `std`,
  `crc16`, `crc32`, `crc64`, `murmur`, `substr`) live inside `fdbm`.
- ID generators are used only when an INSERT lacks the partition-column value.
  `uuid` / `snowflake` ignore the table; `sequence` allocates per `(logical database,
  table)` from the single allocation database. Without a generator, a missing value
  yields `ROUTE_FAILED`.
- `IdGeneratorException` is the module's own exception type; implementations should
  throw it rather than a bare `Exception`.

## Writing a custom extension

```cangjie
package my.ext

import fountain::f_app.{Initializer, InitializerCollection}
import fountain::f_dbm.PartitionAlgorithm

class MyPartition <: PartitionAlgorithm & Initializer {
    static init() {
        InitializerCollection.register(MyPartition())   // must be registered in static init
    }
    private init() {}

    public prop name: String { get() { "myhash" } }

    public func partition<K>(key: K): String { /* ... */ }

    public func initialize(): Unit {
        // Only read Config and prepare local state: fdbm's resources, driver and
        // server do not exist yet at this point.
    }
}
```

Compile it into a dynamic library and place it in fdbm's `custom/` directory. Loading
rules (fdbm design §10.5):

1. fdbm loads **all** libraries in `custom/` first, then calls
   `InitializerCollection.initialize()` once, so every `static init` registration is
   visible.
2. Two pattern-matching passes collect `PartitionAlgorithm` and `IdGenerator`
   (one instance may satisfy both).
3. Duplicate names between custom extensions fail startup with `CONFIG` /
   `PARTITION_CONFIG`. A custom name that matches a built-in takes precedence: the
   algorithm/generator factories look up custom implementations first, so a custom
   extension can override a built-in one.
4. Any load failure or any `initialize()` exception fails startup with `CONFIG`.
5. A missing `custom/` directory means no extensions. Only extension libraries should
   be placed there (every registered `Initializer` is executed).

Extension libraries must share the loader path with `f_dbm` / `f_app` (usually the fdbm
deployment directory).
