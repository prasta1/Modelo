import Foundation

/// Read-only tool that returns the current local date and time on this Mac.
/// Accepts an optional IANA timezone identifier so the model can also answer
/// "what time is it in Tokyo?" without a separate calculation.
struct CurrentTimeTool: Tool {
    let name = "get_current_time"
    let alwaysVisible = true

    let description = """
        Get the current date and time on the user's Mac. \
        Call this whenever you need to know today's date, the current time, \
        or to compute anything relative to "now". \
        Pass an optional IANA timezone identifier to get the time in another zone.
        """

    var parameters: JSONSchema {
        JSONSchema(
            properties: [
                "timezone": .init("string",
                    "Optional IANA timezone identifier, e.g. \"America/New_York\" or \"Asia/Tokyo\". " +
                    "Defaults to the Mac's local timezone when omitted.")
            ],
            required: []
        )
    }

    func execute(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let timezone: String? }
        let args = (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8)))

        let tz: TimeZone
        if let id = args?.timezone, !id.isEmpty,
           let resolved = TimeZone(identifier: id) {
            tz = resolved
        } else {
            tz = .current
        }

        let formatter = DateFormatter()
        formatter.timeZone = tz
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm:ss a zzz"
        return formatter.string(from: Date())
    }
}
