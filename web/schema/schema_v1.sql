CREATE TABLE portfolio (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, description TEXT NOT NULL DEFAULT '',
  color TEXT NOT NULL DEFAULT 'violet', archived INTEGER NOT NULL DEFAULT 0, sort REAL NOT NULL DEFAULT 0,
  created_at REAL NOT NULL, updated_at REAL NOT NULL);

CREATE TABLE project (
  id TEXT PRIMARY KEY,
  portfolio_id TEXT REFERENCES portfolio(id) ON DELETE SET NULL,
  name TEXT NOT NULL, description TEXT NOT NULL DEFAULT '', category TEXT NOT NULL DEFAULT '',
  labels TEXT NOT NULL DEFAULT '[]',
  lifecycle TEXT NOT NULL DEFAULT 'idea' CHECK (lifecycle IN ('idea','planned','building','live','maintenance','archived')),
  paused INTEGER NOT NULL DEFAULT 0, priority INTEGER NOT NULL DEFAULT 0,
  favorite INTEGER NOT NULL DEFAULT 0, pinned INTEGER NOT NULL DEFAULT 0,
  start_date REAL, target_date REAL, key TEXT NOT NULL DEFAULT '', next_number INTEGER NOT NULL DEFAULT 1,
  sort REAL NOT NULL DEFAULT 0, wip_limits TEXT NOT NULL DEFAULT '{}',
  created_at REAL NOT NULL, updated_at REAL NOT NULL);
CREATE INDEX project_portfolio ON project(portfolio_id);

CREATE TABLE epic (
  id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
  title TEXT NOT NULL, description TEXT NOT NULL DEFAULT '', start_date REAL, target_date REAL,
  done INTEGER NOT NULL DEFAULT 0, sort REAL NOT NULL DEFAULT 0, created_at REAL NOT NULL, updated_at REAL NOT NULL);
CREATE INDEX epic_project ON epic(project_id);

CREATE TABLE milestone (
  id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
  title TEXT NOT NULL, description TEXT NOT NULL DEFAULT '', target_date REAL, completed_at REAL,
  created_at REAL NOT NULL, updated_at REAL NOT NULL);
CREATE INDEX milestone_project ON milestone(project_id);

CREATE TABLE release (
  id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
  name TEXT NOT NULL, version TEXT NOT NULL DEFAULT '', target_date REAL, released_at REAL,
  notes TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL);
CREATE INDEX release_project ON release(project_id);

CREATE TABLE task (
  id TEXT PRIMARY KEY, number INTEGER NOT NULL,
  project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
  epic_id TEXT REFERENCES epic(id) ON DELETE SET NULL,
  milestone_id TEXT REFERENCES milestone(id) ON DELETE SET NULL,
  parent_id TEXT REFERENCES task(id) ON DELETE CASCADE,
  title TEXT NOT NULL, description TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'backlog' CHECK (status IN ('backlog','ready','in_progress','review','done')),
  position REAL NOT NULL DEFAULT 0, priority INTEGER NOT NULL DEFAULT 0, assignee TEXT NOT NULL DEFAULT '',
  labels TEXT NOT NULL DEFAULT '[]', due_date REAL, blocked INTEGER NOT NULL DEFAULT 0,
  blocked_reason TEXT NOT NULL DEFAULT '', archived INTEGER NOT NULL DEFAULT 0,
  started_at REAL, completed_at REAL, created_at REAL NOT NULL, updated_at REAL NOT NULL,
  UNIQUE (project_id, number));
CREATE INDEX task_board ON task(project_id, status, position);
CREATE INDEX task_due ON task(due_date);
CREATE INDEX task_parent ON task(parent_id);

CREATE TABLE task_checklist (
  id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
  text TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0, position REAL NOT NULL DEFAULT 0);
CREATE INDEX checklist_task ON task_checklist(task_id);

CREATE TABLE task_dependency (
  task_id TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
  depends_on TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
  PRIMARY KEY (task_id, depends_on), CHECK (task_id <> depends_on));

CREATE TABLE resource_link (
  id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
  kind TEXT NOT NULL, ref TEXT NOT NULL, label TEXT NOT NULL DEFAULT '', environment TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT 'manual', created_at REAL NOT NULL,
  UNIQUE (project_id, kind, ref));
CREATE INDEX resource_ref ON resource_link(kind, ref);

CREATE TABLE external_ref (
  id TEXT PRIMARY KEY, entity TEXT NOT NULL, entity_id TEXT NOT NULL,
  system TEXT NOT NULL, external_id TEXT NOT NULL, url TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT '',
  synced_at REAL NOT NULL, UNIQUE (system, external_id));
CREATE INDEX external_entity ON external_ref(entity, entity_id);

CREATE TABLE activity (
  id TEXT PRIMARY KEY, project_id TEXT REFERENCES project(id) ON DELETE CASCADE,
  type TEXT NOT NULL, ts REAL NOT NULL, source TEXT NOT NULL, title TEXT NOT NULL,
  url TEXT NOT NULL DEFAULT '', meta TEXT NOT NULL DEFAULT '{}');
CREATE INDEX activity_project_ts ON activity(project_id, ts);
CREATE INDEX activity_ts ON activity(ts);

CREATE TABLE sync_state (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at REAL NOT NULL);

-- Project discovery decisions (accepted / dismissed suggestions), kept across refreshes.
CREATE TABLE registry_decision (
  candidate TEXT PRIMARY KEY, decision TEXT NOT NULL CHECK (decision IN ('accepted','dismissed')),
  project_id TEXT REFERENCES project(id) ON DELETE SET NULL, updated_at REAL NOT NULL);
