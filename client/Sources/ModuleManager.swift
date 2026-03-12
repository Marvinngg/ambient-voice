import Foundation

@MainActor
final class ModuleManager {
    private var modules: [String: WEModule] = [:]

    /// 当前激活的模块（热键事件路由到此模块）
    var activeModule: WEModule? {
        modules.values.first { $0.isActive }
    }

    var moduleNames: [String] {
        Array(modules.keys)
    }

    func register(_ module: WEModule) {
        modules[module.name] = module
        // 第一个注册的模块默认激活
        if modules.count == 1 {
            module.isActive = true
        }
        Logger.log("ModuleManager", "Registered module: \(module.name)")
    }

    func activate(_ name: String) {
        for (key, module) in modules {
            module.isActive = (key == name)
        }
    }
}
