use std::path::Path;

/// 계측(analytics-core) 키를 컴파일 타임에 주입한다.
///
/// 우선순위: 빌드 환경변수 > `desktop/.env` > 레포 루트 `.env`.
/// 키가 없으면 계측이 통째로 꺼진 채 빌드된다 — 조용히 꺼지지 않도록 경고를 남긴다.
/// 확인: `strings <바이너리> | grep -cF "$ANALYTICS_TOKEN"` 이 1 이상이어야 한다.
fn main() {
    println!("cargo:rerun-if-env-changed=ANALYTICS_TOKEN");
    println!("cargo:rerun-if-env-changed=ANALYTICS_HOST");

    let mut token = env_value("ANALYTICS_TOKEN");
    let mut host = env_value("ANALYTICS_HOST");
    for file in ["../.env", "../../.env"] {
        if !Path::new(file).is_file() {
            continue;
        }
        println!("cargo:rerun-if-changed={file}");
        let Ok(contents) = std::fs::read_to_string(file) else {
            continue;
        };
        if token.is_none() {
            token = dotenv_value(&contents, "ANALYTICS_TOKEN");
        }
        if host.is_none() {
            host = dotenv_value(&contents, "ANALYTICS_HOST");
        }
    }

    match token {
        Some(token) => {
            println!("cargo:rustc-env=UBS_ANALYTICS_TOKEN={token}");
            if let Some(host) = host {
                println!("cargo:rustc-env=UBS_ANALYTICS_HOST={host}");
            }
        }
        None => println!(
            "cargo:warning=ANALYTICS_TOKEN 이 없어 계측이 꺼진 채 빌드됩니다 (desktop/.env 또는 레포 루트 .env)"
        ),
    }

    tauri_build::build();
}

fn env_value(key: &str) -> Option<String> {
    std::env::var(key)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn dotenv_value(contents: &str, wanted: &str) -> Option<String> {
    contents.lines().find_map(|line| {
        let line = line.trim();
        if line.starts_with('#') {
            return None;
        }
        let (key, value) = line.split_once('=')?;
        if key.trim().trim_start_matches("export ").trim() != wanted {
            return None;
        }
        let value = value.trim();
        let value = value
            .strip_prefix('"')
            .and_then(|v| v.strip_suffix('"'))
            .or_else(|| value.strip_prefix('\'').and_then(|v| v.strip_suffix('\'')))
            .unwrap_or(value);
        Some(value.to_string()).filter(|value| !value.is_empty())
    })
}
