import FlyingFox
import FlyingSocks
import Foundation

/// Lets an `AsyncStream<Data>` be used as an HTTP response body.
///
/// FlyingFox streams a body from an `AsyncBufferedSequence<UInt8>` — a
/// protocol that hands out chunks rather than one byte at a time, so a
/// response is not written a byte per `await`. Nothing in the standard library
/// conforms to it, so this is the adapter.
///
/// It exists so chat can send its sources the moment retrieval finishes
/// instead of after the model has finished writing. On-device generation takes
/// seconds; holding the connection open with nothing on it means the page
/// shows a spinner and the citations the user could already have been reading.
struct StreamingBody: AsyncBufferedSequence, Sendable {
    typealias Element = UInt8

    let chunks: AsyncStream<Data>

    func makeAsyncIterator() -> Iterator {
        Iterator(inner: chunks.makeAsyncIterator())
    }

    struct Iterator: AsyncBufferedIteratorProtocol {
        var inner: AsyncStream<Data>.Iterator
        var pending: [UInt8] = []

        mutating func next() async throws -> UInt8? {
            if pending.isEmpty { await fill() }
            return pending.isEmpty ? nil : pending.removeFirst()
        }

        /// Hand back up to `count` bytes, suspending until some arrive.
        /// Returning nil means the stream is finished — not that it is merely
        /// quiet, which is why `fill` loops past empty chunks.
        mutating func nextBuffer(suggested count: Int) async throws -> ArraySlice<UInt8>? {
            if pending.isEmpty { await fill() }
            guard !pending.isEmpty else { return nil }
            let take = min(max(1, count), pending.count)
            let out = pending.prefix(take)
            pending.removeFirst(take)
            return out
        }

        private mutating func fill() async {
            while pending.isEmpty {
                guard let data = await inner.next() else { return }
                pending = [UInt8](data)
            }
        }
    }
}

extension Respond {
    /// A newline-delimited JSON response that is written as it is produced.
    static func ndjsonStream(_ chunks: AsyncStream<Data>) -> HTTPResponse {
        HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "application/x-ndjson; charset=utf-8"],
            body: HTTPBodySequence(from: StreamingBody(chunks: chunks))
        )
    }
}
