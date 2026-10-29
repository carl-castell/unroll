import ArgumentParser
import Foundation

@main
enum Entry {
    /// ImageCaptureCore delivers its callbacks through the main run loop, so the commands run in a
    /// main-actor task while the main thread runs the loop.
    static func main() {
        // Line-buffer stdout so pipes, logs and Shortcuts see progress as it happens.
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in
            await Unroll.main()
            exit(0)
        }
        CFRunLoopRun()
    }
}
