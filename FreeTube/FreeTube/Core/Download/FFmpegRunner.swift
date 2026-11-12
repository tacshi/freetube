import Foundation

import FFmpegSupport

/// Serializes every call into the ffmpeg C library.
///
/// **Why this is necessary:** `FFmpegSupport.ffmpeg(_:)` is an entry point into a C library with
/// shared global state — most painfully the `+faststart` post-pass (which moves the moov atom to
/// the front of the file). That pass walks global I/O buffers and is *not* thread-safe; two
/// concurrent invocations race and crash with EXC_BAD_ACCESS. The package's `Hook.m` shim also
/// uses `setjmp`/`longjmp`, which has undefined behavior across concurrent calls.
///
/// With this actor, every ffmpeg invocation chains strictly behind the previous one through
/// `pending`, even though the actor body itself can suspend.
@available(iOS 17.0, *)
actor FFmpegRunner {
    static let shared = FFmpegRunner()

    /// Tail of the in-flight FIFO. New callers await this before invoking ffmpeg.
    private var pending: Task<Void, Never>?

    private init() {}

    /// Runs ffmpeg with the given argv off the main actor and returns its exit code. Concurrent
    /// callers are queued — they don't run until the previous ffmpeg call has fully returned.
    func run(_ args: [String]) async -> Int32 {
        let previous = pending
        // Detached (CLAUDE.md §15.12): the C work must not land on the main actor, and must not
        // block this actor's executor either.
        let task = Task<Int32, Never>.detached(priority: .utility) {
            await previous?.value
            return Int32(ffmpeg(args))
        }
        pending = Task<Void, Never> { _ = await task.value }
        return await task.value
    }
}
