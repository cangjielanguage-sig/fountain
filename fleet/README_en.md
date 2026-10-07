## Server
The top-level declarations of the server are all internal and no API is exposed.

### Configuration
```bash
export fleet_port=2350 # Port the fleet server listens on; 2350 is the default. It can also be set with the command line argument --fleet_port=2350
export fleet_storePath=/tmp/fleet # Storage directory of the fleet server; the default is fleet/store under the directory where fleet resides
export fleet_bufferQueueSize=1024 # Data buffer queue size, 1024 by default
export fleet_connectionCheckDuration=1000 # Connection health check period, 1000ms by default
export fleet_hosts=ip1:port1,ip2:port2..... # IPs and ports the fleet server connects to; separate multiple IPs with commas
```
### Deployment
```bash
cjpm install fountain::fboot-<a.b.c> # Use the same version as fleet
cjpm install fountain::fleet-<a.b.c> # Go to the installation path, find the downloaded package, copy it to the target path and then run the following
cp /path/of/fleet/installed /path/of/fleet/copied
cd /path/of/fleet/copied
cjpm build 
```
You may also download the source code from git
```bash
git clone https://gitcode.com/Cangjie-SIG/fountain.git
git checkout -b release-<a.b.c> # Replace <a.b.c> with the latest version
cd /path/of/fountain/cloned
cd fboot
cjpm intall --root /path/of/fboot/installed
cd ../fleet
cjpm build
```

### Startup
```bash
cd /path/of/fleet/compiled-or-installed
fboot fleet --dylibPattern='fountain|f_.*|fleet'
```


## Client
The only client configuration is `fleet_hosts` (the same-named constant is `FleetConfig.FLEET_SERVER_HOSTS`).

```cj
public struct FleetConfig {
    public static const FLEET_SERVER_HOSTS = 'fleet_hosts'
    /**List of fleet server addresses the client connects to, separated by commas*/
    public static prop hosts: Array<String>
}
```

The client does shard routing by `path` (`clients[path.hashCode() % clients.size]`) rather than load balancing: the same `path` always lands on the same server. Therefore **changing the order of `fleet_hosts` changes the mapping from path to server**, and the ownership of existing data must be evaluated when scaling in or out.

`FleetClientException <: BaseException` is the client failure signal; `fleet.base` also provides two constants: `ERROR_HOST_FOR_PATH = 'ErrorHost'`, `UNSUPPORTED_COMMAND = 'UnsupportedCommand'`.

### API
```cj
public struct Fleet {
    public static func get<T>(path: String): ?T where T <: DataFields<T>
    public static func set<T>(path: String, data: T, expireAt: ?DateTime): Unit where T <: DataFields<T>
    public static func set<T>(path: String, data: T): Unit where T <: DataFields<T>
    public static func set<T>(path: String, data: T, expire!: Duration = Duration.Zero): Unit where T <: DataFields<T>
    /**
     * Delete the data at the given path
     */
    public static func remove(path: String): Unit
    /**
     * After calling this function, when the data corresponding to path changes on the server, the server sends
     * the changed data back to the listening client
     */
    public static func listen(path: String, executor: (Message) -> Unit): ListeningFleet
}
// Only isClosed() and close() are exposed; closing cancels the listening
public struct ListeningFleet <: Resource
```
