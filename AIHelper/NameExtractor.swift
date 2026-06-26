import Foundation

/// Extracts proper names from email text using common patterns
enum NameExtractor {
    /// Extract names from email text using greeting, sign-off, and introduction patterns
    static func extractNames(from text: String) -> [String] {
        var names = Set<String>()

        // Pattern 1: "My name is X" or "I'm X," or "I am X,"
        let introPatterns = [
            "(?i)my name is (\\w+)",
            "(?i)this is (\\w+)",
            "(?i)i'm (\\w+),",
            "(?i)i am (\\w+),"
        ]

        // Pattern 2: Sign-off patterns like "Best regards,\nMaryam"
        let signoffPatterns = [
            "(?i)best regards,?\\s*\\n(\\w+)",
            "(?i)kind regards,?\\s*\\n(\\w+)",
            "(?i)sincerely,?\\s*\\n(\\w+)",
            "(?i)thank you,?\\s*\\n(\\w+)",
            "(?i)thanks,?\\s*\\n(\\w+)",
            "(?i)best,?\\s*\\n(\\w+)",
            "(?i)regards,?\\s*\\n(\\w+)",
            "(?i)cheers,?\\s*\\n(\\w+)"
        ]

        // Pattern 3: Greeting patterns like "Hello Hendrik," or "Dear Maryam,"
        let greetingPatterns = [
            "(?i)hello (\\w+),",
            "(?i)hi (\\w+),",
            "(?i)dear (\\w+),",
            "(?i)hey (\\w+),"
        ]

        let allPatterns = introPatterns + signoffPatterns + greetingPatterns

        for pattern in allPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(text.startIndex..., in: text)
                let matches = regex.matches(in: text, options: [], range: range)

                for match in matches {
                    if match.numberOfRanges >= 2,
                       let captureRange = Range(match.range(at: 1), in: text) {
                        let name = String(text[captureRange])
                        // Filter out common non-name words
                        let commonWords = Set(["I", "The", "This", "That", "My", "Your", "It", "We", "They"])
                        if !commonWords.contains(name) && name.count >= 2 {
                            names.insert(name)
                        }
                    }
                }
            }
        }

        return Array(names)
    }
}
