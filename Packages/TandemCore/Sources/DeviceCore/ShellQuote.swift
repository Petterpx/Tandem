/// 把任意字符串转成可安全拼进 adb shell 命令的单引号参数。
public enum ShellQuote {
    /// 单引号包裹，内部的 `'` 写成 `'\''`。
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
