import Testing
@testable import DeduplicatedSequenceAsyncStream

@Suite("DeduplicatedSequenceAsyncStreamTests")
struct DeduplicatedSequenceAsyncStreamTests {

    @Test func test_initializer() async throws {
        let stream = DeduplicatedSequenceAsyncStream.init { continuation in
            continuation.yield(4)
            continuation.yield(4)
            continuation.finish()
        }

        var iterator = stream.makeAsyncIterator()

        let result = await iterator.next()

        #expect(result == [4])
    }

    @Test func test_deduplicates_elements() async throws {
        let (stream, continuation) = DeduplicatedSequenceAsyncStream.makeStream(of: StockPrice.self)

        var iterator = stream.makeAsyncIterator()

        continuation.yield(.init(symbol: "AAPL", price: 120.0))
        continuation.yield(.init(symbol: "NVIDIA", price: 90))
        continuation.yield(.init(symbol: "AAPL", price: 170))

        let result = await iterator.next()
        #expect(result?.count == 2)
        let set = Set(result ?? [])
        let expectedSet = Set([StockPrice(symbol: "AAPL", price: 170), StockPrice(symbol: "NVIDIA", price: 90)])
        #expect(set == expectedSet)

        continuation.yield(.init(symbol: "AAPL", price: 120.0))
        continuation.yield(.init(symbol: "AAPL", price: 120.0))
        continuation.yield(.init(symbol: "AAPL", price: 120.0))

        let secondResult = await iterator.next()
        #expect(secondResult?.count == 1)
        #expect(secondResult?.first == StockPrice(symbol: "AAPL", price: 120))

        continuation.finish()
    }

    @Test func test_returns_nil_when_finished() async throws {
        let (stream, continuation) = DeduplicatedSequenceAsyncStream.makeStream(of: Int.self)

        var iterator = stream.makeAsyncIterator()

        var yieldResult = continuation.yield(2)
        #expect(yieldResult == .enqueued(remaining: .max))

        _ = await iterator.next()

        continuation.finish()

        yieldResult = continuation.yield(2)
        #expect(yieldResult == .terminated)

        let result = await iterator.next()

        #expect(result == nil)
    }

    @Test func test_termination_handler_called_with_cancel_when_cancelled() async throws {

        let (stream, continuation) = DeduplicatedSequenceAsyncStream.makeStream(of: Int.self)

        try await confirmation { called in

            continuation.onTermination = { termination in
                #expect(termination == .cancelled)
                called()
            }

            Task {
                for i in 0..<100{
                    continuation.yield(i)
                    try await Task.sleep(for: .seconds(1))
                }
            }

            var task: Task<Void, Never>!

            task = Task.detached {
                for await _ in stream {}
            }

            task.cancel()

            // Very bad. We should bridge the `fulfillment` API
            // from XCTest instead or creating something similiar.
            try await Task.sleep(for: .seconds(0.1))

        }

        let yieldResult = continuation.yield(2)
        #expect(yieldResult == .terminated)
   }

    @Test func test_termination_handler_called_with_stream_finished() async throws {

        let (_, continuation) = DeduplicatedSequenceAsyncStream.makeStream(of: Int.self)

        await confirmation { confirmation in

            continuation.onTermination = { termination in
                #expect(termination == .finished)
                confirmation()
            }

            continuation.yield(1)

            continuation.finish()
        }

        let yieldResult = continuation.yield(2)
        #expect(yieldResult == .terminated)
   }

    @Test func test_iterator_before_yield() async throws {

        let (stream, continuation) = DeduplicatedSequenceAsyncStream.makeStream(of: Int.self)

        let task = Task {
            try await confirmation() { confirmation in
                for try await _ in stream {}
                confirmation()
            }
        }

        Task {
            for i in 0..<2 {
                continuation.yield(i)
            }

            continuation.finish()
        }

        try await task.value
    }

    @Test func test_finish_with_iterator_before() async throws {

        let (stream, continuation) = DeduplicatedSequenceAsyncStream.makeStream(of: Int.self)

        let task = Task {
            try await confirmation { confirmation in
                for try await _ in stream {}
                confirmation()
            }
        }

        continuation.finish()

        try await task.value
    }

    @Test func test_get_termination_handler() async throws {
        let (stream, continuation) = DeduplicatedSequenceAsyncStream.makeStream(of: Int.self)
        _ = stream.makeAsyncIterator()

        await confirmation { confirmation in

            let handler: @Sendable (DeduplicatedSequenceAsyncStream<Int>.Continuation.Termination) -> Void = { _ in
                confirmation()
            }

            continuation.onTermination = handler

            let get = continuation.onTermination

            get?(.cancelled)
        }
    }

    @Test func test_stream_terminates_automatically_when_going_out_of_scope() async throws {

        func makeStreamAndDie(onTermination: @escaping @Sendable (DeduplicatedSequenceAsyncStream<Int>.Continuation.Termination) -> Void) {
            // If we use _ instead of stream for some reason termination handler won't be called as if swift doesn't detect
            // stream going ot ouf scope. Could be a compiler bug -- not sure.
            let (stream, continuation) = DeduplicatedSequenceAsyncStream.makeStream(of: Int.self)
            // Silence the warning
            _ = stream.makeAsyncIterator()
            continuation.onTermination = onTermination
        }

        await confirmation { confirmation in
            makeStreamAndDie { termination in
                #expect(termination == .cancelled)
                confirmation()
            }
        }
    }

    @Test func test_concurrent_yields() async throws {
        let (stream, continuation) = DeduplicatedSequenceAsyncStream.makeStream(of: String.self)

        await withTaskGroup(of: Void.self) { group in
            for str in ["Beatles", "Arctic Monkeys", "Oasis", "Pink Floyd"] {
                group.addTask {
                    continuation.yield(str)
                }
            }
        }

        var iterator = stream.makeAsyncIterator()

        let result = await iterator.next()

        let set = Set(try #require(result))

        #expect(set == Set(["Beatles", "Arctic Monkeys", "Oasis", "Pink Floyd"]))
    }

    @Test func test_buffer_policy_bounded() async throws {
        let (stream, continuation) = DeduplicatedSequenceAsyncStream.makeStream(of: Int.self, bufferingPolicy: .bounded(3))

        continuation.yield(1)
        continuation.yield(1)
        continuation.yield(1)

        var yieldResult = continuation.yield(1)
        #expect(yieldResult == .enqueued(remaining: 2))

        yieldResult = continuation.yield(2)
        #expect(yieldResult == .enqueued(remaining: 1))
        yieldResult = continuation.yield(3)
        #expect(yieldResult == .enqueued(remaining: 0))
        yieldResult = continuation.yield(4)
        #expect(yieldResult == .dropped(4))


        var iterator = stream.makeAsyncIterator()

        let _ = await iterator.next()

        yieldResult = continuation.yield(5)
        #expect(yieldResult == .enqueued(remaining: 2))
        yieldResult = continuation.yield(5)
        #expect(yieldResult == .enqueued(remaining: 2))
        yieldResult = continuation.yield(6)
        #expect(yieldResult == .enqueued(remaining: 1))
        yieldResult = continuation.yield(7)
        #expect(yieldResult == .enqueued(remaining: 0))
        yieldResult = continuation.yield(8)
        #expect(yieldResult == .dropped(8))

        continuation.finish()
    }

    @Test func test_buffer_policy_unbounded() async throws {
        let (stream, continuation) = DeduplicatedSequenceAsyncStream.makeStream(of: Int.self, bufferingPolicy: .unbounded)

        for i in 0..<1_000 {
            let result = continuation.yield(i)
            #expect(result == .enqueued(remaining: .max))
        }

        var iterator = stream.makeAsyncIterator()

        let result = await iterator.next()

        let set = Set(result ?? [])

        #expect(set == Set(0..<1_000))

        continuation.finish()
    }
}
