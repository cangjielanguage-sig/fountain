# Simplest usage
```cj
let observable = Observable<Int64>
.iterable([1,2,3])
.subscribe('test', FuncObserver<Int64>().setNext{v => println(v)})
.withCurrent()
.defer()

observable.pause()//Pause the generation of new data
// The internal variable disposed_ is checked before every attempt to get the next piece of data; when disposed_ is false the stream ends immediately. dispose() sets disposed_ to true.
// The type of disposed_ is AtomicBool
```
# Initialization styles
1. iterable
    1. Takes an `Iterable<T>` instance
    2. Takes a `()->Iterable<T>` instance
    3. Takes a `()->Future<Iterable<T>>` instance
    4. Takes a `Future<Iterable<T>>` instance
    5. Takes a `()->Future<Iterable<T>>` instance
2. emitter
    Takes a `(Emitter<T>) -> Unit` instance
    - `Emitter<T>`
      - onNext(T)
        Emit one piece of data
      - onComplete()
        Emit the completion event
      - onError(Exception)
        Emit an exception
3. single
    1. Takes a `T` instance
    2. Takes a `()->T` instance
    3. Takes a `Future<T>` instance
    4. Takes a `()->Future<T>` instance
4. maybe
    1. Takes a `?T` instance
    2. Takes a `()->?T` instance
    3. Takes a `Future<?T>` instance
    4. Takes a `()->Future<?T>` instance
5. empty
    Creates an empty observable
6. concat
    1. Takes an `Iterable<Iterable<T>>` instance and flattens it into an `Iterator<T>`
    2. Takes a `()->Iterable<Iterable<T>>` instance and flattens it into an `Iterator<T>`
    3. Takes a `Future<Iterable<Iterable<T>>` instance and flattens it into an `Iterator<T>`
    4. Takes a `()->Future<Iterable<Iterable<T>>>` instance and flattens it into an `Iterator<T>`

# Registering observers
  - `subscribe(Observer<T>)`
    - May be called several times to register several observers
    - The `asyncCombined` argument given at initialization decides whether the observers run in parallel
    - Uses the fully qualified name of the observer type as the name
  - There are several overloads, and a name can also be given to the observer
# Unregistering observers
  - `dispose(completion)`
    Ends the stream forcibly; no new data is produced. The argument decides whether a completion message is sent
  - `dispose(name)`
    Unregisters the observer with the given name
  - `dispose<O>()`
    Unregisters all observers of the given type
  - `dispose<O>(name, O) where O <: Object & Observer<T>`
    Unregisters by name and observer instance; an exception is thrown if the registered observer is not the same instance as the argument
  - `dispose<O>(observer: O): Unit where O <: Object & Observer<T>`
    Unregisters the observer of the given instance; an exception is thrown if the registered observer is not the same instance as the argument
  - `disposeAll()`
    Unregisters all observers
  - `pause(completion!: Bool = false)`
    Pauses the generation of new data; completion decides whether a completion event is sent
  - When there are no observers left, the generation of new data is paused until a new observer is registered and the start function is called again

## Multiple observers

    Each of the initialization functions above accepts the named argument `asyncCombined!: Bool`, which decides whether the multiple observers get their own threads or all share one thread

# Processing policy for each piece of data
 1. `withAlwaysNew()`
    Always process each piece of data on a new thread
 2. `withCurrent()`
    Always process each piece of data on the current thread
 3. `withSingle(...)`
    Initialize the data processing policy with the given backpressure policy and data queue length, and always use the same thread to process all data
 4. `withFixed(...)`
    Initialize the data processing policy with the given backpressure policy, data queue length and thread count, and always use these threads to process all data
# Start
  1. `delay(Duration)`
     Start after a delay of Duration
  2. `defer()`
     Start on a new thread with 0 delay
  3. `immediately()`
     Start immediately on the current thread
# Stop
  - `dispose(completion!: Bool = false)`
    Stop the current observable; if the argument is true, an onComplete() event is sent
# Backpressure policy
    Only the single-thread and fixed-thread-count processing policies support backpressure policies; when the data queue is full at the moment new data is produced, the backpressure policy is triggered

## BackPressure

 1.  `Discarding`
     Discard the new data
 2.  `ToDropOldest`
     Drop the data at the head of the queue
 3.  `AlwaysBlocking`
     Block forever
 7.  `Throwing`
     Throw an exception immediately if the queue is full
 8.  `CurrentThread`
     If the queue is full, process the current data immediately on the current thread
 9.  `NewThread`
     If the queue is full, process the current data immediately on a new thread
10. `Action((()->Unit) -> Unit)`
     If the queue is full, process the current data with the given function
11. `AfterBlocking(Duration, BackPressure<T>)`
     Block for the given duration and, if the queue is still full, apply the given policy; the default policy is Discarding

# `Observer<T>`
  - `onNext(T)`
    Receive one piece of data
  - `onComplete()`
    Receive the completion event
  - `onError(Exception)`
    Receive an exception


## `FuncObserver<T> <: Observer<T>`

   - `setNext((T) -> Unit)`
     Specify the function that receives data
   - `setNext((Single<T>) -> Unit)`
     `Single<T>` is an alias of `SingleIterator<T>`; all the functions of `Iterator<T>` can be used inside this closure.
   - `setError((Exception) -> Unit)`
     Specify the function that receives exceptions
   - `setComplete(() -> Unit)`
     Specify the function that receives the completion event


## `EmptyObserver<T>`

   An empty observer

## Error resumer
  - `public func setErrorResumer(resumer: (Exception) -> ?Iterable<T>): This`
  - `public func setErrorResumer(resumeIfNone: Bool, resumer: (Exception) -> ?T) : This`
  - `public func setErrorResumer(resumer: (Exception) -> Unit): This`
  - `public func setErrorResumer(resumeIfFalse: Bool, resumer: (Exception) -> Bool): This`
  - `public func setErrorResumer(resumeIfNone: Bool, resumer: (Exception) -> ?(Emitter<T>) -> Unit): This`


## Replay
`Observable.replaySize(capacity)`
After startup, observers registered later replay the cached data asynchronously; the cached data is at most capacity items

---

## Other public API

The declarations below are not expanded above; they are grouped by module level and by type (members declared in `extend` blocks are listed under the extended type). See the corresponding files under `src/` for the full semantics.

- Module level: `Cache` (interface), `CombinedObserver` (class), `CombinedObserverPolicy` (enum), `public class EmptyCache<T> <: Cache<T>`, `FullSchedulerException` (class), `ObserverRegistrationException` (class), `public class QueuedCache<T> <: Cache<T>`, `RateLimited` (class), `Scheduler` (class), `SingleScheduler` (class), `SingleSchedulerState` (enum)
- `CombinedObserver`: `add` (func), `clear` (func), `remove` (func), `size` (prop)
- `EmptyCache`: `func iterator(): Iterator<T>`, `func new(): Cache<T>`, `func replay(observer: Observer<T>, fn: () -> Unit): Unit`, `func set(value: T): Unit`
- `Observable`: `concat` (func), `emitter` (func), `empty` (func), `isDisposed` (prop), `maybe` (func), `single` (func)
- `QueuedCache`: `func iterator(): Iterator<T>`, `func new(): Cache<T>`, `func replay(observer: Observer<T>, fn: () -> Unit): Unit`, `func set(value: T): Unit`
- `RateLimited`: `static func anyMoment(scheduler: SingleScheduler<T>, maxTokens!: Int64, timeout!: Duration`, `static func leakingBucket(scheduler: SingleScheduler<T>, timeout!: Duration, maxWaitings!: Int64, leakingPerDuration!: Int64, leakingDuration!: Duration`, `static func slidingWindow(scheduler: SingleScheduler<T>, window!: Duration, timeout!: Duration, limit!: Int64`, `static func tokenBucket(scheduler: SingleScheduler<T>, tokens!: Int64, timeout!: Duration, populationPeriod!: Duration`
- `Scheduler`: `alwaysNew` (func), `current` (func), `fixed` (func), `schedule` (func), `single` (func)
- `SingleScheduler`: `func add(state: SingleSchedulerState<T>)`, `func doSchedule(state: SingleSchedulerState<T>): Unit`, `func schedule(item: ?T): Unit`, `func tryRemove()`
