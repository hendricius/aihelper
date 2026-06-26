import Foundation

/// Default vocabulary for transcription hints
/// These terms help the transcription service correctly spell domain-specific terminology
enum VocabularyDefaults {

    // MARK: - UserDefaults Key

    static let vocabularyKey = "custom_vocabulary"

    // MARK: - Proper Nouns & Brand Names

    static let properNouns = [
        "theBread.code()",
        "Loafy",
        "Gluten Tag",
        "The Sourdough Framework"
    ]

    // MARK: - Baking Processes

    static let processes = [
        "bulk fermentation",
        "autolyse",
        "fermentolyse",
        "proofing",
        "retarding",
        "preshaping",
        "bench rest",
        "scoring",
        "stretch and fold",
        "coil fold",
        "lamination",
        "over fermenting",
        "over proofing"
    ]

    // MARK: - Ingredients & Preferments

    static let ingredients = [
        "sourdough starter",
        "levain",
        "preferment",
        "poolish",
        "biga",
        "pâte fermentée",
        "Brühstück",
        "Kochstück",
        "scald",
        "yudane",
        "tangzhong",
        "diastatic malt",
        "bread flour",
        "einkorn",
        "spelt",
        "rye"
    ]

    // MARK: - Equipment

    static let equipment = [
        "banneton",
        "Dutch oven",
        "alveograph",
        "aliquot jar",
        "Pullman pan",
        "lame"
    ]

    // MARK: - Characteristics & Properties

    static let characteristics = [
        "dough hydration",
        "gluten",
        "crumb",
        "open crumb",
        "tight crumb",
        "fool's crumb",
        "oven spring",
        "elasticity",
        "extensibility",
        "alveoli"
    ]

    // MARK: - Tests & Techniques

    static let techniques = [
        "float test",
        "finger poke test",
        "windowpane test",
        "bassinage"
    ]

    // MARK: - Chemistry & Microbiology

    static let science = [
        "wild yeast",
        "lactic acid bacteria",
        "acetic acid",
        "lactic acid",
        "amylase",
        "protease",
        "Maillard reaction"
    ]

    // MARK: - Programming Languages & Frameworks

    static let programmingLanguages = [
        "Swift", "SwiftUI", "UIKit", "AppKit", "Combine",
        "JavaScript", "TypeScript", "Node.js", "React", "Next.js", "Vue.js", "Svelte",
        "Python", "Django", "FastAPI", "Flask", "NumPy", "Pandas", "PyTorch", "TensorFlow",
        "Rust", "Cargo", "Go", "Golang", "Kotlin", "Java", "Scala",
        "Ruby", "Rails", "PHP", "Laravel", "C++", "C#", "dotnet",
        "HTML", "CSS", "SCSS", "Tailwind", "GraphQL", "REST API"
    ]

    // MARK: - AI & LLM Terms

    static let aiTerms = [
        "Claude", "Claude Code", "Anthropic", "OpenAI", "GPT", "GPT-4", "ChatGPT",
        "LLM", "large language model", "transformer", "attention mechanism",
        "prompt engineering", "system prompt", "few-shot", "zero-shot", "chain of thought",
        "RAG", "retrieval augmented generation", "embeddings", "vector database",
        "fine-tuning", "RLHF", "tokenizer", "context window", "temperature",
        "Whisper", "DALL-E", "Midjourney", "Stable Diffusion",
        "Langchain", "LlamaIndex", "Pinecone", "Weaviate", "ChromaDB",
        "Ollama", "Llama", "Mistral", "Mixtral", "Gemini", "Copilot", "Cursor",
        "agentic", "multi-agent", "tool use", "function calling", "MCP", "Model Context Protocol"
    ]

    // MARK: - DevOps & Infrastructure

    static let devOps = [
        "Docker", "Dockerfile", "Kubernetes", "K8s", "kubectl", "Helm",
        "AWS", "EC2", "S3", "Lambda", "CloudFront", "ECS", "EKS", "RDS",
        "Azure", "GCP", "Google Cloud", "Vercel", "Netlify", "Cloudflare",
        "Terraform", "Ansible", "Pulumi", "CDK",
        "CI/CD", "GitHub Actions", "GitLab CI", "Jenkins", "CircleCI",
        "nginx", "Apache", "Redis", "Memcached", "Elasticsearch",
        "Prometheus", "Grafana", "Datadog", "PagerDuty", "Sentry"
    ]

    // MARK: - Databases

    static let databases = [
        "PostgreSQL", "Postgres", "MySQL", "MariaDB", "SQLite",
        "MongoDB", "DynamoDB", "Cassandra", "CouchDB",
        "Supabase", "Firebase", "Firestore", "PlanetScale", "Neon",
        "Prisma", "Drizzle", "TypeORM", "Sequelize", "SQLAlchemy",
        "CRUD", "ORM", "migration", "schema", "foreign key", "primary key", "index"
    ]

    // MARK: - Git & Version Control

    static let gitTerms = [
        "git", "GitHub", "GitLab", "Bitbucket",
        "commit", "push", "pull", "merge", "rebase", "cherry-pick",
        "branch", "checkout", "stash", "reset", "revert",
        "pull request", "PR", "merge request", "MR", "code review",
        "git diff", "git log", "git status", "git blame",
        "main", "master", "develop", "feature branch", "hotfix"
    ]

    // MARK: - Programming Concepts

    static let programmingConcepts = [
        "async", "await", "promise", "callback", "closure",
        "function", "method", "class", "struct", "enum", "protocol", "interface",
        "inheritance", "polymorphism", "encapsulation", "abstraction",
        "dependency injection", "singleton", "factory", "observer", "delegate",
        "MVVM", "MVC", "MVP", "VIPER", "clean architecture",
        "unit test", "integration test", "end-to-end", "E2E", "TDD", "BDD",
        "mock", "stub", "spy", "fixture",
        "refactor", "debugging", "breakpoint", "stack trace", "exception",
        "API", "endpoint", "middleware", "webhook", "WebSocket",
        "authentication", "authorization", "OAuth", "JWT", "bearer token",
        "CORS", "CSRF", "XSS", "SQL injection"
    ]

    // MARK: - CLI & Terminal

    static let cliTerms = [
        "terminal", "command line", "shell", "bash", "zsh",
        "npm", "yarn", "pnpm", "bun", "pip", "brew", "Homebrew",
        "curl", "wget", "grep", "sed", "awk", "jq",
        "SSH", "SCP", "rsync", "chmod", "chown", "sudo",
        "environment variable", "dotenv", "PATH"
    ]

    // MARK: - Apple Development

    static let appleDev = [
        "Xcode", "iOS", "macOS", "watchOS", "tvOS", "visionOS",
        "App Store", "TestFlight", "provisioning profile", "code signing",
        "CoreData", "CloudKit", "HealthKit", "StoreKit", "MapKit",
        "UIViewController", "UITableView", "UICollectionView",
        "NavigationStack", "NavigationSplitView", "TabView",
        "@State", "@Binding", "@Observable", "@Published", "@AppStorage",
        "EnvironmentObject", "StateObject", "ObservedObject",
        "SF Symbols", "Human Interface Guidelines", "HIG"
    ]

    // MARK: - Combined Default Vocabulary

    /// All default vocabulary combined (baking + programming)
    static var allTerms: [String] {
        properNouns + processes + ingredients + equipment + characteristics + techniques + science +
        programmingLanguages + aiTerms + devOps + databases + gitTerms + programmingConcepts + cliTerms + appleDev
    }

    /// Default vocabulary as a single string for prompt hints
    static var defaultVocabularyString: String {
        allTerms.joined(separator: ", ")
    }

    // MARK: - User Vocabulary Management

    /// Get the user's custom vocabulary (or default if not set)
    static func getVocabulary() -> String {
        if let custom = UserDefaults.standard.string(forKey: vocabularyKey), !custom.isEmpty {
            return custom
        }
        return defaultVocabularyString
    }

    /// Save custom vocabulary
    static func saveVocabulary(_ vocabulary: String) {
        UserDefaults.standard.set(vocabulary, forKey: vocabularyKey)
    }

    /// Reset to default vocabulary
    static func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: vocabularyKey)
    }

    /// Build a prompt hint combining vocabulary with optional additional context
    static func buildPromptHint(additionalContext: String? = nil) -> String {
        let vocabulary = getVocabulary()

        if let context = additionalContext, !context.isEmpty {
            return "\(context). Terms: \(vocabulary)"
        }

        return "Terms: \(vocabulary)"
    }
}
