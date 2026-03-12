import Foundation

/// Shell + Module 架构中的模块协议
/// 当前只有 VoiceModule，未来可扩展 Chat/Files/Tools
@MainActor
protocol WEModule: AnyObject {
    var name: String { get }
    var isActive: Bool { get set }

    func onHotKeyDown()
    func onHotKeyUp()
}
