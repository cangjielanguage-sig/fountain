# f_net

`fountain::f_net` is the TCP transport layer of fountain: it puts the `Message` frame reading and writing of `f_protocol` onto connections and manages
the connection lifecycle (heartbeat inspection, failure counting, rate limiting, close ordering). To the layer above (the `RPCClient` of `f_rpc`) it offers
the multi-node client pool `MultiClient`.

## Package names

| Package | Contents |
| --- | --- |
| `fountain::f_net` | `MessageFuture`, `SocketBuffer`, `SocketParams` (internal, used only indirectly through builders) |
| `fountain::f_net.client` | `Client` / `ClientBuilder`, `MultiClient` / `MultiClientBuilder`, `ListeningClient`, `ClientException` |
| `fountain::f_net.server` | `Server` / `ServerBuilder` |

## Basic types

### `MessageFuture<DE>`

```cj
/**
 * Get the decoded data; the public functions of this type are concurrency safe
 */
public class MessageFuture<DE> {
    /** Blocks until there is data, i.e. until the reading thread decodes a result and wakes this thread */
    public func get(): DE
    /** Returns None<DE> immediately when there is no data */
    public func tryGet(): ?DE
    /** Blocks up to timeout when there is no data, and returns immediately after the timeout (data arriving before the timeout wakes it) */
    public func tryGet(timeout: Duration): ?DE
}
```

`MessageFuture` holds the **raw `Message`** (`MessageFuture<Message>`), and the caller must convert the payload itself with `convert<T>(msg.data)`.
The `set()` used to fill in the result is not public; only the reading thread in the same package calls it.

### `SocketBuffer <: IOStream & Resource`

```cj
/**
 * Frame buffer on one connection
 */
public class SocketBuffer <: IOStream & Resource {
    /** Encode message and write it to the socket (mutual exclusion of whole-frame writes, see close()) */
    public func transfer(message: Message): Unit
    public func read(bytes: Array<Byte>): Int64     // Used to read a full frame; see f_protocol.Message.decode
    public func write(bytes: Array<Byte>): Unit
    public func flush(): Unit
    public func isClosed(): Bool
    /** First wait for the frame being written to leave (up to 2s), then close the socket: the peer sees "a complete frame + EOF", not half a frame */
    public func close(): Unit
    public prop localAddress: SocketAddress
    public prop remoteAddress: SocketAddress
}
```

The constructor is not public: `SocketBuffer` is created internally by `Client` / `Server` (one per TCP connection).

## Client

### `Client<T>`

```cj
public class Client<T> where T <: DataFields<T> {
    /** 4 builder overloads: host!+port! / address!:(String,UInt16) / address!:String / address!:IPSocketAddress */
    public static func builder(queueSize!: Int64 = 1024, socketCount!: Int64 = 1, address!: String,
        checkDuration!: Duration, checker!: () -> ?Message): ClientBuilder<T>
    /** The message carries its own id (Message.id); returns the raw response Message */
    public func transfer(message: Message): MessageFuture<Message>
    /** Timeout version waiting for a response; returns None on timeout or when the client is already closed */
    public func transfer(message: Message, timeout: Duration): ?Message
    /** Subscription/push style receiving: executor receives the response stream after that Message */
    public func transfer<T>(message: Message, executor: (Message) -> Unit): ListeningClient<T> where T <: DataFields<T>
    public prop address: IPSocketAddress
    public func isClosed(): Bool
    /** Idempotent: cancels the inspection timer + closes all connection buffers */
    public func close(): Unit
}
```

Common settings of `ClientBuilder<T>` (`build(): Client<T>`): `bindToDevice` / `keepAlive` / `linger` / `noDelay` /
`quickAcknowledge` / `readTimeout` / `receiveBufferSize` / `sendBufferSize` / `writeTimeout` /
`socketOption(level, option, value, valueLength)` / `socketOptionBool` / `socketOptionIntNative` /
`pingTimeout` (**1s by default**; too short a value causes a storm of disconnects and reconnects).

Behavior highlights:

- **The read loop decodes neutrally with `Message.decode<DataAny>`**: non-PING messages are handed to `MessageFuture` as they are, and polymorphic payloads are converted by the caller with `convert<T>`;
- **Heartbeat tolerance**: a connection is only torn down and rebuilt after `CHECK_FAILURE_TOLERANCE = 3` consecutive failed checks; one successful check requires
  `res.id == m.id && Command.ACK`;
- `Client` closes itself once all buffers are closed; `transfer` throws `Exception('Client is closed')` when already closed;
- A failed build throws `ClientException`.

### `MultiClient<W, T>`: multi-node client pool

```cj
public class MultiClient<W, T> <: Resource & Iterable<Client<T>> {
    public static func builder(queueSize!: Int64 = 1024, socketCount!: Int64 = 1,
        checkDuration!: Duration, checker!: () -> ?Message): MultiClientBuilder<W, T>
}

public class MultiClientBuilder<W, T> where W <: Addable<W> & Comparable<W>, T <: DataFields<T> {
    /** Round robin: step is the step size, min/max are the value range of the algorithm, origin is the starting point of the accumulated weight keys (default = min, for backward compatibility) */
    public func roundRobin(step: W, min: W, max: W, origin!: ?W = None): This
    /** Random: pick a value on [min, max) by weight */
    public func random(min: W, max: W): This
    /** Add a node: weight is the weight of that node; the address may be given as String / (host, port) / IPSocketAddress, or an Iterable may be passed */
    public func add(weight: W, address: String): This
    public func build(): MultiClient<W, T>
}
```

- `W` only supports `Int64` / `Float64` (other types throw `LoadBalanceException`);
- **Iteration semantics**: `MultiClient` is an `Iterable<Client<T>>`; `for(client in multiClient)` yields clients in load-balancing order,
  and **the first element is the node selected this time while the following elements are the retry nodes** (the `RPCClient` of `f_rpc` relies on this semantics);
- **Weight semantics (accumulated weight buckets)**: the internal TreeMap uses the accumulated weight of each node as its key (`origin + w₁ + … + wᵢ`),
  and picking a node = the first key ≥ the value produced by the algorithm, so node i covers `(K_{i-1}, K_i]`. Therefore for weighted scenarios pass
  `origin = 0`, put `min` **inside** the first bucket (for example `step / 2`), and `max = Σw`;
  if `origin` and `min` are the same, the value sequence aligns with the bucket boundaries and **the first node is always hit** (see `.autocode/bugs/bug-archived-20261004-2.md`).

### `ListeningClient<T>`

The return value of `transfer<T>(message, executor)`: it keeps feeding the responses after a given message to `executor`; `close()` is idempotent.

## Server

```cj
public class Server<T> where T <: DataFields<T> {
    public init(bufferQueueSize!: Int64 = 1024, bindAt!: UInt16, checkDuration!: Duration, executors!: Int64 = 200,
                unavailableChecked!: Int64 = 3,
                defaultResp!: (MessageID) -> ?Message = {_=> None},
                limiter!: RateLimiter<Unit> = UnlimitedRateLimiter<Unit>(),
                checker!: () -> ?Message)
    public static func builder(bufferQueueSize!: Int64 = 1024, checkDuration!: Duration,
        checker!: () -> ?Message, bindAt!: UInt16): ServerBuilder<T>
    /** Blocking accept loop: the caller spawns it itself */
    public func start(executor: (SocketBuffer, Message) -> ?Message): Unit
    public func isClosed(): Bool
    public func close(): Unit
}
```

The per-connection loop of `start()`:

1. `Message.decode<T>(buffer)` decodes one frame; reading EOF (the peer closed cleanly) logs `tcp closed` at DEBUG and drops the connection, while
   a decoding failure (displaced byte stream) logs the WARN `error occurred on decoding` and **must** drop the connection;
2. **PING is answered with an ACK by `Server` itself**, and a heartbeat ACK (the id recorded in `checkerId`) is also recognized here; neither reaches the executor;
3. Business messages go through `executors.call(limiter){executor(buffer, req)}`: the executor receives **the buffer + the already decoded Message**,
   and when it returns `None` the `defaultResp(req.id)` fallback is used; if that is still `None`, no response is sent;
4. Connection unavailability: once the ping count of a connection exceeds `unavailableChecked` (3 by default), the connection is judged unavailable and closed.

Rate limiting applies only to step 3 (the executor path); PING/ACK are not limited. The arguments of `ServerBuilder` fall into two layers:

- Without a prefix (`bindToDevice` / `receiveBufferSize` / `sendBufferSize` / `reuseAddress` / `backlogSize` /
  `socketOption*`) they apply to the **listening socket**;
- With the `socket*` prefix (`socketNoDelay` / `socketLinger` / `socketKeepalive` etc., through `SocketParams`) they apply to
  **every connection after accept**;
- Others: `executors(n)`, `defaultResponse(fn)`, and four rate limiter constructors (`anyMomentRateLimiter` /
  `leakingBucketRateLimiter` / `slidingWindowRateLimiter` / `tokenBucketRateLimiter`).

## Related documents

- `doc/审查报告.md`: a static review snapshot from 2026-05-03 (file and case counts of that time, no longer matching the present, kept for historical reference only);
- The API excerpts formerly under `doc/` (basic types / client / server) have been deleted; **this README and the source code are authoritative**.

---

## Other public API

The declarations below are not expanded above; they are grouped by module level and by type (members declared in `extend` blocks are listed under the extended type). See the corresponding files under `src/` for the full semantics.

- `MultiClient`: `func iterator(): Iterator<Client<T>>`
- `ServerBuilder`: `func setSocketOptionBool(level: Int32, option: Int32, value: Bool): This`, `func setSocketOptionIntNative(level: Int32, option: Int32, value: IntNative): This`, `socketBindToDevice` (func), `func socketQuickAcknowledge(quickAcknowledge: Bool): This`, `func socketReadTimeout(readTimeout: ?Duration): This`, `func socketReceiveBufferSize(receiveBufferSize: Int64): This`, `func socketSendBufferSize(sendBufferSize: Int64): This`, `func socketWriteTimeout(writeTimeout: ?Duration): This`
