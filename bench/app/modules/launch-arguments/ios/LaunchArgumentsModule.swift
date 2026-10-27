import ExpoModulesCore

// launchApp's arguments arrive as `-key value` pairs (a boolean may come without its dash).
public class LaunchArgumentsModule: Module {
  public func definition() -> ModuleDefinition {
    Name("LaunchArguments")

    Function("get") { () -> [String: String] in
      let args = ProcessInfo.processInfo.arguments
      var out: [String: String] = [:]
      var i = 1
      while i + 1 < args.count {
        let key = args[i], value = args[i + 1]
        if key.hasPrefix("-") {
          out[String(key.dropFirst())] = value
          i += 2
        } else if value == "true" || value == "false" {
          out[key] = value
          i += 2
        } else {
          i += 1
        }
      }
      return out
    }
  }
}
