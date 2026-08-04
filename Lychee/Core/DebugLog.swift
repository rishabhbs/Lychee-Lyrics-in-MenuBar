import Foundation

@inline(__always)
func lycheeDebugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
