import Foundation

// Portfolio & project-management records (persisted in workspace.sqlite).

enum Lifecycle: String, CaseIterable, Codable, Identifiable {
    case idea, planned, building, live, maintenance, archived
    var id: String { rawValue }
    var title: String {
        switch self {
        case .idea: "Idea"
        case .planned: "Planned"
        case .building: "Building"
        case .live: "Live"
        case .maintenance: "Maintenance"
        case .archived: "Archived"
        }
    }
    var icon: String {
        switch self {
        case .idea: "lightbulb"
        case .planned: "calendar"
        case .building: "hammer"
        case .live: "dot.radiowaves.left.and.right"
        case .maintenance: "wrench.and.screwdriver"
        case .archived: "archivebox"
        }
    }
}

enum TaskStatus: String, CaseIterable, Codable, Identifiable {
    case backlog, ready, inProgress = "in_progress", review, done
    var id: String { rawValue }
    var title: String {
        switch self {
        case .backlog: "Backlog"
        case .ready: "Ready"
        case .inProgress: "In Progress"
        case .review: "Review"
        case .done: "Done"
        }
    }
    var isOpen: Bool { self != .done }
}

enum Priority: Int, CaseIterable, Codable, Identifiable {
    case none = 0, low, medium, high, urgent
    var id: Int { rawValue }
    var title: String { ["Tanpa", "Low", "Medium", "High", "Urgent"][rawValue] }
}

struct Portfolio: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var description: String = ""
    var color: String = "violet"
    var archived = false
    var sort: Double = 0
    var createdAt = Date()
    var updatedAt = Date()
}

struct Project: Identifiable, Codable, Hashable {
    var id: String
    var portfolioId: String?
    var name: String
    var description: String = ""
    var category: String = ""
    var labels: [String] = []
    var lifecycle: Lifecycle = .idea
    var paused = false
    var priority: Priority = .none
    var favorite = false
    var pinned = false
    var startDate: Date?
    var targetDate: Date?
    var key: String = ""                  // short task prefix, e.g. "ALT"
    var nextNumber = 1
    var sort: Double = 0
    var wipLimits: [String: Int] = [:]    // status rawValue → limit
    var createdAt = Date()
    var updatedAt = Date()
}

struct Epic: Identifiable, Codable, Hashable {
    var id: String
    var projectId: String
    var title: String
    var description: String = ""
    var startDate: Date?
    var targetDate: Date?
    var done = false
    var sort: Double = 0
    var createdAt = Date()
    var updatedAt = Date()
}

struct Milestone: Identifiable, Codable, Hashable {
    var id: String
    var projectId: String
    var title: String
    var description: String = ""
    var targetDate: Date?
    var completedAt: Date?
    var createdAt = Date()
    var updatedAt = Date()
}

struct Release: Identifiable, Codable, Hashable {
    var id: String
    var projectId: String
    var name: String
    var version: String = ""
    var targetDate: Date?
    var releasedAt: Date?
    var notes: String = ""
    var createdAt = Date()
}

struct WTask: Identifiable, Codable, Hashable {
    var id: String
    var number: Int
    var projectId: String
    var epicId: String?
    var milestoneId: String?
    var parentId: String?
    var title: String
    var description: String = ""
    var status: TaskStatus = .backlog
    var position: Double = 0
    var priority: Priority = .none
    var assignee: String = ""
    var labels: [String] = []
    var dueDate: Date?
    var blocked = false
    var blockedReason: String = ""
    var archived = false
    var startedAt: Date?
    var completedAt: Date?
    var createdAt = Date()
    var updatedAt = Date()

    func isOverdue(_ now: Date = Date()) -> Bool {
        guard let d = dueDate, status != .done, !archived else { return false }
        return d < Calendar.current.startOfDay(for: now)
    }
}

struct ChecklistItem: Identifiable, Codable, Hashable {
    var id: String
    var taskId: String
    var text: String
    var done = false
    var position: Double = 0
}

struct TaskDependency: Codable, Hashable {
    var taskId: String        // this task…
    var dependsOn: String     // …waits for this one
}

/// A resource a project uses: repo, domain, server node, compose project, service, Vercel project…
struct ResourceLink: Identifiable, Codable, Hashable {
    enum Kind: String, CaseIterable, Codable {
        case repo, local, domain, node, compose, service, vercel, n8n, app, githubProject, job
        var title: String {
            switch self {
            case .repo: "Repository"
            case .local: "Folder lokal"
            case .domain: "Domain"
            case .node: "Server"
            case .compose: "Docker compose"
            case .service: "Service"
            case .vercel: "Vercel"
            case .n8n: "n8n"
            case .app: "Aplikasi (Monitor)"
            case .githubProject: "GitHub Project"
            case .job: "Cron / job"
            }
        }
        var icon: String {
            switch self {
            case .repo: "chevron.left.forwardslash.chevron.right"
            case .local: "laptopcomputer"
            case .domain: "globe"
            case .node: "server.rack"
            case .compose: "shippingbox"
            case .service: "gearshape.2"
            case .vercel: "triangle"
            case .n8n: "point.3.filled.connected.trianglepath.dotted"
            case .app: "square.stack.3d.up"
            case .githubProject: "rectangle.split.3x1"
            case .job: "clock"
            }
        }
    }
    var id: String
    var projectId: String
    var kind: Kind
    var ref: String                       // owner/name, host, node id, app id, path, project id…
    var label: String = ""
    var environment: String = ""          // production, staging, development
    var source: String = "manual"         // manual, discovery
    var createdAt = Date()
}

/// A local record mirrored from an external system (GitHub issue → task, milestone…).
struct ExternalRef: Identifiable, Codable, Hashable {
    var id: String
    var entity: String                    // task, milestone
    var entityId: String
    var system: String                    // github
    var externalId: String                // "owner/repo#12", "PVTI_…"
    var url: String = ""
    var state: String = ""                // last remote state seen
    var syncedAt = Date()
}

struct ActivityEvent: Identifiable, Codable, Hashable {
    var id: String                        // stable: local UUID or "<source>:<kind>:<external id>"
    var projectId: String?
    var type: String                      // task.created, task.status, github.commit, ci.failed, site.down…
    var ts: Date
    var source: String                    // raphael, github, vercel, monitor, hermes
    var title: String
    var url: String = ""
    var meta: [String: String] = [:]
}

extension WTask {
    /// "ALT-12"
    func code(_ project: Project?) -> String {
        let k = project?.key.isEmpty == false ? project!.key : "T"
        return "\(k)-\(number)"
    }
}
