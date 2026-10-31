import Foundation

enum ResourceBundle {
    static var app: Bundle {
        #if SWIFT_PACKAGE
        .module
        #else
        .main
        #endif
    }
}
