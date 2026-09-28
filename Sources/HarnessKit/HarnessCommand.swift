import Foundation

/// Builds the shell lines that run a harness for one account. Pure functions, so
/// quoting and environment handling are unit-tested.
public enum HarnessCommand {
    public struct Values: Sendable {
        public var prompt: String
        public var briefFile: String
        public var briefDir: String
        public var cwd: String

        public init(prompt: String, briefFile: String, briefDir: String, cwd: String) {
            self.prompt = prompt
            self.briefFile = briefFile
            self.briefDir = briefDir
            self.cwd = cwd
        }
    }

    /// `cd <cwd> && <account env> <launch…>`, every argument shell-quoted.
    public static func launch(_ descriptor: HarnessDescriptor, account: HarnessAccount?, values: Values) -> String {
        let argv = descriptor.launch.map { substitute($0, values) }
        return "cd \(quote(values.cwd)) && " + withAccount(descriptor, account, argv)
    }

    public static func login(_ descriptor: HarnessDescriptor, account: HarnessAccount?) -> String? {
        descriptor.login.map { withAccount(descriptor, account, $0) }
    }

    public static func logout(_ descriptor: HarnessDescriptor, account: HarnessAccount?) -> String? {
        descriptor.logout.map { withAccount(descriptor, account, $0) }
    }

    /// Selects the account's home. For the default account the variable is explicitly
    /// unset, because shells started by other agents often inherit a non-default one.
    static func withAccount(_ descriptor: HarnessDescriptor, _ account: HarnessAccount?, _ argv: [String]) -> String {
        let command = argv.map(quote).joined(separator: " ")
        guard let variable = descriptor.accounts?.env else { return command }
        if let account, !account.isDefault, let home = account.home {
            return "\(variable)=\(quote(home)) \(command)"
        }
        return "env -u \(variable) \(command)"
    }

    static func substitute(_ template: String, _ v: Values) -> String {
        template
            .replacingOccurrences(of: "{prompt}", with: v.prompt)
            .replacingOccurrences(of: "{briefFile}", with: v.briefFile)
            .replacingOccurrences(of: "{briefDir}", with: v.briefDir)
            .replacingOccurrences(of: "{cwd}", with: v.cwd)
    }

    public static func quote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
