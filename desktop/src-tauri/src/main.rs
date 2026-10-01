#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::VecDeque;
use std::fs;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager, State};

mod analytics;

const MAX_CAPTURED_BYTES: usize = 1024 * 1024;
const NO_PROJECTS_MESSAGE: &str = "빌드 가능한 프로젝트를 찾지 못했습니다.";

#[derive(Default)]
struct ProcessSlot {
    active: bool,
    cancelled: bool,
    child: Option<Child>,
}

#[derive(Clone, Default)]
struct BuildState(Arc<Mutex<ProcessSlot>>);

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BuildRequest {
    project: String,
    version_bump: String,
    outputs: Vec<String>,
    jobs: u8,
    clean: bool,
    locale: String,
    /// 계측 전용(허용 목록으로 좁힌 뒤 `project_type` 만 싣는다). 빌드 명령에는 안 쓴다.
    #[serde(default)]
    project_type: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
struct BuildLog {
    stream: &'static str,
    line: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct BuildResult {
    success: bool,
    cancelled: bool,
    exit_code: Option<i32>,
    stdout: String,
    stderr: String,
    report: Option<Value>,
}

#[derive(Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct VersionPoint {
    version: String,
    build: String,
}

#[derive(Debug, PartialEq, Serialize)]
struct VersionPreview {
    current: VersionPoint,
    next: VersionPoint,
}

#[derive(Debug)]
struct PreparedBuild {
    runtime_root: PathBuf,
    project: PathBuf,
    version_bump: String,
    outputs: Vec<String>,
    jobs: u8,
    clean: bool,
    locale: String,
    report_path: PathBuf,
}

#[tauri::command]
async fn detect_projects(app: AppHandle, root: String) -> Result<Value, String> {
    analytics::detect_started();
    let result = detect_projects_inner(app, root).await;
    analytics::detect_finished(match &result {
        Ok(value) => Ok(value.as_array().map_or(0, Vec::len)),
        Err(message) if message == NO_PROJECTS_MESSAGE => Err("no_project"),
        Err(_) => Err("detect_error"),
    });
    result
}

async fn detect_projects_inner(app: AppHandle, root: String) -> Result<Value, String> {
    let root = canonical_directory(&root)?;
    let runtime_root = runtime_root(&app)?;
    tauri::async_runtime::spawn_blocking(move || {
        let mut command = ubs_command(&runtime_root)?;
        command.args(["detect", "--json"]).arg(&root);
        let output = command
            .output()
            .map_err(|error| format!("UBS detect 실행 실패: {error}"))?;
        let stdout = String::from_utf8_lossy(&output.stdout);
        if let Ok(value) = serde_json::from_str::<Value>(&stdout) {
            install_missing_ubs(&runtime_root, &root, &value)?;
            return Ok(value);
        }
        let stderr = strip_ansi(&String::from_utf8_lossy(&output.stderr));
        Err(if stderr.trim().is_empty() {
            NO_PROJECTS_MESSAGE.to_string()
        } else {
            stderr.trim().to_string()
        })
    })
    .await
    .map_err(|error| format!("UBS detect 작업 실패: {error}"))?
}

#[tauri::command]
fn preview_version(project: String, kind: String, bump: String) -> Result<VersionPreview, String> {
    let project = canonical_directory(&project)?;
    version_preview(&project, &kind, &bump)
}

#[tauri::command]
async fn run_build(
    app: AppHandle,
    state: State<'_, BuildState>,
    request: BuildRequest,
) -> Result<BuildResult, String> {
    let project_type = analytics::project_type(request.project_type.as_deref());
    let prepared = prepare_build(&app, request).inspect_err(|_| {
        analytics::build_rejected("invalid_request");
    })?;
    let shared = state.0.clone();
    {
        let mut slot = shared
            .lock()
            .map_err(|_| "빌드 상태 잠금이 손상되었습니다.".to_string())?;
        if slot.active {
            analytics::build_rejected("busy");
            return Err("이미 실행 중인 빌드가 있습니다.".to_string());
        }
        slot.active = true;
        slot.cancelled = false;
    }

    let track = analytics::build_started(
        project_type,
        &prepared.outputs,
        &prepared.version_bump,
        prepared.jobs,
        prepared.clean,
    );
    let result = run_build_tracked(app, shared, prepared).await;
    analytics::build_finished(
        track,
        match &result {
            Ok(result) if result.success => analytics::BuildOutcome::Success {
                artifacts: analytics::artifact_count(result.report.as_ref()),
            },
            Ok(result) if result.cancelled => analytics::BuildOutcome::Cancelled,
            Ok(result) => analytics::BuildOutcome::Failed {
                exit_code: result.exit_code,
            },
            Err(_) => analytics::BuildOutcome::Error,
        },
    );
    result
}

async fn run_build_tracked(
    app: AppHandle,
    shared: Arc<Mutex<ProcessSlot>>,
    prepared: PreparedBuild,
) -> Result<BuildResult, String> {
    let worker_state = shared.clone();
    let result = tauri::async_runtime::spawn_blocking(move || {
        run_build_blocking(app, worker_state, prepared)
    })
    .await;

    match result {
        Ok(inner) => {
            if inner.is_err() {
                clear_process_slot(&shared);
            }
            inner
        }
        Err(error) => {
            clear_process_slot(&shared);
            Err(format!("빌드 작업 실패: {error}"))
        }
    }
}

#[tauri::command]
fn cancel_build(state: State<'_, BuildState>) -> Result<bool, String> {
    request_cancellation(&state.0)
}

#[tauri::command]
fn open_artifact_location(path: String) -> Result<(), String> {
    let result = open_artifact_location_inner(&path);
    analytics::artifact_opened(result.is_ok());
    result
}

/// UI 상태가 바뀔 때 부른다. 이름은 `analytics::SCREENS` 허용 목록으로만 받는다.
#[tauri::command]
fn analytics_screen(name: String) {
    analytics::screen(&name);
}

/// 프론트 조작·오류. action 은 허용 목록으로만 받는다(`analytics::ui_event`).
#[tauri::command]
fn analytics_ui(action: String, detail: Option<String>) {
    analytics::ui_event(&action, detail.as_deref());
}

fn open_artifact_location_inner(path: &str) -> Result<(), String> {
    let (path, is_file) = canonical_artifact_path(path)?;

    #[cfg(target_os = "macos")]
    {
        let status = finder_command(&path, is_file)
            .status()
            .map_err(|error| format!("Finder 실행 실패: {error}"))?;
        if status.success() {
            Ok(())
        } else {
            Err(format!("Finder가 경로를 열지 못했습니다: {status}"))
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = (path, is_file);
        Err("Finder 열기는 macOS에서만 지원합니다.".to_string())
    }
}

fn canonical_artifact_path(raw: &str) -> Result<(PathBuf, bool), String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Err("산출물 경로가 비어 있습니다.".to_string());
    }
    let path = PathBuf::from(raw)
        .canonicalize()
        .map_err(|error| format!("산출물 경로 확인 실패: {error}"))?;
    if path.is_file() {
        Ok((path, true))
    } else if path.is_dir() {
        Ok((path, false))
    } else {
        Err("산출물 경로가 파일 또는 폴더가 아닙니다.".to_string())
    }
}

#[cfg(target_os = "macos")]
fn finder_command(path: &Path, is_file: bool) -> Command {
    let mut command = Command::new("/usr/bin/open");
    let folder = if is_file {
        path.parent().unwrap_or(path)
    } else {
        path
    };
    command.arg(folder);
    command
}

fn request_cancellation(shared: &Arc<Mutex<ProcessSlot>>) -> Result<bool, String> {
    let mut slot = shared
        .lock()
        .map_err(|_| "빌드 상태 잠금이 손상되었습니다.".to_string())?;
    if !slot.active {
        return Ok(false);
    }
    slot.cancelled = true;
    if let Some(child) = slot.child.as_mut() {
        terminate_process_tree(child).map_err(|error| format!("빌드 취소 요청 실패: {error}"))?;
    }
    Ok(true)
}

fn prepare_build(app: &AppHandle, request: BuildRequest) -> Result<PreparedBuild, String> {
    let project = canonical_directory(&request.project)?;
    let version_bump = match request.version_bump.as_str() {
        "none" | "build" | "patch" | "minor" | "major" => request.version_bump,
        _ => return Err("지원하지 않는 버전 변경 값입니다.".to_string()),
    };
    let mut outputs = request.outputs;
    if outputs.len() > 5 {
        return Err("출력 형식 선택이 너무 많습니다.".to_string());
    }
    outputs.sort();
    outputs.dedup();
    if outputs
        .iter()
        .any(|value| !matches!(value.as_str(), "appbundle" | "apk" | "ipa" | "web" | "pkg"))
    {
        return Err("지원하지 않는 출력 형식입니다.".to_string());
    }
    if request.jobs > 8 {
        return Err("병렬 작업 수는 자동 또는 1~8이어야 합니다.".to_string());
    }
    let locale = match request.locale.as_str() {
        "ko" | "en" | "ja" | "zh" => request.locale,
        _ => "en".to_string(),
    };

    Ok(PreparedBuild {
        runtime_root: runtime_root(app)?,
        project,
        version_bump,
        outputs,
        jobs: request.jobs,
        clean: request.clean,
        locale,
        report_path: temporary_report_path(),
    })
}

fn run_build_blocking(
    app: AppHandle,
    shared: Arc<Mutex<ProcessSlot>>,
    prepared: PreparedBuild,
) -> Result<BuildResult, String> {
    let mut command = ubs_command(&prepared.runtime_root)?;
    command
        .arg("build")
        .args(["--non-interactive", "--no-publish", "--verbose"])
        .arg("--project")
        .arg(&prepared.project)
        .args(["--version-bump", &prepared.version_bump])
        .arg(if prepared.clean {
            "--clean"
        } else {
            "--skip-clean"
        })
        .arg("--report-json")
        .arg(&prepared.report_path)
        .env("UBS_LANG", &prepared.locale)
        .env("PYTHONUNBUFFERED", "1")
        .env(
            "UBS_FLUTTER_PARALLEL",
            if prepared.jobs == 1 { "false" } else { "true" },
        )
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if !prepared.outputs.is_empty() {
        command
            .arg("--flutter-outputs")
            .arg(prepared.outputs.join(","));
    }
    if prepared.jobs > 0 {
        command.args(["--jobs", &prepared.jobs.to_string()]);
    }
    configure_process_group(&mut command);

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            clear_process_slot(&shared);
            return Err(format!("UBS build 실행 실패: {error}"));
        }
    };
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "빌드 표준 출력을 열지 못했습니다.".to_string())?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| "빌드 오류 출력을 열지 못했습니다.".to_string())?;
    {
        let mut slot = shared
            .lock()
            .map_err(|_| "빌드 상태 잠금이 손상되었습니다.".to_string())?;
        slot.child = Some(child);
        if slot.cancelled {
            if let Some(child) = slot.child.as_mut() {
                let _ = terminate_process_tree(child);
            }
        }
    }

    let stdout_reader = stream_output(stdout, app.clone(), "stdout");
    let stderr_reader = stream_output(stderr, app, "stderr");
    let status = match wait_for_child(&shared) {
        Ok(status) => status,
        Err(error) => {
            if let Ok(mut slot) = shared.lock() {
                if let Some(child) = slot.child.as_mut() {
                    let _ = terminate_process_tree(child);
                }
            }
            clear_process_slot(&shared);
            return Err(error);
        }
    };
    let stdout = stdout_reader.join().unwrap_or_default();
    let stderr = stderr_reader.join().unwrap_or_default();
    let cancelled = {
        let mut slot = shared
            .lock()
            .map_err(|_| "빌드 상태 잠금이 손상되었습니다.".to_string())?;
        let cancelled = slot.cancelled;
        slot.child = None;
        slot.active = false;
        slot.cancelled = false;
        cancelled
    };
    let report = read_report(&prepared.report_path);

    Ok(BuildResult {
        success: status.success() && !cancelled,
        cancelled,
        exit_code: status.code(),
        stdout,
        stderr,
        report,
    })
}

fn wait_for_child(shared: &Arc<Mutex<ProcessSlot>>) -> Result<ExitStatus, String> {
    loop {
        let status = {
            let mut slot = shared
                .lock()
                .map_err(|_| "빌드 상태 잠금이 손상되었습니다.".to_string())?;
            let child = slot
                .child
                .as_mut()
                .ok_or_else(|| "실행 중인 빌드 프로세스가 없습니다.".to_string())?;
            child
                .try_wait()
                .map_err(|error| format!("빌드 상태 확인 실패: {error}"))?
        };
        if let Some(status) = status {
            return Ok(status);
        }
        thread::sleep(Duration::from_millis(100));
    }
}

fn stream_output<R: Read + Send + 'static>(
    stream: R,
    app: AppHandle,
    stream_name: &'static str,
) -> thread::JoinHandle<String> {
    thread::spawn(move || {
        let mut reader = BufReader::new(stream);
        let mut captured = VecDeque::new();
        let mut captured_bytes = 0usize;
        loop {
            let mut raw = Vec::new();
            match reader.read_until(b'\n', &mut raw) {
                Ok(0) => break,
                Ok(_) => {
                    let line = strip_ansi(String::from_utf8_lossy(&raw).trim_end());
                    if !line.is_empty() {
                        let _ = app.emit(
                            "build-log",
                            BuildLog {
                                stream: stream_name,
                                line: line.clone(),
                            },
                        );
                        captured_bytes += line.len() + 1;
                        captured.push_back(line);
                        while captured_bytes > MAX_CAPTURED_BYTES {
                            if let Some(removed) = captured.pop_front() {
                                captured_bytes = captured_bytes.saturating_sub(removed.len() + 1);
                            } else {
                                break;
                            }
                        }
                    }
                }
                Err(_) => break,
            }
        }
        captured.into_iter().collect::<Vec<_>>().join("\n")
    })
}

fn runtime_root(app: &AppHandle) -> Result<PathBuf, String> {
    #[cfg(debug_assertions)]
    {
        let _ = app;
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .canonicalize()
            .map_err(|error| format!("개발용 UBS 경로 확인 실패: {error}"))
    }
    #[cfg(not(debug_assertions))]
    {
        let root = app
            .path()
            .resource_dir()
            .map_err(|error| format!("앱 리소스 경로 확인 실패: {error}"))?
            .join("ubs-runtime");
        if root.join("build.sh").is_file() {
            Ok(root)
        } else {
            Err("앱에 UBS 런타임이 포함되지 않았습니다.".to_string())
        }
    }
}

fn canonical_directory(raw: &str) -> Result<PathBuf, String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Err("프로젝트 폴더를 선택하세요.".to_string());
    }
    let path = PathBuf::from(raw)
        .canonicalize()
        .map_err(|error| format!("프로젝트 경로 확인 실패: {error}"))?;
    if !path.is_dir() {
        return Err("선택한 경로가 폴더가 아닙니다.".to_string());
    }
    Ok(path)
}

fn install_missing_ubs(
    runtime_root: &Path,
    selected_root: &Path,
    detected: &Value,
) -> Result<(), String> {
    let projects = detected
        .as_array()
        .ok_or_else(|| "UBS detect 결과 형식이 올바르지 않습니다.".to_string())?;
    let mut installed_roots = Vec::new();
    for project in projects {
        let raw = project
            .get("path")
            .and_then(Value::as_str)
            .ok_or_else(|| "감지된 프로젝트 경로가 없습니다.".to_string())?;
        let project_root = canonical_directory(raw)?;
        if !project_root.starts_with(selected_root) {
            return Err(format!(
                "선택한 폴더 밖의 프로젝트에는 UBS를 설치하지 않습니다: {}",
                project_root.display()
            ));
        }
        if installed_roots.contains(&project_root) {
            continue;
        }
        install_bundled_ubs(runtime_root, &project_root)?;
        installed_roots.push(project_root);
    }
    Ok(())
}

fn install_bundled_ubs(runtime_root: &Path, project_root: &Path) -> Result<bool, String> {
    let build_script = project_root.join("build.sh");
    let python_runtime = project_root.join("scripts/ubs.py");
    if build_script.is_file() && python_runtime.is_file() {
        return Ok(false);
    }

    let installer = runtime_root.join("install.sh");
    if !installer.is_file() {
        return Err("앱에 UBS 설치기가 포함되지 않았습니다.".to_string());
    }
    let source_url = tauri::Url::from_directory_path(runtime_root)
        .map_err(|_| "앱의 UBS 설치 소스 경로를 변환하지 못했습니다.".to_string())?;
    #[cfg(windows)]
    let mut command = Command::new("bash");
    #[cfg(not(windows))]
    let mut command = Command::new("/bin/bash");
    command
        .arg(installer)
        .current_dir(project_root)
        .env("UBS_INSTALL_BASE_URL", source_url.as_str())
        .env("UBS_INSTALL_ALLOW_FILE", "true");
    if build_script.symlink_metadata().is_ok() || python_runtime.symlink_metadata().is_ok() {
        command.env("UBS_FORCE", "true");
    }
    add_common_executable_paths(&mut command);
    let output = command
        .output()
        .map_err(|error| format!("UBS 자동 설치 실행 실패: {error}"))?;
    if !output.status.success() {
        let stderr = strip_ansi(&String::from_utf8_lossy(&output.stderr));
        let stdout = strip_ansi(&String::from_utf8_lossy(&output.stdout));
        let detail = if stderr.trim().is_empty() {
            stdout.trim()
        } else {
            stderr.trim()
        };
        return Err(if detail.is_empty() {
            format!("UBS 자동 설치 실패: {}", output.status)
        } else {
            format!("UBS 자동 설치 실패: {detail}")
        });
    }
    if !build_script.is_file() || !python_runtime.is_file() {
        return Err("UBS 자동 설치 후 필수 실행 파일을 확인하지 못했습니다.".to_string());
    }
    Ok(true)
}

fn version_preview(project: &Path, kind: &str, bump: &str) -> Result<VersionPreview, String> {
    if !matches!(bump, "none" | "build" | "patch" | "minor" | "major") {
        return Err("지원하지 않는 버전 정책입니다.".to_string());
    }
    match kind {
        "tauri" => tauri_version_preview(project, bump),
        "flutter" => flutter_version_preview(project, bump),
        _ => Err("이 프로젝트 형식은 버전 미리보기를 지원하지 않습니다.".to_string()),
    }
}

fn tauri_version_preview(project: &Path, bump: &str) -> Result<VersionPreview, String> {
    let config_path = project.join("src-tauri/tauri.conf.json");
    let config: Value = serde_json::from_str(
        &fs::read_to_string(&config_path)
            .map_err(|error| format!("Tauri 버전 파일 읽기 실패: {error}"))?,
    )
    .map_err(|error| format!("Tauri 설정 분석 실패: {error}"))?;
    let version = config
        .get("version")
        .and_then(Value::as_str)
        .ok_or_else(|| "Tauri 설정에 version이 없습니다.".to_string())?;
    let build = config
        .pointer("/bundle/macOS/bundleVersion")
        .and_then(Value::as_str)
        .unwrap_or(version);
    let next_version = bump_version_name(version, bump)?;
    let next_build = if bump == "none" {
        build.to_string()
    } else {
        increment_trailing_number(build)?
    };
    Ok(VersionPreview {
        current: VersionPoint {
            version: version.to_string(),
            build: build.to_string(),
        },
        next: VersionPoint {
            version: next_version,
            build: next_build,
        },
    })
}

fn flutter_version_preview(project: &Path, bump: &str) -> Result<VersionPreview, String> {
    let pubspec_path = project.join("pubspec.yaml");
    let pubspec = fs::read_to_string(&pubspec_path)
        .map_err(|error| format!("Flutter 버전 파일 읽기 실패: {error}"))?;
    let current = pubspec
        .lines()
        .find_map(|line| line.strip_prefix("version:").map(str::trim))
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "pubspec.yaml에 version이 없습니다.".to_string())?;
    let (version, build) = current.rsplit_once('+').unwrap_or((current, "0"));
    let next_version = bump_version_name(version, bump)?;
    let next_build = if bump == "none" {
        build.to_string()
    } else {
        increment_trailing_number(build)?
    };
    Ok(VersionPreview {
        current: VersionPoint {
            version: version.to_string(),
            build: build.to_string(),
        },
        next: VersionPoint {
            version: next_version,
            build: next_build,
        },
    })
}

fn bump_version_name(current: &str, bump: &str) -> Result<String, String> {
    if matches!(bump, "none" | "build") {
        return Ok(current.to_string());
    }
    let stable = current.split_once('-').map_or(current, |(value, _)| value);
    let mut parts = stable.split('.');
    let major = parts
        .next()
        .and_then(|value| value.parse::<u64>().ok())
        .ok_or_else(|| format!("버전 형식이 올바르지 않습니다: {current}"))?;
    let minor = parts
        .next()
        .and_then(|value| value.parse::<u64>().ok())
        .ok_or_else(|| format!("버전 형식이 올바르지 않습니다: {current}"))?;
    let patch = parts
        .next()
        .and_then(|value| value.parse::<u64>().ok())
        .ok_or_else(|| format!("버전 형식이 올바르지 않습니다: {current}"))?;
    if parts.next().is_some() {
        return Err(format!("버전 형식이 올바르지 않습니다: {current}"));
    }
    match bump {
        "patch" => Ok(format!(
            "{major}.{minor}.{}",
            patch
                .checked_add(1)
                .ok_or_else(|| "패치 버전이 너무 큽니다.".to_string())?
        )),
        "minor" => Ok(format!(
            "{major}.{}.0",
            minor
                .checked_add(1)
                .ok_or_else(|| "마이너 버전이 너무 큽니다.".to_string())?
        )),
        "major" => Ok(format!(
            "{}.0.0",
            major
                .checked_add(1)
                .ok_or_else(|| "메이저 버전이 너무 큽니다.".to_string())?
        )),
        _ => Err("지원하지 않는 버전 정책입니다.".to_string()),
    }
}

fn increment_trailing_number(current: &str) -> Result<String, String> {
    let digits_at = current
        .char_indices()
        .rev()
        .find(|(_, character)| !character.is_ascii_digit())
        .map_or(0, |(index, character)| index + character.len_utf8());
    let number = current[digits_at..]
        .parse::<u64>()
        .map_err(|_| format!("빌드 번호 형식이 올바르지 않습니다: {current}"))?;
    let next = number
        .checked_add(1)
        .ok_or_else(|| "빌드 번호가 너무 큽니다.".to_string())?;
    Ok(format!("{}{next}", &current[..digits_at]))
}

fn ubs_command(runtime_root: &Path) -> Result<Command, String> {
    let script = runtime_root.join("build.sh");
    if !script.is_file() {
        return Err(format!("UBS 실행 파일이 없습니다: {}", script.display()));
    }
    #[cfg(windows)]
    let mut command = Command::new("bash");
    #[cfg(not(windows))]
    let mut command = Command::new("/bin/bash");
    command.arg(script).current_dir(runtime_root);
    add_common_executable_paths(&mut command);
    Ok(command)
}

fn add_common_executable_paths(command: &mut Command) {
    let mut paths: Vec<PathBuf> = std::env::var_os("PATH")
        .as_deref()
        .map(std::env::split_paths)
        .into_iter()
        .flatten()
        .collect();
    for path in [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ] {
        let path = PathBuf::from(path);
        if !paths.contains(&path) {
            paths.push(path);
        }
    }
    if let Some(home) = std::env::var_os("HOME") {
        let home = PathBuf::from(home);
        for suffix in [
            ".cargo/bin",
            ".pub-cache/bin",
            ".local/bin",
            "Desktop/flutter/bin",
            "Development/flutter/bin",
            "flutter/bin",
            ".fvm/default/bin",
        ] {
            let path = home.join(suffix);
            if !paths.contains(&path) {
                paths.push(path);
            }
        }
    }
    if let Ok(path) = std::env::join_paths(paths) {
        command.env("PATH", path);
    }
}

fn temporary_report_path() -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    std::env::temp_dir().join(format!("ubs-desktop-{}-{nonce}.json", std::process::id()))
}

fn read_report(path: &Path) -> Option<Value> {
    let report = fs::read_to_string(path)
        .ok()
        .and_then(|content| serde_json::from_str(&content).ok());
    let _ = fs::remove_file(path);
    report
}

fn clear_process_slot(shared: &Arc<Mutex<ProcessSlot>>) {
    if let Ok(mut slot) = shared.lock() {
        slot.child = None;
        slot.active = false;
        slot.cancelled = false;
    }
}

#[cfg(unix)]
fn configure_process_group(command: &mut Command) {
    use std::os::unix::process::CommandExt;
    command.process_group(0);
}

#[cfg(windows)]
fn configure_process_group(command: &mut Command) {
    use std::os::windows::process::CommandExt;
    command.creation_flags(0x0000_0200);
}

#[cfg(unix)]
fn terminate_process_tree(child: &mut Child) -> std::io::Result<()> {
    let status = Command::new("/bin/kill")
        .args(["-TERM", &format!("-{}", child.id())])
        .status()?;
    if status.success() {
        Ok(())
    } else {
        child.kill()
    }
}

#[cfg(windows)]
fn terminate_process_tree(child: &mut Child) -> std::io::Result<()> {
    let status = Command::new("taskkill")
        .args(["/PID", &child.id().to_string(), "/T", "/F"])
        .status()?;
    if status.success() {
        Ok(())
    } else {
        child.kill()
    }
}

fn strip_ansi(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();
    while let Some(character) = chars.next() {
        if character == '\u{1b}' && chars.peek() == Some(&'[') {
            chars.next();
            for control in chars.by_ref() {
                if ('@'..='~').contains(&control) {
                    break;
                }
            }
        } else {
            output.push(character);
        }
    }
    output
}

fn main() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(BuildState::default())
        .setup(|app| {
            analytics::init(app.handle());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            detect_projects,
            preview_version,
            run_build,
            cancel_build,
            open_artifact_location,
            analytics_screen,
            analytics_ui
        ])
        .build(tauri::generate_context!())
        .expect("UBS desktop 초기화 실패");
    app.run(|app_handle, event| {
        let is_exit = matches!(event, tauri::RunEvent::Exit);
        let should_cancel = match event {
            tauri::RunEvent::Exit | tauri::RunEvent::ExitRequested { .. } => true,
            tauri::RunEvent::WindowEvent {
                label,
                event: tauri::WindowEvent::Destroyed,
                ..
            } => label == "main",
            _ => false,
        };
        if should_cancel {
            let state = app_handle.state::<BuildState>();
            let _ = request_cancellation(&state.0);
        }
        if is_exit {
            analytics::flush(Duration::from_secs(2));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ansi_sequences_are_removed() {
        assert_eq!(strip_ansi("\u{1b}[32m완료\u{1b}[0m"), "완료");
    }

    #[test]
    fn temporary_reports_are_unique_enough_for_one_process() {
        let first = temporary_report_path();
        thread::sleep(Duration::from_millis(1));
        let second = temporary_report_path();
        assert_ne!(first, second);
        assert_eq!(
            first.extension().and_then(|value| value.to_str()),
            Some("json")
        );
    }

    #[test]
    fn artifact_paths_are_canonicalized_and_classified() {
        let root = std::env::temp_dir().join(format!(
            "ubs-artifact-path-test-{}",
            temporary_report_path()
                .file_stem()
                .expect("temporary file stem")
                .to_string_lossy()
        ));
        fs::create_dir_all(&root).expect("artifact directory");
        let file = root.join("output artifact.apk");
        fs::write(&file, b"artifact").expect("artifact file");

        assert_eq!(
            canonical_artifact_path(""),
            Err("산출물 경로가 비어 있습니다.".to_string())
        );
        assert!(
            canonical_artifact_path(root.join("missing.apk").to_str().expect("UTF-8 path"))
                .expect_err("missing artifact must fail")
                .starts_with("산출물 경로 확인 실패:")
        );
        assert_eq!(
            canonical_artifact_path(root.to_str().expect("UTF-8 path")),
            Ok((root.canonicalize().expect("canonical directory"), false))
        );
        assert_eq!(
            canonical_artifact_path(file.to_str().expect("UTF-8 path")),
            Ok((file.canonicalize().expect("canonical file"), true))
        );

        fs::remove_dir_all(root).expect("test cleanup");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn finder_opens_artifact_folders_with_argv() {
        let file = Path::new("/tmp/output artifact.apk");
        let file_command = finder_command(file, true);
        assert_eq!(file_command.get_program(), "/usr/bin/open");
        assert_eq!(
            file_command.get_args().collect::<Vec<_>>(),
            vec![Path::new("/tmp").as_os_str()]
        );

        let directory = Path::new("/tmp/output folder");
        let directory_command = finder_command(directory, false);
        assert_eq!(directory_command.get_program(), "/usr/bin/open");
        assert_eq!(
            directory_command.get_args().collect::<Vec<_>>(),
            vec![directory.as_os_str()]
        );
    }

    #[test]
    fn current_repository_is_the_debug_runtime() {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .canonicalize()
            .expect("repository root");
        assert!(root.join("build.sh").is_file());
        assert!(root.join("scripts/ubs.py").is_file());
    }

    #[cfg(unix)]
    #[test]
    fn bundled_installer_repairs_partial_ubs_and_skips_complete_install() {
        let runtime = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .canonicalize()
            .expect("repository root");
        let target = std::env::temp_dir().join(format!(
            "ubs-desktop-install-test-{}",
            temporary_report_path()
                .file_stem()
                .expect("temporary file stem")
                .to_string_lossy()
        ));
        fs::create_dir_all(target.join("src-tauri")).expect("Tauri fixture directory");
        fs::write(target.join("src-tauri/tauri.conf.json"), b"{}").expect("Tauri fixture config");
        fs::write(target.join("build.sh"), b"#!/usr/bin/env bash\n# stale\n")
            .expect("partial UBS fixture");

        assert!(install_bundled_ubs(&runtime, &target).expect("automatic UBS install"));
        assert_eq!(
            fs::read(target.join("build.sh")).expect("installed build.sh"),
            fs::read(runtime.join("build.sh")).expect("bundled build.sh")
        );
        assert!(target.join("scripts/ubs.py").is_file());
        assert!(!install_bundled_ubs(&runtime, &target).expect("complete UBS check"));

        fs::remove_dir_all(target).expect("test cleanup");
    }

    #[test]
    fn version_preview_matches_tauri_and_flutter_build_policies() {
        let target = std::env::temp_dir().join(format!(
            "ubs-version-preview-test-{}",
            temporary_report_path()
                .file_stem()
                .expect("temporary file stem")
                .to_string_lossy()
        ));
        fs::create_dir_all(target.join("src-tauri")).expect("Tauri fixture directory");
        fs::write(
            target.join("src-tauri/tauri.conf.json"),
            br#"{"version":"1.2.3","bundle":{"macOS":{"bundleVersion":"7"}}}"#,
        )
        .expect("Tauri fixture config");

        assert_eq!(
            version_preview(&target, "tauri", "build").expect("Tauri build preview"),
            VersionPreview {
                current: VersionPoint {
                    version: "1.2.3".to_string(),
                    build: "7".to_string(),
                },
                next: VersionPoint {
                    version: "1.2.3".to_string(),
                    build: "8".to_string(),
                },
            }
        );
        assert_eq!(
            version_preview(&target, "tauri", "minor")
                .expect("Tauri semantic version preview")
                .next,
            VersionPoint {
                version: "1.3.0".to_string(),
                build: "8".to_string(),
            }
        );

        fs::write(
            target.join("pubspec.yaml"),
            b"name: fixture\nversion: 2.4.6+9\n",
        )
        .expect("Flutter fixture config");
        assert_eq!(
            version_preview(&target, "flutter", "patch")
                .expect("Flutter version preview")
                .next,
            VersionPoint {
                version: "2.4.7".to_string(),
                build: "10".to_string(),
            }
        );

        fs::remove_dir_all(target).expect("test cleanup");
    }

    #[cfg(unix)]
    #[test]
    fn desktop_flutter_sdk_is_available_to_build_commands() {
        let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
            return;
        };
        let mut command = Command::new("/bin/sh");
        add_common_executable_paths(&mut command);
        let path = command
            .get_envs()
            .find(|(key, _)| *key == "PATH")
            .and_then(|(_, value)| value)
            .expect("PATH override");
        assert!(std::env::split_paths(path).any(|entry| entry == home.join("Desktop/flutter/bin")));

        if home.join("Desktop/flutter/bin/flutter").is_file() {
            command.args(["-c", "command -v flutter"]);
            let output = command.output().expect("Flutter lookup");
            assert!(output.status.success());
            assert_eq!(
                String::from_utf8_lossy(&output.stdout).trim(),
                home.join("Desktop/flutter/bin/flutter").to_string_lossy()
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn cancellation_terminates_the_active_process_group() {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "sleep 30"]);
        configure_process_group(&mut command);
        let child = command.spawn().expect("spawn cancellable child");
        let shared = Arc::new(Mutex::new(ProcessSlot {
            active: true,
            cancelled: false,
            child: Some(child),
        }));

        assert!(request_cancellation(&shared).expect("cancel request"));
        let mut exited = false;
        for _ in 0..20 {
            let status = shared
                .lock()
                .expect("process slot")
                .child
                .as_mut()
                .expect("active child")
                .try_wait()
                .expect("child status");
            if status.is_some() {
                exited = true;
                break;
            }
            thread::sleep(Duration::from_millis(50));
        }
        assert!(exited, "cancelled child did not exit within one second");
    }
}
