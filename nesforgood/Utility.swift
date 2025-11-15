import Foundation

extension Array {
    subscript(i: UInt16) -> Element {
        get {
            return self[Int(i)]
        } set(from) {
            self[Int(i)] = from
        }
    }
}
