The `DeduplicatedSequenceAsyncStream` extends the concept of `AsyncStream` by adding element deduplication. Instead of delivering individual updates to consumers, it maintains a buffer of unique elements and delivers sequences of these elements to consumers. It requires that the elements of the generated sequence conform to `Hashable`.


## Installation
Add package to as your dependency:
```swift
.package(url: "https://github.com/supersonicbyte/deduplicated-sequence-async-stream")
```
Voila! That's it.

## Usage
Create a stream with the static `makeStream` or with the closure based initializer.

```swift
struct StockPrice: Hashable {
    let symbol: String
    let price: Double

    func hash(into hasher: inout Hasher) {
        hasher.combine(symbol)
    }

    static func == (lhs: StockPrice, rhs: StockPrice) -> Bool {
        return lhs.symbol == rhs.symbol
    }
}

let (stream, continuation) = DeduplicatedSequenceAsyncStream.makeStream(of: StockPrice.self)
```

Use the `continuation` to produce values into the stream:
```swift
continuation.yield(StockPrice(name: "AAPL", price: 120))
continuation.yield(StockPrice(name: "GOOGL", price: 230))
```
Use the stream's async iterator to consume the sequences produced by the stream:
```
Task {
  for await prices in stream {
    print(prices)
  }
}
```
After you finish producing call the `finish()` method on the continuation to terminate the stream.
```swift
continuation.finish()
```

Use the `onTerminate()` callback to get notified when the stream get's terminated:
```swift
continuation.onTermination = { termination in 
  switch termination {
    case .finished:
      print("stream finished!")
    case .cancelled:
      print("stream cancelled!")
  }
}
```

For more details on usage check out the documentation.
