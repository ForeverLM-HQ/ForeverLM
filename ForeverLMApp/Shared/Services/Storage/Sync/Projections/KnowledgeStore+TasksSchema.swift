// MARK: - Schema 162: what the Task, Job and Automation records need (§12.7)

extension KnowledgeStore {
    /// The table schema 162 added (docs/cloudkit-schema-design.md §12.7), created empty, with its columns on
    /// today's tables (a task's board key, an automation's runner, a run's ring slot) in those tables' own
    /// definitions. The generation-2 activation fills the columns (`tasksActivationDerivations`), and from
    /// then on the Task, Job and Automation projections, the upkeep and `MacJobRunner` keep them.
    static let tasksSyncTables: [ReplicaSchemaTable] = [
        // One row per Job record (§3.5.28): work a Mac does for the iPhone, the web or the hosted MCP,
        // claimed by compare-and-set. Private to the member, so no foreign key. Times are Cocoa seconds,
        // as every local table holds them; `params_json`, `requested_by_json`, `claim_json` and
        // `result_json` hold the wire's objects as they are.
        ReplicaSchemaTable("jobs", [
            ("id", "TEXT PRIMARY KEY"),
            ("kind", "TEXT NOT NULL"),
            ("target", "TEXT"),
            ("params_json", "TEXT NOT NULL DEFAULT '{}'"),
            ("requested_by_json", "TEXT"),
            ("requested_at", "REAL"),
            ("claim_json", "TEXT"),
            ("lease_until", "REAL"),
            ("status", "TEXT NOT NULL DEFAULT 'queued'"),
            ("result_json", "TEXT"),
            ("error", "TEXT"),
            ("expires_at", "REAL"),
        ], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_jobs_status ON jobs(status)",
        ]),
    ]

    /// Creates schema 162's table where missing: empty, DDL only.
    func createTasksSyncTables() throws {
        for table in Self.tasksSyncTables {
            try exec(table.createStatement)
            for index in table.indexes {
                try exec(index)
            }
        }
    }

}

// MARK: - The activation's derivations for tasks and automations (§13.3 step 3c)

extension KnowledgeStore {
    /// The derivations for tasks and automations, in order: every notebook's task board keys and a
    /// team's tasks and share requests in `ck_identity`, exactly what the generation-2 upkeep keeps
    /// afterwards; then every automation's runs their ring slots. Each is idempotent, bounded by the
    /// library's tasks and automations (0 of each in production on 2026-10-04), in its own transaction,
    /// and reads generation-1 truth only. No Job is derived: generation 1 has none. An automation's
    /// runner is not derived either: the first Mac to run it under generation 2 takes it
    /// (`scheduledTaskRunsHere`).
    static let tasksActivationDerivations: [ActivationDerivation] = [
        ActivationDerivation(id: "taskRows") { store in try store.inDerivationTransaction { try $0.deriveTaskRows() } },
        ActivationDerivation(id: "automationRings") { store in try store.inDerivationTransaction { try $0.deriveAutomationRings() } },
    ]

    func deriveTaskRows() throws {
        var notebooks: [String] = []
        try query("SELECT DISTINCT notebook_id FROM notebook_tasks ORDER BY notebook_id", []) { row in
            if let id = row.text(0) { notebooks.append(id) }
        }
        for notebook in notebooks {
            try TaskUpkeep.replanBoard(notebookID: notebook, connection: self)
        }
        try TaskUpkeep.recordTeamIdentities(teamZones: try teamZoneKeys(), connection: self)
    }

    func deriveAutomationRings() throws {
        var tasks: [String] = []
        try query("SELECT DISTINCT task_id FROM scheduled_task_runs ORDER BY task_id", []) { row in
            if let id = row.text(0) { tasks.append(id) }
        }
        for task in tasks {
            try AutomationRing.assignSlots(taskID: task, connection: self)
        }
    }
}
