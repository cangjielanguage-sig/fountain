# frpcdemo: usage example of `fountain::f_rpc`

Three packages demonstrate the complete RPC path: **service interface and data model** (`rpcdef`), **server** (`rpcserver`), and **caller** (`rpcclient`).
Every time the server handles an `echo` it prints the JSON it received, and the client calls `echo` 100 times in a row —— so how many times each
service node was actually served can be read off directly by counting the lines starting with `{` in the server output (one line per request);
that is how multi-node load balancing (round robin + weights) is verified.

## Contents

| Path | Description |
| --- | --- |
| `rpcdef/src/EchoRPC.cj` | `@RPCStub` interface: `func echo(po: EchoPO): EchoPO` (macro expansion generates `EchoRPC_Stub__`) |
| `rpcdef/src/model/EchoPO.cj` | `@DataAssist` data model; contains the nested type `InnerPO`, used to verify the coding/decoding of nested objects |
| `rpcserver/src/rpc/impl/EchoPOImpl.cj` | `@RPCSkeleton` service implementation (prints the received JSON and returns it unchanged) |
| `rpcclient/src/client.cj` | Calls `echo` 100 times inside `Initializer.start()`, then prints the number of successes and the JSON of the last response |
| `boot.sh` | Entry point for starting processes/building (all commands below use it) |
| `log/` | File logs of a run (`frpcdemoserver-<host:port>.log`, `frpcdemoclient.log`) |

## 0. Build

```bash
cd frpcdemo
./boot.sh build          # Compile this project and its dependencies (required the first time or after changing fountain library code; takes a while)
```

`./boot.sh build` compiles the dependencies (`f_app`, `f_rpc`, `f_data`…) together into `target/`, and writes the dynamic library
directories of the modules into `LD_LIBRARY_PATH`; `./boot.sh runServer|runClient` then use `--dylibPattern` to pick out the dynamic library
of the package to load.

## 1. Start the server

```bash
./boot.sh runServer <host:port> [seed node|-] [weight]
```

- The weight defaults to `1.0`; writing `-` (or omitting it) for the seed node means there is no seed.
- Examples:

```bash
# Seed node (also serves requests): listens on 127.0.0.1:1203, weight 2.0
./boot.sh runServer 127.0.0.1:1203 - 2.0

# Pure service node: listens on 127.0.0.1:1204, registers itself with 127.0.0.1:1203, weight 1.0
./boot.sh runServer 127.0.0.1:1204 127.0.0.1:1203 1.0

# Two mutually independent service nodes, both with weight 1.0 (the client connects to both)
./boot.sh runServer 127.0.0.1:1203
./boot.sh runServer 127.0.0.1:1204
```

After startup the process prints the configuration that actually took effect, for verification:

```
rpcServer_port=1204 rpcServer_baseAddresses=127.0.0.1:1203,127.0.0.1:1204 rpcServer_weight=1.0
```

Two things you must know:

1. **`rpcServer_port` only accepts a port number (`UInt16`)**. `boot.sh` splits the port out of "host:port" automatically;
   if you hand `127.0.0.1:1204` to it directly, the parse fails and it **silently falls back to the default port 1203**, so two service nodes collide on the port.
2. **The registration targets include the node itself** (`baseAddresses` = explicit seeds + itself). The weight propagates through the registry: the client reads weights from
   the `host,weight` returned by `SUBSCRIBE(data:true)`, and a node not found in the registry can only fall back to the weight configured on the client (1.0)
   —— so a service node must be able to report itself into the registry for its own weight to take effect.

On every `echo` request, the server prints:

```
===========================
{"a":100,"b":"hello world","c":false,"d":2.71828,"inner":{"tag":"inner-default","count":7}}
===========================
```

To exit: `Ctrl-C`.

## 2. Start the client

```bash
./boot.sh runClient <host:port>[,<host:port>...]
```

- Separate multiple service nodes with **commas**; `boot.sh` converts them into the `weight,address|weight,address` form required by
  `rpcClient_serverAddress` (weight 1.0 for every address) and forces `rpcClient_loadbalance=roundrobin` (round robin).
- Examples:

```bash
./boot.sh runClient 127.0.0.1:1203                        # Connect to a single node
./boot.sh runClient 127.0.0.1:1203,127.0.0.1:1204         # Connect to two nodes at once
```

After startup it prints the configuration, then calls `echo` **100 times** in a row (a single failure is only logged and the next call continues), and finally prints:

```
rpcClient_serverAddress=1.0,127.0.0.1:1203|1.0,127.0.0.1:1204 rpcClient_loadbalance=roundrobin
***************************
echo calls finished: 100/100 succeeded
{"a":100,"b":"hello world","c":false,"d":2.71828,"inner":{"tag":"inner-default","count":7}}
***************************
```

Note: start the server before the client. Service discovery is asynchronous, so the first call of the client may have to wait one round (the upper bound is
`rpcClient_discoveryTimeout`, 5s by default); if there is no available service node during that time it reports `no available client ...` and exits.

To exit: `Ctrl-C`.

## 3. Complete verification procedure (load balancing)

Three terminals, executed in order (the table shows measured results from 2026-10-04, 100 calls per scenario):

| Scenario | Terminal 1 | Terminal 2 | Terminal 3 (client) | Measured 1203 : 1204 |
| --- | --- | --- | --- | --- |
| 1. Equal-weight round robin | `./boot.sh runServer 127.0.0.1:1203` | `./boot.sh runServer 127.0.0.1:1204` | `./boot.sh runClient 127.0.0.1:1203,127.0.0.1:1204` | **50 : 50** |
| 2. Weight 2:1 | `./boot.sh runServer 127.0.0.1:1203 - 2.0` | `./boot.sh runServer 127.0.0.1:1204 - 1.0` | Same as above | **67 : 33** |
| 3. Seed + pure service node | `./boot.sh runServer 127.0.0.1:1203 - 2.0` | `./boot.sh runServer 127.0.0.1:1204 127.0.0.1:1203 1.0` | `./boot.sh runClient 127.0.0.1:1203` | **67 : 33** |

- Scenario 2: after changing the weight you must **restart the server** (the weight is read at startup); the client can simply be run again.
- The path of scenario 3: the client only knows the seed node ⇒ it gets all service nodes from the seed via `SUBSCRIBE(data:true)` ⇒ subscribes to each and builds a call pool
  ⇒ the weights come from the registry ⇒ neither the client code nor its configuration has to change, and the two nodes share the load 2:1.
- How to count: after redirecting each server's output to a file,

```bash
grep -c '^{' server-1203.out      # How many times this node was actually served
```

(The client also prints the response JSON, so do not mix client output with server output when counting.)

## 4. Configuration quick reference

The main server- and client-related configuration (all settable through environment variables; see `../f_rpc/README.md` for the complete list):

| Configuration | Default | Description |
| --- | --- | --- |
| `rpcServer_port` | `1203` | Service listening port (`UInt16`, port number only) |
| `rpcServer_baseAddresses` | Empty | List of seed node addresses (comma separated); the node registers itself with them after startup |
| `rpcServer_weight` | `1.0` | Service weight, registered in the registry; the client distributes calls accordingly |
| `rpcClient_serverAddress` | None | Service nodes to connect to, in the form `weight,address`, several separated by `\|` (if unset, an ERROR is printed and the process exits) |
| `rpcClient_loadbalance` | `random` | Load balancing strategy: `random` / `roundrobin` (this demo uses round robin) |
| `rpcClient_retryCount` | `0` | Number of retries after a single call fails |

## 5. Observing and troubleshooting

- **Logs**: the console is at DEBUG level (see the `logger_appender_*` at the top of `boot.sh` for the format); file logs are under `./log/` at INFO level.
- **Composition of the call pool**: for every service, service discovery prints
  `[FOUNTAIN_RPC.hosts] fountain::rpcdef.EchoRPC.echo v=* -> 2 host(s): 127.0.0.1:1203(1.000000) 127.0.0.1:1204(1.000000)`
  —— "who exactly is in the pool, and with which weight" is most directly answered by this line.
- **Registration**: at startup the server prints `[FOUNTAIN_RPC.register] base addresses ...` / `host registered ...`,
  and the registry side prints `[FOUNTAIN_RPC.Skeleton.REGISTER] "127.0.0.1:1204,1.000000"`.
- **Common symptoms**:
  - `no available client for ... after 5s`: the server is not up, or the address configured on the client is wrong, or the service name/version does not match;
  - All calls land on the same node: check that both nodes reported their weights into the registry (see the `hosts` log above);
  - The server reports `Connection reset by peer`: most likely a broken link caused by the client process exiting abnormally; look at the exception on the client side.

Load balancing (round robin/weights) once did not work at all (the first node was always hit); the root cause and the fix are recorded in
part 2 of `../.autocode/bugs/bug-archived-20261004-2.md`.
