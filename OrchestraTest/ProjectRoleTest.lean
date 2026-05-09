import OrchestraTest.TestM
import Orchestra

open Lean (Json FromJson ToJson)
open Orchestra
open Orchestra.Project
open Orchestra.Listener

namespace OrchestraTest.ProjectRole

private def withTempHome (act : IO α) : IO α := do
  let tmpRoot : System.FilePath :=
    System.FilePath.mk "/tmp" / s!"orchestra-role-test-{← IO.monoNanosNow}"
  let projectsRoot := tmpRoot / "projects"
  let globalRoles  := tmpRoot / "global-roles"
  IO.FS.createDirAll projectsRoot
  IO.FS.createDirAll globalRoles
  setProjectsDirOverride (some projectsRoot)
  setGlobalRolesDirOverride (some globalRoles)
  try act
  finally
    setProjectsDirOverride none
    setGlobalRolesDirOverride none

private def writeRole (dir : System.FilePath) (name : String) (json : String) : IO Unit := do
  IO.FS.createDirAll dir
  IO.FS.writeFile (dir / s!"{name}.json") json

private def setupProject (defaultTarget : Option RepoTarget := none) : IO Project := do
  let pid ← freshProjectId
  let now ← TaskStore.currentIso8601
  let p : Project := { id := pid, name := "demo", createdAt := now, defaultTarget }
  saveProject p
  return p

private def addIssue (pid : ProjectId) (status : IssueStatus := .open) (title : String := "i") :
    IO Issue := do
  let now ← TaskStore.currentIso8601
  let iid ← freshIssueId
  let i : Issue :=
    { id := iid, projectId := pid, title, description := "x", status
    , target := some { repo := { owner := "o", name := "r" }, branch := "main" }
    , createdAt := now, updatedAt := now }
  saveIssue i
  return i

@[test]
def renderSubstitutesPlaceholders : Test := do
  let v : RenderVars :=
    { projectId := "p1", projectName := "API",
      instructions := "go", issueId := some "i1",
      issueTitle := some "do x",
      targetRepo := some "o/r", targetBranch := some "main" }
  let out := render
    "[{{project_name}} / {{issue_id}}] {{issue_title}} on {{target_repo}}@{{target_branch}}: {{instructions}}"
    v
  TestM.assertEqual out "[API / i1] do x on o/r@main: go" (msg := "render substitution")

@[test]
def projectRoleOverridesGlobal : Test := do
  let outcome ← (withTempHome do
    let project ← setupProject
    let global ← globalRolesDir
    writeRole global "worker" r#"{"name":"worker","permissions":["a"],"prompt_template":"GLOBAL"}"#
    let pdir ← projectRolesDir project.id
    writeRole pdir "worker" r#"{"name":"worker","permissions":["a","b"],"prompt_template":"PROJECT"}"#
    let r ← loadRole project.id "worker"
    return r.map (fun r => (r.promptTemplate, r.permissions)))
  TestM.assertEqual outcome (some ("PROJECT", ["a","b"])) (msg := "project file wins")

@[test]
def loadAllRolesMergesGlobalsThatArentShadowed : Test := do
  let names ← (withTempHome do
    let project ← setupProject
    let global ← globalRolesDir
    let pdir ← projectRolesDir project.id
    writeRole global "planner"  r#"{"name":"planner","permissions":["manage_issues"],"prompt_template":"P"}"#
    writeRole global "reviewer" r#"{"name":"reviewer","permissions":["review_issues"],"prompt_template":"R"}"#
    -- Project shadows planner with a different impl, leaves reviewer untouched.
    writeRole pdir   "planner"  r#"{"name":"planner","permissions":["manage_issues","comment"],"prompt_template":"PP"}"#
    let rs ← loadAllRoles project.id
    return (rs.map (·.name)).qsort (· < ·))
  TestM.assertEqual names #["planner", "reviewer"] (msg := "merged set")

@[test]
def dispatcherSpawnsWorkerWhenOpenIssueAndCapAllows : Test := do
  let result ← (withTempHome do
    let project ← setupProject
    let _i := ← addIssue project.id (status := .open) (title := "do it")
    let role : Role :=
      { name := "implementor", permissions := ["work_issues", "create_pr"]
      , promptTemplate := "implement"
      , dispatch := some { trigger := .hasOpenIssues, max := 1, preClaim := true } }
    return dispatcherTick
      { activeByRole := {}
      , issues := ← loadIssues project.id
      , caps := [("implementor", 2)]
      , roles := #[role] })
  TestM.assertEqual result.size 1 (msg := "exactly one spawn")
  match result[0]? with
  | some s =>
    TestM.assertEqual s.roleName "implementor" (msg := "role name")
    TestM.assert s.issueId.isSome  "spawn must bind to an issue"
  | none => TestM.fail "expected one spawn"

@[test]
def dispatcherRespectsCap : Test := do
  let count ← (withTempHome do
    let project ← setupProject
    let _ := ← addIssue project.id .open
    let _ := ← addIssue project.id .open
    let role : Role :=
      { name := "implementor", permissions := []
      , promptTemplate := "x"
      , dispatch := some { trigger := .hasOpenIssues, max := 5 } }
    let active : Std.HashMap String Nat := ({} : Std.HashMap String Nat).insert "implementor" 2
    return (dispatcherTick
      { activeByRole := active
      , issues := ← loadIssues project.id
      , caps := [("implementor", 2)]
      , roles := #[role] }).size)
  TestM.assertEqual count 0 (msg := "active==cap blocks spawn")

@[test]
def dispatcherIdleTriggerOnlyWhenNoWork : Test := do
  let (idleEmpty, idleWithOpen) ← (withTempHome do
    let project ← setupProject
    let role : Role :=
      { name := "planner", permissions := ["manage_issues"]
      , promptTemplate := "plan"
      , dispatch := some { trigger := .idle, max := 1 } }
    let emptyIssues : Array Issue := #[]
    let resEmpty := dispatcherTick
      { activeByRole := {}, issues := emptyIssues
      , caps := [("planner", 1)], roles := #[role] }
    let _ := ← addIssue project.id .open
    let resWithOpen := dispatcherTick
      { activeByRole := {}, issues := ← loadIssues project.id
      , caps := [("planner", 1)], roles := #[role] }
    return (resEmpty.size, resWithOpen.size))
  TestM.assertEqual idleEmpty 1     (msg := "idle role spawns when no work")
  TestM.assertEqual idleWithOpen 0  (msg := "idle role suppressed when open issues exist")

@[test]
def dispatcherEmitsAtMostOnePerRolePerTick : Test := do
  let count ← (withTempHome do
    let project ← setupProject
    let _ := ← addIssue project.id .open
    let _ := ← addIssue project.id .open
    let _ := ← addIssue project.id .open
    let role : Role :=
      { name := "implementor", permissions := []
      , promptTemplate := "x"
      , dispatch := some { trigger := .hasOpenIssues, max := 10 } }
    return (dispatcherTick
      { activeByRole := {}, issues := ← loadIssues project.id
      , caps := [("implementor", 10)], roles := #[role] }).size)
  TestM.assertEqual count 1 (msg := "≤1 spawn per role per tick (gradual ramp)")

end OrchestraTest.ProjectRole
