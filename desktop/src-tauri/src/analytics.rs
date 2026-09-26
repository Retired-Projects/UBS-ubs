//! 앱 계측 전송 (analytics-core 규격, 앱 슬러그 `ubs-desktop`, `utility_recurring`).
//!
//! 프론트에 posthog-js 를 넣지 않고 Rust 에서 보낸다(`analytics-core/docs/integration-tauri.md`).
//! 이벤트 이름은 `analytics-core/docs/event-taxonomy.md` 에 있는 것만 쓴다.
//!
//! | 칸 | 이벤트 |
//! |---|---|
//! | 라이프사이클 | `Application Installed`(첫 실행) · `Application Updated`(버전 바뀐 첫 실행) · `Application Opened`(콜드 스타트) |
//! | ① 화면 | `$screen` — UI 상태가 바뀔 때 [`SCREENS`] 중 하나 |
//! | ② 활성화 | `user activated`(`trigger: first_build`) — 첫 빌드 성공, 설치당 한 번 |
//! | ③ 도메인 | 빌드 `action performed`(시작) → `item created`(성공) / `action failed`(실패·취소) · 폴더 감지 `search performed` · 산출물 열기 `item viewed` |
//! | ④ 맥락 | `ctx_screen` · `ctx_task` · `ctx_project_type` |
//! | 오류 | `$exception` — Rust 패닉(동기 전송) · 프론트 JS 오류 |
//!
//! **개인정보·경로를 싣지 않는다.** 프로젝트 경로·이름은 어떤 속성에도 들어가지 않고,
//! 오류 메시지는 [`scrub`] 로 경로를 지운 뒤 자른다.
//!
//! **전송 실패는 조용히 무시한다** — 계측이 빌드 동작에 영향을 주면 안 된다.

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager};
use time::{format_description::well_known::Rfc3339, OffsetDateTime};

/// build.rs 가 `.env` 에서 주입한다. 없으면 계측 자체가 꺼진다(빌드 경고로 드러난다).
const TOKEN: Option<&str> = option_env!("UBS_ANALYTICS_TOKEN");
const HOST: &str = match option_env!("UBS_ANALYTICS_HOST") {
    Some(host) => host,
    None => "https://analytics.sanglimsoft.com",
};

/// 화면 이름(경로 꼴). 라우트가 없는 단일 창이라 UI 상태가 곧 화면이다.
pub const SCREENS: &[&str] = &[
    "/welcome",        // 프로젝트 없음
    "/project/choose", // 감지된 프로젝트가 여럿이라 고르는 중
    "/project",        // 프로젝트 선택·옵션 설정
    "/build",          // 빌드 실행 중
    "/build/result",   // 빌드 결과 표시
];

/// UBS `detect` 가 돌려주는 프로젝트 종류. 밖의 값은 `other` 로 묶는다.
const PROJECT_TYPES: &[&str] = &[
    "flutter",
    "tauri",
    "android",
    "gradle",
    "ios-xcode",
    "react",
    "next",
    "node",
    "godot",
];
const OUTPUTS: &[&str] = &["appbundle", "apk", "ipa", "web", "pkg"];

const STATE_FILE: &str = "analytics.json";
const BATCH_MAX: usize = 20;
const MESSAGE_MAX: usize = 300;

struct Client {
    distinct_id: String,
    session_id: String,
    app_version: String,
    state_path: PathBuf,
    sender: Sender<Value>,
}

static CLIENT: OnceLock<Client> = OnceLock::new();
/// super property. 모든 이벤트(패닉 포함)에 `ctx_*` 로 붙는다. 메모리에만 두므로 재시작하면 비어 있다.
static CONTEXT: Mutex<Vec<(&'static str, String)>> = Mutex::new(Vec::new());
static STATE_LOCK: Mutex<()> = Mutex::new(());
static PENDING: AtomicUsize = AtomicUsize::new(0);

#[derive(Default, Deserialize, Serialize)]
struct Stored {
    distinct_id: String,
    #[serde(default)]
    activated: bool,
    #[serde(default)]
    version: String,
}

/// 앱 시작 때 한 번. 설치 id 를 읽거나 만들고 라이프사이클 이벤트를 보낸다.
pub fn init(app: &AppHandle) {
    let Some(token) = TOKEN else {
        eprintln!("[analytics] ANALYTICS_TOKEN 없이 빌드됨 — 계측 꺼짐");
        return;
    };
    let Ok(dir) = app.path().app_data_dir() else {
        return;
    };
    let state_path = dir.join(STATE_FILE);
    let previous = read_state(&state_path);
    let fresh = previous.is_none();
    let mut stored = previous.unwrap_or_else(|| Stored {
        distinct_id: uuid::Uuid::new_v4().to_string(),
        ..Stored::default()
    });
    let app_version = app.package_info().version.to_string();
    let updated_from = (!fresh && stored.version != app_version).then(|| stored.version.clone());
    stored.version = app_version.clone();
    // id 를 저장하지 못하면 실행마다 새 유저로 세어진다 — 그럴 바엔 끈다.
    if std::fs::create_dir_all(&dir).is_err() || write_state(&state_path, &stored).is_err() {
        return;
    }

    let (sender, receiver) = mpsc::channel();
    let url = format!("{}/batch/", HOST.trim_end_matches('/'));
    thread::spawn(move || send_loop(receiver, &url, token));
    let client = Client {
        distinct_id: stored.distinct_id,
        session_id: uuid::Uuid::new_v4().to_string(),
        app_version,
        state_path,
        sender,
    };
    if CLIENT.set(client).is_err() {
        return;
    }
    install_panic_hook(token);

    if fresh {
        capture("Application Installed", json!({}));
    } else if let Some(previous_version) = updated_from {
        capture(
            "Application Updated",
            json!({ "previous_version": previous_version }),
        );
    }
    capture("Application Opened", json!({}));
}

/// 보낼 이벤트를 큐에 넣는다. 전송은 백그라운드 스레드가 한다.
pub fn capture(event: &str, props: Value) {
    let Some(client) = CLIENT.get() else {
        return;
    };
    let item = client.item(event, props);
    if cfg!(debug_assertions) {
        eprintln!("[analytics] {event} {}", item["properties"]);
    }
    PENDING.fetch_add(1, Ordering::SeqCst);
    if client.sender.send(item).is_err() {
        PENDING.fetch_sub(1, Ordering::SeqCst);
    }
}

/// 종료 직전 큐를 비운다. 빌드 결과 직후 창을 닫으면 결과 이벤트가 유실되던 자리.
pub fn flush(timeout: Duration) {
    let started = Instant::now();
    while PENDING.load(Ordering::SeqCst) > 0 && started.elapsed() < timeout {
        thread::sleep(Duration::from_millis(50));
    }
}

/// 화면 전환. 허용 목록 밖의 이름과 직전과 같은 화면은 보내지 않는다.
pub fn screen(name: &str) {
    let Some(name) = SCREENS.iter().find(|screen| **screen == name) else {
        return;
    };
    if context_value("ctx_screen").as_deref() == Some(*name) {
        return;
    }
    set_context("ctx_screen", Some(*name));
    capture("$screen", json!({ "$screen_name": name }));
}

/// 프론트에서 오는 조작·오류. 허용 목록 밖의 action 은 버린다.
pub fn ui_event(action: &str, detail: Option<&str>) {
    match action {
        "locale_changed" => capture("settings changed", json!({ "key": "locale" })),
        "log_copied" => capture("content shared", json!({ "kind": "build_log" })),
        "js_error" | "js_rejection" => capture(
            "$exception",
            json!({
                "$exception_type": if action == "js_error" { "JsError" } else { "UnhandledRejection" },
                "$exception_message": scrub(detail.unwrap_or_default()),
                "$exception_source": "ui",
            }),
        ),
        _ => {}
    }
}

pub fn set_context(key: &'static str, value: Option<&str>) {
    let Ok(mut context) = CONTEXT.lock() else {
        return;
    };
    context.retain(|(existing, _)| *existing != key);
    if let Some(value) = value {
        context.push((key, value.to_string()));
    }
}

fn context_value(key: &str) -> Option<String> {
    CONTEXT
        .lock()
        .ok()?
        .iter()
        .find(|(existing, _)| *existing == key)
        .map(|(_, value)| value.clone())
}

/// 설치당 한 번만 보낸다. 저장에 실패하면 다음 실행에 또 보내 부풀므로 보내지 않는다.
fn activated_once(trigger: &str) {
    let Some(client) = CLIENT.get() else {
        return;
    };
    let Ok(_guard) = STATE_LOCK.lock() else {
        return;
    };
    let Some(mut stored) = read_state(&client.state_path) else {
        return;
    };
    if stored.activated {
        return;
    }
    stored.activated = true;
    if write_state(&client.state_path, &stored).is_ok() {
        capture("user activated", json!({ "trigger": trigger }));
    }
}

// ── 도메인: 폴더 감지 ────────────────────────────────────────────────

pub fn detect_started() {
    set_context("ctx_task", Some("detect"));
}

/// `count` 는 감지된 프로젝트 수. 실패는 `reason` 코드로만 남긴다(메시지·경로 없음).
pub fn detect_finished(result: Result<usize, &'static str>) {
    set_context("ctx_task", None);
    match result {
        Ok(count) => capture(
            "search performed",
            json!({ "type": "detect", "has_result": count > 0, "count": count }),
        ),
        Err(reason) => capture(
            "action failed",
            json!({ "type": "detect", "reason": reason }),
        ),
    }
}

// ── 도메인: 빌드 ────────────────────────────────────────────────────

pub struct BuildTrack {
    started: Instant,
    project_type: &'static str,
}

pub enum BuildOutcome {
    Success { artifacts: usize },
    Failed { exit_code: Option<i32> },
    Cancelled,
    Error,
}

pub fn project_type(raw: Option<&str>) -> &'static str {
    raw.and_then(|raw| PROJECT_TYPES.iter().find(|kind| **kind == raw))
        .copied()
        .unwrap_or("other")
}

/// 빌드가 시작되기도 전에 거절된 요청(검증 실패·이미 실행 중). 시작 짝이 없으므로 type 을 가른다.
pub fn build_rejected(reason: &'static str) {
    capture(
        "action failed",
        json!({ "type": "build_request", "reason": reason }),
    );
}

pub fn build_started(
    project_type: &'static str,
    outputs: &[String],
    version_bump: &str,
    jobs: u8,
    clean: bool,
) -> BuildTrack {
    set_context("ctx_task", Some("build"));
    set_context("ctx_project_type", Some(project_type));
    let outputs: Vec<&str> = outputs
        .iter()
        .filter_map(|output| OUTPUTS.iter().find(|known| **known == output).copied())
        .collect();
    capture(
        "action performed",
        json!({
            "type": "build",
            "project_type": project_type,
            "outputs": outputs.join(","),
            "version_bump": version_bump,
            "jobs": jobs,
            "clean": clean,
        }),
    );
    BuildTrack {
        started: Instant::now(),
        project_type,
    }
}

pub fn build_finished(track: BuildTrack, outcome: BuildOutcome) {
    let duration_sec = track.started.elapsed().as_secs();
    let project_type = track.project_type;
    match outcome {
        BuildOutcome::Success { artifacts } => {
            capture(
                "item created",
                json!({
                    "type": "build",
                    "project_type": project_type,
                    "duration_sec": duration_sec,
                    "artifact_count": artifacts,
                }),
            );
            activated_once("first_build");
        }
        other => {
            let reason = match other {
                BuildOutcome::Failed {
                    exit_code: Some(code),
                } => format!("exit_{code}"),
                BuildOutcome::Failed { exit_code: None } => "signal".to_string(),
                BuildOutcome::Cancelled => "cancelled".to_string(),
                _ => "internal".to_string(),
            };
            capture(
                "action failed",
                json!({
                    "type": "build",
                    "reason": reason,
                    "project_type": project_type,
                    "duration_sec": duration_sec,
                }),
            );
        }
    }
    set_context("ctx_task", None);
    set_context("ctx_project_type", None);
}

/// UBS `--report-json` 의 산출물 수. 경로는 세기만 하고 싣지 않는다.
pub fn artifact_count(report: Option<&Value>) -> usize {
    report
        .and_then(|report| report.get("results"))
        .and_then(Value::as_array)
        .map(|results| {
            results
                .iter()
                .filter_map(|result| result.get("artifacts").and_then(Value::as_array))
                .map(Vec::len)
                .sum()
        })
        .unwrap_or(0)
}

// ── 도메인: 산출물 열기 ──────────────────────────────────────────────

pub fn artifact_opened(ok: bool) {
    if ok {
        capture("item viewed", json!({ "type": "artifact" }));
    } else {
        capture(
            "action failed",
            json!({ "type": "open_artifact", "reason": "open_error" }),
        );
    }
}

// ── 전송 ───────────────────────────────────────────────────────────

impl Client {
    fn item(&self, event: &str, props: Value) -> Value {
        let mut properties = match props {
            Value::Object(map) => map,
            _ => Map::new(),
        };
        self.common(&mut properties, CONTEXT.lock().ok().map(|c| c.clone()));
        json!({
            "event": event,
            "distinct_id": self.distinct_id,
            "timestamp": now(),
            "properties": properties,
        })
    }

    fn common(
        &self,
        properties: &mut Map<String, Value>,
        context: Option<Vec<(&'static str, String)>>,
    ) {
        properties.insert("$app_version".into(), json!(self.app_version));
        properties.insert("$os".into(), json!(os_name()));
        properties.insert("$lib".into(), json!("ubs-desktop-rust"));
        properties.insert("$device_type".into(), json!("Desktop"));
        properties.insert("$session_id".into(), json!(self.session_id));
        if cfg!(debug_assertions) {
            // 개발 실행. 수신 서버가 버리고 ingest_verdicts 에 사유만 남긴다(analysis/filters.py).
            properties.insert("is_debug".into(), json!(true));
        }
        for (key, value) in context.unwrap_or_default() {
            properties.insert(key.into(), json!(value));
        }
    }
}

fn send_loop(receiver: Receiver<Value>, url: &str, token: &str) {
    let agent = agent();
    while let Ok(first) = receiver.recv() {
        let mut batch = vec![first];
        while batch.len() < BATCH_MAX {
            match receiver.try_recv() {
                Ok(item) => batch.push(item),
                Err(_) => break,
            }
        }
        let count = batch.len();
        // 실패해도 재시도하지 않는다. 다음 실행의 Application Opened 가 다시 잡힌다.
        post(&agent, url, token, batch);
        PENDING.fetch_sub(count, Ordering::SeqCst);
    }
}

/// `ureq::post()` 전역 헬퍼는 https 에서 패닉한다(provider 미설정) —
/// provider 를 명시한 agent 를 쓴다(known-issues `ureq-global-helper-tls-provider-panic`).
fn agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(10)))
        .tls_config(
            ureq::tls::TlsConfig::builder()
                .provider(ureq::tls::TlsProvider::NativeTls)
                .build(),
        )
        .build()
        .into()
}

fn post(agent: &ureq::Agent, url: &str, token: &str, batch: Vec<Value>) {
    let body = json!({ "api_key": token, "batch": batch });
    let _ = agent.post(url).send_json(&body);
}

/// Rust 패닉을 `$exception` 으로 보낸다.
///
/// ⚠️ 패닉 경로는 큐를 거치지 않고 **동기로 즉시** 보낸다 — 릴리스는 `panic = "abort"` 라
/// 훅이 끝나면 프로세스가 바로 죽는다. 훅 안에서 또 패닉하면 abort 이므로 통째로 감싼다.
fn install_panic_hook(token: &'static str) {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let Some(client) = CLIENT.get() else {
                return;
            };
            let message = info
                .payload()
                .downcast_ref::<&str>()
                .map(|message| (*message).to_string())
                .or_else(|| info.payload().downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "panic".to_string());
            let source = info
                .location()
                .map(|location| format!("{}:{}", location.file(), location.line()))
                .unwrap_or_default();
            let mut properties = Map::new();
            properties.insert("$exception_type".into(), json!("RustPanic"));
            properties.insert("$exception_message".into(), json!(scrub(&message)));
            properties.insert("$exception_source".into(), json!(scrub(&source)));
            // 패닉한 스레드가 CONTEXT 를 쥐고 있을 수 있다 — 기다리지 않는다.
            let context = CONTEXT.try_lock().ok().map(|context| context.clone());
            client.common(&mut properties, context);
            let item = json!({
                "event": "$exception",
                "distinct_id": client.distinct_id,
                "timestamp": now(),
                "properties": properties,
            });
            let url = format!("{}/batch/", HOST.trim_end_matches('/'));
            post(&agent(), &url, token, vec![item]);
        }));
        previous(info);
    }));
}

// ── 보조 ───────────────────────────────────────────────────────────

/// 사용자 경로를 지우고 길이를 자른다. 오류 메시지에 홈·프로젝트 경로가 섞여 들어온다.
pub fn scrub(raw: &str) -> String {
    let cleaned = raw
        .split_whitespace()
        .map(|token| {
            let bare = token.trim_matches(|c: char| "\"'`()[]{}<>,;".contains(c));
            let looks_like_path = bare.starts_with('/')
                || bare.starts_with("~/")
                || bare.starts_with("file:")
                || bare.contains(":\\")
                || bare.contains("/Users/")
                || bare.contains("/home/")
                || bare.contains("/Volumes/")
                || bare.contains("/private/");
            if looks_like_path {
                "<path>"
            } else {
                token
            }
        })
        .collect::<Vec<_>>()
        .join(" ");
    cleaned.chars().take(MESSAGE_MAX).collect()
}

fn os_name() -> &'static str {
    match std::env::consts::OS {
        "macos" => "macOS",
        "windows" => "Windows",
        "linux" => "Linux",
        other => other,
    }
}

fn now() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_default()
}

fn read_state(path: &Path) -> Option<Stored> {
    let bytes = std::fs::read(path).ok()?;
    serde_json::from_slice::<Stored>(&bytes)
        .ok()
        .filter(|stored| !stored.distinct_id.is_empty())
}

fn write_state(path: &Path, stored: &Stored) -> std::io::Result<()> {
    let bytes = serde_json::to_vec(stored).map_err(std::io::Error::other)?;
    let temporary = path.with_extension("json.tmp");
    std::fs::write(&temporary, bytes)?;
    std::fs::rename(temporary, path)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 전송 경로가 실제로 도는지 본다. 컴파일만 통과하고 런타임에 죽는 일이 이미 있었다
    /// (ureq provider 미설정). 닫힌 포트로 보내 실패를 유도해도 패닉하면 안 된다.
    #[test]
    fn post_path_does_not_panic() {
        post(
            &agent(),
            "https://127.0.0.1:9/batch/",
            "test-token",
            vec![json!({ "event": "$exception", "distinct_id": "test" })],
        );
    }

    #[test]
    fn scrub_removes_user_paths_and_truncates() {
        let message =
            scrub("failed to open /Users/kim/secret-app/pubspec.yaml: denied (\"/Volumes/x\")");
        assert!(!message.contains("kim"));
        assert!(!message.contains("secret-app"));
        assert!(!message.contains("Volumes"));
        assert!(message.contains("<path>"));
        assert!(message.starts_with("failed to open"));
        assert!(scrub(&"a".repeat(1000)).chars().count() <= MESSAGE_MAX);
        assert_eq!(scrub("C:\\Users\\kim\\app boom"), "<path> boom");
    }

    #[test]
    fn unknown_values_collapse_to_allow_list() {
        assert_eq!(project_type(Some("flutter")), "flutter");
        assert_eq!(project_type(Some("/Users/kim/app")), "other");
        assert_eq!(project_type(None), "other");
        assert!(SCREENS.iter().all(|screen| screen.starts_with('/')));
    }

    #[test]
    fn artifact_count_sums_report_results() {
        let report = json!({ "results": [
            { "artifacts": ["/a.ipa", "/b.aab"] },
            { "artifacts": [] },
            { "status": "skipped" }
        ]});
        assert_eq!(artifact_count(Some(&report)), 2);
        assert_eq!(artifact_count(None), 0);
    }

    #[test]
    fn state_round_trips_and_rejects_empty_id() {
        let dir = std::env::temp_dir().join(format!("ubs-analytics-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(STATE_FILE);
        write_state(
            &path,
            &Stored {
                distinct_id: "id-1".into(),
                activated: true,
                version: "1.0.0".into(),
            },
        )
        .unwrap();
        let stored = read_state(&path).unwrap();
        assert_eq!(stored.distinct_id, "id-1");
        assert!(stored.activated);
        std::fs::write(&path, br#"{"distinct_id":""}"#).unwrap();
        assert!(read_state(&path).is_none());
        let _ = std::fs::remove_dir_all(dir);
    }
}
