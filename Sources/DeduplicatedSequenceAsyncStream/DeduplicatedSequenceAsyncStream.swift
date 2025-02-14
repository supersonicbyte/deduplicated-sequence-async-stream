
/// A deduplicated sequence asynchronous stream generated from a closure that calls a continuation
/// to produce new elements.
///
///  `DeduplicatedSequenceAsyncStream` extends the concept of `AsyncStream` by adding element deduplication.
///  Instead of delivering individual updates to consumers, it maintains a buffer of unique elements and delivers sequences of
///  these elements to consumers. It requiers that the elements of the generated sequence conform to `Hashable`.
///
///
///  You initialize a `DeduplicatedSequenceAsyncStream` with a closure that receives an
/// `DeduplicatedSequenceAsyncStream.Continuation`. Produce elements in this closure,
///  then provide them to the stream by calling the continuation's `yield(_:)` method. When
///  there are no further elements to produce, call the continuation's `finish()` method.
///  This causes the sequence iterator to produce a `nil`, which terminates the sequence.
///  The continuation conforms to `Sendable`, which permits calling it from concurrent contexts external
///  to the iteration of the `DeduplicatedSequenceAsyncStream`.
///
///  An arbitrary source of elements can produce elements faster than they are consumed by a caller
///  iterating over them. Because of this, `DeduplicatedSequenceAsyncStream`defines a buffering behavior,
///  allowing the stream to buffer a specific number of oldest or newest elements. By default, the buffer limit is `Int.max`,
///  which means the value is unbounded.
///
///
/// ### Example of DeduplcatedSequenceAsyncStream in Action
///
///  Consider the following type `StockPrice`.
///    ```swift
///    struct StockPrice: Hashable {
///        let symbol: String
///        let price: Double
///
///        func hash(into hasher: inout Hasher) {
///            hasher.combine(symbol)
///        }
///
///        static func == (lhs: StockPrice, rhs: StockPrice) -> Bool {
///            return lhs.symbol == rhs.symbol
///        }
///     }
///    ```
///
///  Imagine we have two different parts of an app, one called a producer which
///  produces values into the stream, and the other called consumer - which consumes
///  the values from the stream.
///
///  The producer code consists of yielding values to the stream, e.g.
///    ```swift
///    ...
///     continuation.yield(StockPrice(symbol: "AAPL", price: 150.0))
///    ...
///    ```
///
///  The consumer code consists of consuming the stream:
///    ```swift
///    ...
///    for try await stockPrices in stream {
///             ...
///    }
///    ...
///    ```
///
///  To better understand what `DeduplicatedSequenceAsyncStream` does let's
///  examine the following flow:
///
///
///  1. Producer yield three values to the stream
///    ```swift
///    continuation.yield(StockPrice(symbol: "AAPL", price: 150.0))
///    continuation.yield(StockPrice(symbol: "GOOGL", price: 2800.0))
///    continuation.yield(StockPrice(symbol: "AAPL", price: 151.0))
///    ```
///
///  2. Consumer task wakes up
///    ```swift
///    for await prices in stream {
///       print("\(prices)”) // Outputs: [APPL=151.0, GOOGL=2800.0]
///    }
///    ```
///
///  We can see that at the moment when the consumer task waked up we consumed one sequence with two elements.
///  The second yield of the AAPL only updated the existing element in the buffer not creating another entry.
///
///
///  3. Producer yields two more values
///    ```swift
///    continuation.yield(StockPrice(symbol: “NVDA", price: 135.0))
///    continuation.yield(StockPrice(symbol: “APPL", price: 152.0))
///    ```
///
///  4. Consumer wakes up:
///   ```swift
///   for await prices in stream {
///     print("\(prices)”) // Output: [APPL=152.0, NVDA=135.0]
///   }
///   ```
///  Now the the stream returns a sequence with two elements containing the AAPL and NVDA stocks. The GOOGL stock
///  is not present since it was consumed it the first iteration.
///
///
///
///
public struct DeduplicatedSequenceAsyncStream<Element: Hashable> {

    // A mechanism to interface between synchronous code and an asynchronous
    /// stream.
    ///
    /// The closure you provide to the `DeduplicatedSequenceAsyncStream` in
    /// `init(_:bufferingPolicy:_:)` receives an instance of this type when
    /// invoked. Use this continuation to provide elements to the stream by
    /// calling one of the `yield` methods, then terminate the stream normally by
    /// calling the `finish()` method.
    ///
    /// - Note: Unlike other continuations in Swift, `DeduplicatedSequenceStream.Continuation`
    /// supports escaping.
    public struct Continuation: Sendable {

        /// A type that indicates how the stream terminated.
        ///
        /// The `onTermination` closure receives an instance of this type.
        public enum Termination: Sendable {
            /// The stream finished as a result of calling the continuation's
            ///  `finish` method.
            case finished
            /// The stream finished as a result of cancellation.
            case cancelled
        }

        /// A type that indicates the result of yielding a value to a client, by
        /// way of the continuation.
        ///
        /// The various `yield` methods of `DeduplicatedSequenceAsyncStream.Continuation`
        /// return this type to indicate the success or failure of yielding an element to the continuation.
        public enum YieldResult: Equatable {

            /// The stream successfully enqueued the element.
            ///
            /// This value represents the successful enqueueing of an element, whether
            /// the stream buffers the element or delivers it immediately to a pending
            /// call to `next()`. The associated value `remaining` is a hint that
            /// indicates the number of remaining slots in the buffer at the time of
            /// the `yield` call.
            ///
            /// - Note: From a thread safety point of view, `remaining` is a lower bound
            /// on the number of remaining slots. This is because a subsequent call
            /// that uses the `remaining` value could race on the consumption of
            /// values from the stream.
            case enqueued(remaining: Int)

            /// The stream didn't enqueue the element because the buffer was full.
            ///
            /// The associated element for this case is the element dropped by the stream.
            case dropped(Element)

            /// The stream didn't enqueue the element because the stream was in a
            /// terminal state.
            ///
            /// This indicates the stream terminated prior to calling `yield`, either
            /// because the stream finished normally or through cancellation.
            case terminated
        }

        /// A strategy that handles exhaustion of a buffer’s capacity.
        public enum BufferingPolicy: Sendable {

            /// Continue to add to the buffer, without imposing a limit on the number
            /// of buffered elements.
            case unbounded

            /// When the buffer is full, discard the newly received element.
            ///
            /// This strategy enforces keeping at most the specified number of oldest
            /// values.
            case bounded(Int)
        }

        let storage: _Storage

        /// Resume the task awaiting the next iteration point by having it return
        /// normally from its suspension point with a given element.
        ///
        /// - Parameter value: The value to yield from the continuation.
        /// - Returns: A `YieldResult` that indicates the success or failure of the
        ///   yield operation.
        ///
        /// If nothing is awaiting the next value, this method attempts to buffer the
        /// result's element.
        ///
        /// This can be called more than once and returns to the caller immediately
        /// without blocking for any awaiting consumption from the iteration.
        @discardableResult
        public func yield(_ value: sending Element) -> YieldResult {
            storage.yield(value)
        }


        /// Resume the task awaiting the next iteration point by having it return
        /// nil, which signifies the end of the iteration.
        ///
        /// Calling this function more than once has no effect. After calling
        /// finish, the stream enters a terminal state and doesn't produce any
        /// additional elements.
        public func finish() {
            storage.finish()
        }


        /// A callback to invoke when canceling iteration of an asynchronous
        /// stream.
        ///
        /// If an `onTermination` callback is set, using task cancellation to
        /// terminate iteration of an `DeduplicatedSequenceAsyncStream` results in
        /// a call to this callback.
        ///
        /// Canceling an active iteration invokes the `onTermination` callback
        /// first, then resumes by yielding `nil`. This means that you can perform
        /// needed cleanup in the cancellation handler. After reaching a terminal
        /// state as a result of cancellation, the `DeduplicatedSequenceAsyncStream` sets
        /// the callback to `nil`.
        public var onTermination: (@Sendable (Termination) -> Void)? {
            get {
                return storage.getOnTermination()
            }
            nonmutating set {
                storage.setOnTermination(newValue)
            }
        }
    }

    final class _Context {
        let storage: _Storage?
        let produce: () async -> [Element]?

        init(storage: _Storage? = nil, produce: @escaping () async -> [Element]?) {
            self.storage = storage
            self.produce = produce
        }

        deinit {
            storage?.cancel()
        }
    }

    let context: _Context

    /// Constructs an asynchronous deduplicated sequence stream for an element type, using the
    /// specified buffering policy and element-producing closure.
    ///
    /// - Parameters:
    ///    - elementType: The type of element in the sequence the `DeduplicatedSequenceAsyncStream` produces.
    ///    - bufferingPolicy: A `Continuation.BufferingPolicy` value to
    ///       set the stream's buffering behavior. By default, the stream buffers an
    ///       unlimited number of elements. You can also set the policy to buffer a
    ///       limited number of oldest elements.
    ///    - build: A custom closure that yields values to the
    ///       `DeduplicatedSequenceAsyncStream`. This closure receives an `DeduplicatedSequenceAsyncStream.Continuation`
    ///       instance that it uses to provide elements to the stream and terminate the
    ///       stream when finished.
    ///
    /// The `DeduplicatedSequenceAsyncStream.Continuation` received by the `build` closure is
    /// appropriate for use in concurrent contexts. It is thread safe to send and
    /// finish; all calls to the continuation are serialized. However, calling
    /// this from multiple concurrent contexts could result in out-of-order
    /// delivery.
    ///
    /// The following example shows an `DeduplicatedSequenceAsyncStream` created with this
    /// initializer that produces 100 random numbers on a one-second interval,
    /// calling `yield(_:)` to deliver each element to the awaiting call point.
    /// When the `for` loop exits, the stream finishes by calling the
    /// continuation's `finish()` method.
    ///
    ///     let stream = DeduplicatedSequenceAsyncStream<Int>(Int.self,
    ///                                   bufferingPolicy: .bufferingNewest(5)) { continuation in
    ///         Task.detached {
    ///             for _ in 0..<100 {
    ///                 await Task.sleep(1 * 1_000_000_000)
    ///                 continuation.yield(Int.random(in: 1...10))
    ///             }
    ///             continuation.finish()
    ///         }
    ///     }
    ///
    ///     // Call point:
    ///     for await random in stream {
    ///         print(random)
    ///     }
    ///
    public init(
        _ elementType: Element.Type = Element.self,
        bufferingPolicy limit: Continuation.BufferingPolicy = .unbounded,
        _ build: (Continuation) -> Void
    ) {
        let storage: _Storage = _Storage(bufferingPolicy: limit)
        context = _Context(storage: storage, produce: storage.next)
        build(Continuation(storage: storage))
    }

    /// Initializes a new ``DeduplicatedSequenceAsyncStream`` and an ``DeduplicatedSequenceAsyncStream/Continuation``.
    ///
    /// - Parameters:
    ///   - elementType: The element type of the stream.
    ///   - limit: The buffering policy that the stream should use.
    /// - Returns: A tuple containing the stream and its continuation. The continuation should be passed to the
    /// producer while the stream should be passed to the consumer.
    public static func makeStream(
        of elementType: Element.Type = Element.self,
        bufferingPolicy limit: Continuation.BufferingPolicy = .unbounded
    ) -> (stream: DeduplicatedSequenceAsyncStream<Element>, continuation:DeduplicatedSequenceAsyncStream<Element>.Continuation) {
        var continuation: DeduplicatedSequenceAsyncStream<Element>.Continuation!
        let stream = DeduplicatedSequenceAsyncStream<Element>(bufferingPolicy: limit) { continuation = $0 }
        return (stream: stream, continuation: continuation!)
    }
}

extension DeduplicatedSequenceAsyncStream: AsyncSequence {

    /// The asynchronous iterator for iterating an asynchronous deduplicated sequence stream.
    ///
    /// This type doesn't conform to `Sendable`. Don't use it from multiple
    /// concurrent contexts. It is a programmer error to invoke `next()` from a
    /// concurrent context that contends with another such call, which
    /// results in a call to `fatalError()`.
    public struct Iterator: AsyncIteratorProtocol {
        let context: _Context

        /// The asynchronous iterator for iterating an deduplicated sequence asynchronous stream.
        ///
        /// This type doesn't conform to `Sendable`. Don't use it from multiple
        /// concurrent contexts. It is a programmer error to invoke `next()` from a
        /// concurrent context that contends with another such call, which
        /// results in a call to `fatalError()`.
        public mutating func next() async -> [Element]? {
            return await context.produce()
        }
    }

    /// Creates the asynchronous iterator that produces elements of this
    /// asynchronous sequence.
    public func makeAsyncIterator() -> Iterator{
        return Iterator(context: context)
    }
}

extension DeduplicatedSequenceAsyncStream: @unchecked Sendable where Element: Sendable {}

extension DeduplicatedSequenceAsyncStream.Continuation.YieldResult: Sendable where Element: Sendable {}
