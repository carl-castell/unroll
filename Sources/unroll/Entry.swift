import ArgumentParser
import Foundation

@main
enum Entry {
    /// ImageCaptureCore delivers its callbacks through the main run loop, so the commands run in a
    /// main-actor task while the main thread runs the loop.
    static func main() {
        Task { @MainActor in
            await Unroll.main()
            exit(0)
        }
        CFRunLoopRun()
    }
}
