/// 需要运行会话的设备集合（spec §3「选中过就保持」），纯值类型，便于测试。
///
/// `wanted = (工作台打开 ? kept : ∅) ∪ popped ∪ ai`；集合里都是逻辑 id。
struct MirrorSet: Equatable {
    /// 在工作台中选中过、尚未「停止投屏」或「移除」的设备。工作台关闭时保留，重新打开时恢复。
    private(set) var kept: Set<String> = []
    /// 弹出为独立窗口的设备，不受工作台开关影响。
    private(set) var popped: Set<String> = []
    /// AI（MCP）使用中的设备，不受工作台开关影响；释放只影响这个集合。
    private(set) var ai: Set<String> = []
    private(set) var workspaceOpen = false

    var wanted: Set<String> {
        (workspaceOpen ? kept : []).union(popped).union(ai)
    }

    /// AI 开始使用：加入 ai（工作台关闭时也运行）。
    mutating func aiAcquire(_ id: String) {
        ai.insert(id)
    }

    /// AI 释放（空闲过期或结束）：移出 ai；仍在 kept / popped 中的继续运行。
    mutating func aiRelease(_ id: String) {
        ai.remove(id)
    }

    /// 在工作台中选中：加入 kept（切到别的设备时原设备仍保留）。
    mutating func select(_ id: String) {
        kept.insert(id)
    }

    /// 右键「停止投屏」：移出 kept；已弹出的仍继续运行。
    mutating func stopMirroring(_ id: String) {
        kept.remove(id)
    }

    /// 右键「移除」：移出所有集合。
    mutating func remove(_ id: String) {
        kept.remove(id)
        popped.remove(id)
        ai.remove(id)
    }

    /// 弹出为独立窗口（也用于系统恢复出的弹出窗口）。
    mutating func popOut(_ id: String) {
        popped.insert(id)
    }

    /// 弹出窗口关闭：移出 popped；仍在 kept 中则由工作台继续保持。
    mutating func popupClosed(_ id: String) {
        popped.remove(id)
    }

    mutating func setWorkspaceOpen(_ open: Bool) {
        workspaceOpen = open
    }
}
