import Benchmark
import DeduplicatedSequenceAsyncStream

nonisolated(unsafe) let benchmarks = {
    Benchmark("Initializer") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(DeduplicatedSequenceAsyncStream.makeStream(of: Int.self)) // replace this line with your own benchmark
        }
    }

    Benchmark("Yield") { benchmark in
        let (stream, continuation) = DeduplicatedSequenceAsyncStream.makeStream(of: Int.self)

        benchmark.startMeasurement()

        for i in benchmark.scaledIterations {
            blackHole(continuation.yield(i))
        }

        continuation.finish()

        benchmark.stopMeasurement()
    }

    Benchmark("Yield with consume") { benchmark in
        let (stream, continuation) = DeduplicatedSequenceAsyncStream.makeStream(of: Int.self)

        benchmark.startMeasurement()

        for i in benchmark.scaledIterations {
            blackHole(continuation.yield(i))
        }

        let task = Task {
            for await el in stream {
                continuation.finish()
            }
        }

        await task.value

        benchmark.stopMeasurement()
    }

    Benchmark("Yield with consume concurrent") { benchmark in
        let (stream, continuation) = DeduplicatedSequenceAsyncStream.makeStream(of: Int.self)

        benchmark.startMeasurement()

        let iterations = benchmark.scaledIterations
        Task {
            for i in iterations {
                blackHole(continuation.yield(i))
                await Task.yield()
            }
            continuation.finish()
        }

        let task = Task {
            for await el in stream {}
        }

        await task.value

        benchmark.stopMeasurement()
    }

    Benchmark("AsyncStream - Yield with consume (For comparison)") { benchmark in
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)

        benchmark.startMeasurement()

        for i in benchmark.scaledIterations {
            blackHole(continuation.yield(i))
        }

        let upperBound = benchmark.scaledIterations.upperBound

        let task = Task {
            for await el in stream {
                if el == upperBound - 1 {
                    continuation.finish()
                }
            }
        }

        await task.value

        benchmark.startMeasurement()
    }
}
