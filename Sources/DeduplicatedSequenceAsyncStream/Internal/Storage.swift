import Synchronization

extension DeduplicatedSequenceAsyncStream {
    final class _Storage: @unchecked Sendable {
        typealias TerminationHandler = @Sendable (Continuation.Termination) -> Void

        init(bufferingPolicy: Continuation.BufferingPolicy) {
            let state = State(limit: bufferingPolicy)
            self.state = Mutex(state)
        }

        struct State: @unchecked Sendable {
            var continuations: [UnsafeContinuation<[Element]?, Never>] = []
            var pending: [Element: Element]
            let limit: Continuation.BufferingPolicy
            var onTermination: TerminationHandler?
            var terminal: Bool = false

            init(limit: Continuation.BufferingPolicy) {
                self.limit = limit

                switch limit {
                case .unbounded:
                    self.pending = .init(minimumCapacity: 10)
                case .bounded(let capacity):
                    self.pending = .init(minimumCapacity: capacity)
                }
           }
       }

        let state: Mutex<State>

         func yield(_ value: sending Element) -> Continuation.YieldResult {

            var result: Continuation.YieldResult = .terminated

            state.withLock { state in

                let limit = state.limit
                let bufferedElementsCount = state.pending.count

                if !state.continuations.isEmpty {
                    let continuation = state.continuations.removeFirst()

                    if bufferedElementsCount > 0 {
                        if !state.terminal {
                            switch limit {
                            case .unbounded:
                                state.pending[value] = value
                                result = .enqueued(remaining: .max)
                            case .bounded(let limit):
                                if bufferedElementsCount < limit {
                                    state.pending[value] = value
                                    result = .enqueued(remaining: limit - (bufferedElementsCount + 1))
                                } else {
                                    result = .dropped(value)
                                }
                            }
                        } else {
                            result = .terminated
                        }

                        let toSend = Array(state.pending.values)
                        state.pending.removeAll()
                        continuation.resume(returning: toSend)
                    } else if state.terminal {
                        result = .terminated
                        continuation.resume(returning: nil)
                    } else {
                        switch limit {
                        case .unbounded:
                            result = .enqueued(remaining: .max)
                        case .bounded(let limit):
                            result = .enqueued(remaining: limit)
                        }
                        // This is needed to bypass the current compiler error if we try to pass the value directly to the continuation.
                        // `value` is sending, and we try to pass it directly to the continuation which is also `sending` but the compiler
                        // cannot verify that we will not use the value after being sent.
                        // This migh be a compiler bug: https://github.com/swiftlang/swift/issues/77199.
                        // We are safe to do so here because we won't retain nor access the `sending` value.
                        let unsafeTransfer = UnsafeTransfer([value])
                        continuation.resume(returning: unsafeTransfer.unwrap)
                    }
                } else {
                    if !state.terminal {
                        switch limit {
                        case .unbounded:
                            result = .enqueued(remaining: .max)
                            state.pending[value] = value
                        case .bounded(let limit):
                            if bufferedElementsCount < limit {
                                state.pending[value] = value
                                let updatedCount = state.pending.count
                                result = .enqueued(remaining: limit - updatedCount)
                            } else {
                                result = .dropped(value)
                            }
                        }
                    } else {
                        result = .terminated
                    }
                }
            }

            return result
        }

         func next(_ continuation: UnsafeContinuation<[Element]?, Never>)  {
            state.withLock { state in
                state.continuations.append(continuation)

                if state.pending.count > 0 {
                    let cont = state.continuations.removeFirst()
                    let toSend = Array(state.pending.values)
                    cont.resume(returning: toSend)
                    state.pending.removeAll()
                } else if state.terminal {
                    let cont = state.continuations.removeFirst()
                    cont.resume(returning: nil)
                }
            }
        }

         func next() async -> [Element]? {
            await withTaskCancellationHandler {
                await withUnsafeContinuation {
                    next($0)
                }
            } onCancel: {
                cancel()
            }
        }

        @Sendable func cancel() {
            var handler: TerminationHandler?
            state.withLock { state in
                // swap out the handler before we invoke it to prevent double cancel
                handler = state.onTermination
                state.onTermination = nil
            }
            // handler must be invoked before yielding nil for termination
            handler?(.cancelled)

            finish()
        }

        func finish() {
            var continuations: [UnsafeContinuation<[Element]?, Never>] = []

            state.withLock { state in

                let handler = state.onTermination
                state.onTermination = nil
                state.terminal = true

                guard !state.continuations.isEmpty else {
                    handler?(.finished)
                    return
                }

                // Hold on to the continuations to resume outside the lock.
                continuations = state.continuations
                state.continuations.removeAll()

                handler?(.finished)
            }

            for continuation in continuations {
                continuation.resume(returning: nil)
            }
        }

        func getOnTermination() -> TerminationHandler? {
            state.withLock { state in
                return state.onTermination
            }
        }

        func setOnTermination(_ newValue: TerminationHandler?) {
            state.withLock { state in
                withExtendedLifetime(state.onTermination) {
                    state.onTermination = newValue
                }
            }
        }
    }
}

extension DeduplicatedSequenceAsyncStream {
    fileprivate struct UnsafeTransfer<T>: @unchecked Sendable {
        let unwrap: T

        init(_ value: T) {
            self.unwrap = value
        }
    }
}
