(() => {
  "use strict";

  const messages = window.UBS_MESSAGES;
  const tauri = window.__TAURI__;
  const invoke = tauri?.core?.invoke;
  const openDialog = tauri?.dialog?.open;
  const listen = tauri?.event?.listen;
  const projectStore = window.UBS_PROJECT_STORE;
  const projectsKey = "ubs.saved-projects.v1";
  const selectedProjectKey = "ubs.selected-project.v1";
  const buildHistoryKey = "ubs.build-history.v1";
  const localeKey = "ubs.locale.v1";
  const LOG_LINE_LIMIT = 420;
  const storage = (() => {
    try {
      return window.localStorage;
    } catch {
      return null;
    }
  })();
  const detectedLocale = resolveLocale(navigator.languages || [navigator.language]);
  const savedLocale = storage?.getItem(localeKey);
  let locale = ["ko", "en"].includes(savedLocale)
    ? savedLocale
    : ["ko", "en"].includes(detectedLocale) ? detectedLocale : "en";
  const projects = [];
  const savedProjects = projectStore.load(storage, projectsKey);
  const buildHistory = projectStore.loadHistory(storage, buildHistoryKey);
  const logLines = [];
  let selectedProject = null;
  let running = false;
  let timer = null;
  let startedAt = 0;
  let copyFeedbackTimer = null;
  let versionPreviewRequest = 0;
  let lastBuildResult = null;
  let runStatusState = { key: "ready", tone: "", values: {} };
  let trackedScreen = null;
  let resultProjectPath = null;

  const elements = {
    addProject: document.querySelector("#add-project"),
    chooseFolder: document.querySelector("#choose-folder"),
    projectPath: document.querySelector("#project-path"),
    projectBadge: document.querySelector("#project-badge"),
    projectChoice: document.querySelector("#project-choice"),
    projectList: document.querySelector("#project-list"),
    projectState: document.querySelector("#project-state"),
    currentProject: document.querySelector("#current-project"),
    currentProjectName: document.querySelector("#current-project-name"),
    currentProjectSymbol: document.querySelector("#current-project-symbol"),
    currentProjectType: document.querySelector("#current-project-type"),
    removeCurrentProject: document.querySelector("#remove-current-project"),
    buildHistory: document.querySelector("#build-history"),
    historyCount: document.querySelector("#history-count"),
    historyEmpty: document.querySelector("#history-empty"),
    versionBumps: [...document.querySelectorAll('input[name="version-bump"]')],
    versionPreview: document.querySelector("#version-preview"),
    currentVersion: document.querySelector("#current-version"),
    nextVersion: document.querySelector("#next-version"),
    jobs: [...document.querySelectorAll('input[name="jobs"]')],
    jobsCard: document.querySelector("#jobs-card"),
    cleanBuild: document.querySelector("#clean-build"),
    outputFieldset: document.querySelector("#output-fieldset"),
    outputHint: document.querySelector("#output-hint"),
    outputChecks: [...document.querySelectorAll("#output-fieldset input")],
    pipeline: [...document.querySelectorAll("#pipeline li")],
    runStatus: document.querySelector("#run-status"),
    startBuild: document.querySelector("#start-build"),
    cancelBuild: document.querySelector("#cancel-build"),
    buildLog: document.querySelector("#build-log"),
    buildResult: document.querySelector("#build-result"),
    copyLog: document.querySelector("#copy-log"),
    copyLogStatus: document.querySelector("#copy-log-status"),
    logStatus: document.querySelector("#log-status"),
    elapsed: document.querySelector("#elapsed"),
    localeOptions: [...document.querySelectorAll(".locale-option")]
  };
  let logRenderQueued = false;

  // 계측: 이름·동작은 Rust 쪽 허용 목록(analytics.rs)으로만 받는다. 실패는 무시한다.
  function track(action, detail) {
    invoke?.("analytics_ui", { action, detail: detail ?? null })?.catch(() => {});
  }

  function syncScreen() {
    // 결과 칸은 다른 프로젝트를 골라도 남아 있어서, 결과가 지금 프로젝트의 것일 때만 결과 화면으로 센다.
    const showingResult = Boolean(lastBuildResult) && selectedProject?.path === resultProjectPath;
    const name = running
      ? "/build"
      : showingResult
        ? "/build/result"
        : !elements.projectChoice.hidden
          ? "/project/choose"
          : selectedProject ? "/project" : "/welcome";
    if (!invoke || name === trackedScreen) return;
    trackedScreen = name;
    invoke("analytics_screen", { name }).catch(() => {});
  }

  function resolveLocale(languages) {
    const language = languages.find(Boolean)?.toLowerCase() || "en";
    if (language.startsWith("ko")) return "ko";
    if (language.startsWith("ja")) return "ja";
    if (language.startsWith("zh")) return "zh";
    return "en";
  }

  function text(key, values = {}) {
    let value = messages[locale]?.[key] || messages.en[key] || key;
    for (const [name, replacement] of Object.entries(values)) {
      value = value.replace(`{${name}}`, String(replacement));
    }
    return value;
  }

  function applyLocale() {
    document.documentElement.lang = locale;
    document.querySelectorAll("[data-i18n]").forEach((element) => {
      element.textContent = text(element.dataset.i18n);
    });
    document.querySelectorAll("[data-i18n-aria-label]").forEach((element) => {
      element.setAttribute("aria-label", text(element.dataset.i18nAriaLabel));
    });
    elements.localeOptions.forEach((button) => {
      const active = button.dataset.locale === locale;
      button.classList.toggle("active", active);
      button.setAttribute("aria-pressed", String(active));
    });
    setRunStatus(runStatusState.key, runStatusState.tone, runStatusState.values);
    elements.logStatus.textContent = text("logStatus", {
      current: String(logLines.length),
      total: String(LOG_LINE_LIMIT)
    });
  }

  function setRunStatus(key, tone = "", values = {}) {
    runStatusState = { key, tone, values };
    elements.runStatus.textContent = text(key, values);
    elements.runStatus.className = ["run-status", tone].filter(Boolean).join(" ");
  }

  function selectLocale(nextLocale) {
    if (running || !["ko", "en"].includes(nextLocale) || nextLocale === locale) return;
    locale = nextLocale;
    storage?.setItem(localeKey, locale);
    track("locale_changed");
    applyLocale();
    applySelectedProject();
    setProjectState(
      selectedProject
        ? text("projectSelected", { name: projectName(selectedProject.path) })
        : text("waitingProject"),
      selectedProject ? "success" : "neutral"
    );
    if (lastBuildResult) renderResult(lastBuildResult);
  }

  function setProjectState(message, tone = "neutral") {
    elements.projectState.textContent = message;
    elements.projectState.dataset.tone = tone;
  }

  function setPipeline(activeStage, failed = false) {
    const order = ["detect", "validate", "build", "package", "done"];
    const activeIndex = order.indexOf(activeStage);
    elements.pipeline.forEach((item, index) => {
      item.className = "";
      if (activeIndex < 0) return;
      if (index < activeIndex) item.classList.add("complete");
      if (index === activeIndex) item.classList.add(failed ? "failed" : "active");
    });
  }

  function projectName(path) {
    return path.replace(/[\\/]+$/, "").split(/[\\/]/).pop() || path;
  }

  function projectSymbol(type) {
    return type.slice(0, 2).toUpperCase();
  }

  function historyStatus(status) {
    const keys = {
      success: "historySuccess",
      failed: "historyFailed",
      cancelled: "historyCancelled"
    };
    return text(keys[status] || "historyFailed");
  }

  function settingsSummary(settings, type) {
    const normalized = projectStore.normalizeSettings(settings);
    const versionKeys = {
      none: "versionNone",
      build: "versionBuild",
      patch: "versionPatch",
      minor: "versionMinor",
      major: "versionMajor"
    };
    const outputs = normalized.outputs.map((output) => output.toUpperCase()).join("+");
    return [
      text(versionKeys[normalized.versionBump]),
      text(normalized.jobs === 1 ? "jobsSequential" : "jobsParallel"),
      normalized.clean ? text("cleanLabel") : null,
      type === "flutter" ? outputs : null
    ].filter(Boolean).join(" · ");
  }

  function renderHistory() {
    elements.buildHistory.replaceChildren();
    elements.historyCount.textContent = String(buildHistory.length);
    elements.historyEmpty.hidden = buildHistory.length > 0;
    buildHistory.forEach((record, index) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "history-item";
      button.dataset.index = String(index);
      button.dataset.status = record.status;
      button.classList.toggle("active", selectedProject?.path === record.path);
      button.setAttribute("aria-label", `${projectName(record.path)} · ${settingsSummary(record.settings, record.type)}`);
      if (record.builtAt) button.title = `${record.path}\n${record.builtAt}`;

      const title = document.createElement("span");
      title.className = "history-title";
      const name = document.createElement("strong");
      name.textContent = projectName(record.path);
      const status = document.createElement("span");
      status.className = "history-status";
      status.textContent = historyStatus(record.status);
      title.append(name, status);

      const summary = document.createElement("span");
      summary.className = "history-summary";
      summary.textContent = settingsSummary(record.settings, record.type);
      button.append(title, summary);
      elements.buildHistory.append(button);
    });
  }

  function rememberBuild(project, settings, status) {
    const next = projectStore.rememberBuild(buildHistory, project, settings, status);
    buildHistory.splice(0, buildHistory.length, ...next);
    projectStore.saveHistory(storage, buildHistoryKey, buildHistory);
    renderHistory();
  }

  function saveCurrentProject(project) {
    savedProjects.splice(0, savedProjects.length, ...(project ? [project] : []));
    projectStore.save(storage, projectsKey, savedProjects);
  }

  function applySelectedProject() {
    const isFlutter = selectedProject?.type === "flutter";
    elements.chooseFolder.hidden = Boolean(selectedProject);
    elements.currentProject.hidden = !selectedProject;
    elements.projectBadge.textContent = selectedProject?.type || text("notDetected");
    elements.projectBadge.classList.toggle("detected", Boolean(selectedProject));
    elements.currentProjectName.textContent = selectedProject ? projectName(selectedProject.path) : "";
    elements.currentProjectSymbol.textContent = selectedProject ? projectSymbol(selectedProject.type) : "--";
    elements.currentProjectType.textContent = selectedProject?.type || "";
    elements.projectPath.textContent = selectedProject?.path || "";
    if (selectedProject) {
      elements.removeCurrentProject.setAttribute("aria-label", text("removeProject", {
        name: projectName(selectedProject.path)
      }));
    }
    elements.outputFieldset.hidden = !isFlutter;
    elements.outputFieldset.disabled = running || !isFlutter;
    elements.outputHint.textContent = text(isFlutter ? "outputsReady" : "outputsUnavailable");
    elements.startBuild.disabled = running || !selectedProject;
    projectStore.saveSelectedPath(storage, selectedProjectKey, selectedProject?.path);
    syncBuildModeVisibility();
    renderHistory();
    if (selectedProject) setPipeline("validate");
    else setPipeline(null);
    refreshVersionPreview();
    syncScreen();
  }

  function selectProject(project, announce = true, closeChoice = true, restoreHistory = false) {
    selectedProject = project;
    if (closeChoice) elements.projectChoice.hidden = true;
    saveCurrentProject(project);
    applyBuildSettings(restoreHistory
      ? projectStore.latestSettings(buildHistory, project.path)
      : projectStore.normalizeSettings());
    applySelectedProject();
    if (announce) setProjectState(text("projectSelected", { name: projectName(project.path) }), "success");
  }

  function removeCurrentProject() {
    if (!selectedProject || running) return;
    const removed = selectedProject;
    selectedProject = null;
    projects.splice(0);
    elements.projectChoice.hidden = true;
    saveCurrentProject(null);
    applyBuildSettings(projectStore.normalizeSettings());
    applySelectedProject();
    setProjectState(text("projectRemoved", { name: projectName(removed.path) }), "success");
  }

  function selectedValue(inputs) {
    return inputs.find((input) => input.checked)?.value;
  }

  function currentBuildSettings() {
    return projectStore.normalizeSettings({
      versionBump: selectedValue(elements.versionBumps),
      jobs: Number(selectedValue(elements.jobs)),
      clean: elements.cleanBuild.checked,
      outputs: elements.outputChecks.filter((input) => input.checked).map((input) => input.value)
    });
  }

  function applyBuildSettings(settings) {
    const normalized = projectStore.normalizeSettings(settings);
    elements.versionBumps.forEach((input) => {
      input.checked = input.value === normalized.versionBump;
    });
    elements.jobs.forEach((input) => {
      input.checked = Number(input.value) === normalized.jobs;
    });
    elements.cleanBuild.checked = normalized.clean;
    elements.outputChecks.forEach((input) => {
      input.checked = normalized.outputs.includes(input.value);
    });
    syncBuildModeVisibility();
  }

  function formatVersionPoint(point) {
    if (!point?.version) return "";
    return point.build
      ? `${point.version} · ${text("versionBuildValue", { value: point.build })}`
      : point.version;
  }

  async function refreshVersionPreview() {
    const request = ++versionPreviewRequest;
    elements.versionPreview.hidden = true;
    elements.currentVersion.textContent = "";
    elements.nextVersion.textContent = "";
    if (!invoke || !selectedProject) return;
    try {
      const preview = await invoke("preview_version", {
        project: selectedProject.path,
        kind: selectedProject.type,
        bump: selectedValue(elements.versionBumps)
      });
      if (request !== versionPreviewRequest) return;
      elements.currentVersion.textContent = formatVersionPoint(preview.current);
      elements.nextVersion.textContent = formatVersionPoint(preview.next);
      elements.versionPreview.hidden = false;
    } catch {
      if (request === versionPreviewRequest) elements.versionPreview.hidden = true;
    }
  }

  function syncBuildModeVisibility() {
    const outputCount = elements.outputChecks.filter((input) => input.checked).length;
    const showBuildMode = selectedProject?.type === "flutter" && outputCount >= 2;
    elements.jobsCard.hidden = !showBuildMode;
    if (!showBuildMode) {
      elements.jobs.forEach((input) => {
        input.checked = input.value === "1";
      });
    }
  }

  function syncOutputChecks(changed) {
    if (!elements.outputChecks.some((input) => input.checked)) changed.checked = true;
    syncBuildModeVisibility();
  }

  function scheduleLogRender() {
    if (logRenderQueued) return;
    logRenderQueued = true;
    window.requestAnimationFrame(() => {
      logRenderQueued = false;
      elements.buildLog.textContent = logLines.join("\n");
      elements.logStatus.textContent = text("logStatus", {
        current: String(logLines.length),
        total: String(LOG_LINE_LIMIT)
      });
      const atTail = elements.buildLog.scrollHeight - elements.buildLog.clientHeight <= elements.buildLog.scrollTop + 16;
      if (atTail) elements.buildLog.scrollTop = elements.buildLog.scrollHeight;
      elements.copyLog.disabled = logLines.length === 0;
    });
  }

  function appendLog(payload) {
    const line = `${payload?.stream === "stderr" ? "! " : "› "}${payload?.line || ""}`;
    if (!line.trim()) return;
    logLines.push(line);
    if (logLines.length > LOG_LINE_LIMIT) {
      logLines.splice(0, logLines.length - LOG_LINE_LIMIT);
    }
    scheduleLogRender();
  }

  function appendLogLines(raw, stream = "stdout") {
    if (!raw) return;
    const lines = raw.split("\n").map((line) => `${stream === "stderr" ? "! " : "› "}${line}`);
    if (lines.length === 0) return;
    if (logLines.length + lines.length <= LOG_LINE_LIMIT) {
      logLines.push(...lines);
    } else {
      const cut = lines.length - (LOG_LINE_LIMIT - logLines.length);
      logLines.push(...lines.slice(Math.max(0, cut)));
    }
    if (logLines.length > LOG_LINE_LIMIT) {
      logLines.splice(0, logLines.length - LOG_LINE_LIMIT);
    }
    scheduleLogRender();
  }

  function syncProject() {
    const project = projects[Number(elements.projectList.value)] || null;
    if (project) selectProject(project, false, false);
  }

  async function chooseFolder() {
    if (running) return;
    if (!openDialog || !invoke) {
      setProjectState(text("desktopOnly"), "error");
      return;
    }
    try {
      const root = await openDialog({
        directory: true,
        multiple: false,
        title: text("chooseDialog")
      });
      if (!root) return;
      selectedProject = null;
      applySelectedProject();
      elements.projectPath.textContent = root;
      elements.projectChoice.hidden = true;
      setProjectState(text("detecting"));
      setPipeline("detect");
      const detected = await invoke("detect_projects", { root });
      projects.splice(0, projects.length, ...(Array.isArray(detected) ? detected : []));
      renderProjects();
    } catch {
      projects.splice(0);
      selectedProject = null;
      elements.projectChoice.hidden = true;
      saveCurrentProject(null);
      applySelectedProject();
      setPipeline("detect", true);
      setProjectState(text("detectFailed"), "error");
    }
  }

  function renderProjects() {
    elements.projectList.replaceChildren();
    projects.forEach((project, index) => {
      const option = document.createElement("option");
      option.value = String(index);
      option.textContent = `[${project.type}] ${project.path}`;
      elements.projectList.append(option);
    });
    if (projects.length === 0) {
      selectedProject = null;
      elements.projectChoice.hidden = true;
      elements.projectBadge.textContent = text("notDetected");
      setProjectState(text("noProjects"), "error");
      setPipeline("detect", true);
      return;
    }
    elements.projectChoice.hidden = projects.length === 1;
    elements.projectList.value = "0";
    syncScreen();
    setProjectState(
      projects.length === 1
        ? text("oneProject")
        : text("manyProjects", { count: projects.length }),
      "success"
    );
    syncProject();
  }

  function resetCopyFeedback() {
    if (copyFeedbackTimer) window.clearTimeout(copyFeedbackTimer);
    copyFeedbackTimer = null;
    elements.copyLog.className = "console-copy-button";
    elements.copyLog.textContent = text("copyLog");
    elements.copyLog.disabled = !elements.buildLog.textContent.trim();
    elements.copyLogStatus.textContent = "";
  }

  function showCopyFeedback(key, tone) {
    if (copyFeedbackTimer) window.clearTimeout(copyFeedbackTimer);
    const message = text(key);
    elements.copyLog.className = `console-copy-button ${tone}`;
    elements.copyLog.textContent = message;
    elements.copyLogStatus.textContent = message;
    copyFeedbackTimer = window.setTimeout(resetCopyFeedback, 1800);
  }

  async function writeClipboard(value) {
    if (navigator.clipboard?.writeText) {
      try {
        await navigator.clipboard.writeText(value);
        return;
      } catch {
        // Fall through for webviews where Clipboard API permission is unavailable.
      }
    }
    const textarea = document.createElement("textarea");
    textarea.value = value;
    textarea.setAttribute("readonly", "");
    textarea.style.position = "fixed";
    textarea.style.opacity = "0";
    document.body.append(textarea);
    textarea.select();
    try {
      if (!document.execCommand("copy")) throw new Error("copy failed");
    } finally {
      textarea.remove();
    }
  }

  async function copyBuildLog() {
    const value = elements.buildLog.textContent;
    if (!value.trim()) return;
    try {
      await writeClipboard(value);
      showCopyFeedback("logCopied", "success");
      track("log_copied");
    } catch {
      showCopyFeedback("logCopyFailed", "error");
    }
  }

  function updateElapsed() {
    const seconds = Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
    const minutes = String(Math.floor(seconds / 60)).padStart(2, "0");
    const remainder = String(seconds % 60).padStart(2, "0");
    elements.elapsed.textContent = `${minutes}:${remainder}`;
  }

  function setRunning(value) {
    running = value;
    elements.addProject.disabled = value;
    elements.chooseFolder.disabled = value;
    [...elements.versionBumps, ...elements.jobs].forEach((input) => {
      input.disabled = value;
    });
    elements.cleanBuild.disabled = value;
    elements.projectList.disabled = value;
    elements.removeCurrentProject.disabled = value;
    elements.localeOptions.forEach((button) => {
      button.disabled = value;
    });
    elements.buildHistory.querySelectorAll("button").forEach((button) => {
      button.disabled = value;
    });
    elements.outputFieldset.disabled = value || selectedProject?.type !== "flutter";
    elements.startBuild.hidden = value;
    elements.startBuild.disabled = value || !selectedProject;
    elements.cancelBuild.hidden = !value;
    if (value) {
      startedAt = Date.now();
      updateElapsed();
      timer = window.setInterval(updateElapsed, 1000);
    } else if (timer) {
      window.clearInterval(timer);
      timer = null;
    }
    syncScreen();
  }

  function renderResult(result) {
    lastBuildResult = result;
    const artifacts = result?.report?.results?.flatMap((item) => item.artifacts || []) || [];
    elements.buildResult.replaceChildren();
    const resultSummary = document.createElement("div");
    resultSummary.className = "build-result-summary";
    const summary = document.createElement("strong");
    summary.textContent = result.cancelled
      ? text("cancelled")
      : result.success
        ? text("succeeded")
        : text("failed", { code: result.exitCode ?? "?" });
    summary.className = result.success ? "result-success" : "result-error";
    resultSummary.append(summary);

    const artifactSummary = document.createElement("span");
    artifactSummary.textContent = artifacts.length
      ? text("artifacts", { count: artifacts.length })
      : text("noArtifacts");
    resultSummary.append(artifactSummary);
    elements.buildResult.append(resultSummary);
    for (const artifact of artifacts.slice(0, 8)) {
      const path = typeof artifact === "string" ? artifact : artifact.path;
      if (!path) continue;
      const row = document.createElement("div");
      row.className = "artifact-row";
      const item = document.createElement("code");
      item.textContent = path;
      const openButton = document.createElement("button");
      openButton.className = "artifact-open-button";
      openButton.type = "button";
      openButton.textContent = text("openFolder");
      openButton.addEventListener("click", async () => {
        if (!invoke) return;
        openButton.textContent = text("openFolder");
        openButton.classList.remove("error");
        openButton.disabled = true;
        try {
          await invoke("open_artifact_location", { path });
        } catch {
          openButton.textContent = text("openFolderFailed");
          openButton.classList.add("error");
        } finally {
          openButton.disabled = false;
        }
      });
      row.append(item, openButton);
      elements.buildResult.append(row);
    }
  }

  async function startBuild() {
    if (!invoke || !selectedProject || running) return;
    const project = { ...selectedProject };
    const settings = currentBuildSettings();
    resultProjectPath = project.path;
    let historyResult = "failed";
    logLines.splice(0);
    elements.buildLog.textContent = "";
    elements.logStatus.textContent = text("logStatus", {
      current: "0",
      total: String(LOG_LINE_LIMIT)
    });
    resetCopyFeedback();
    elements.buildResult.replaceChildren();
    lastBuildResult = null;
    setRunStatus("building", "running");
    setPipeline("build");
    setRunning(true);
    try {
      const result = await invoke("run_build", {
        request: {
          project: project.path,
          versionBump: settings.versionBump,
          outputs: project.type === "flutter" ? settings.outputs : [],
          jobs: settings.jobs,
          clean: settings.clean,
          locale,
          projectType: project.type
        }
      });
      if (logLines.length === 0) {
        if (result.stdout) appendLogLines(result.stdout, "stdout");
        if (result.stderr) appendLogLines(result.stderr, "stderr");
      }
      renderResult(result);
      historyResult = result.cancelled ? "cancelled" : result.success ? "success" : "failed";
      if (result.success) {
        setRunStatus("succeeded", "success");
        setPipeline("done");
        elements.pipeline.forEach((item) => item.className = "complete");
      } else {
        setRunStatus(result.cancelled ? "cancelled" : "failed", "error", { code: result.exitCode ?? "?" });
        setPipeline("build", true);
      }
    } catch {
      setRunStatus("buildError", "error");
      setPipeline("build", true);
      appendLog({ stream: "stderr", line: text("buildError") });
    } finally {
      setRunning(false);
      rememberBuild(project, settings, historyResult);
      refreshVersionPreview();
    }
  }

  async function cancelBuild() {
    if (!invoke || !running) return;
    elements.cancelBuild.disabled = true;
    setRunStatus("cancelling", "running");
    try {
      await invoke("cancel_build");
    } finally {
      elements.cancelBuild.disabled = false;
    }
  }

  async function initialize() {
    window.addEventListener("error", (event) => track("js_error", String(event.message || "error")));
    window.addEventListener("unhandledrejection", (event) => track("js_rejection", String(event.reason?.message || event.reason || "rejection")));
    applyLocale();
    setPipeline(null);
    renderHistory();
    const restoredPath = projectStore.selectedPath(storage, selectedProjectKey);
    const restored = savedProjects.find((project) => project.path === restoredPath) || savedProjects[0];
    if (restored) {
      selectProject(restored, false);
      setProjectState(text("projectSelected", { name: projectName(restored.path) }), "success");
    }
    elements.addProject.addEventListener("click", chooseFolder);
    elements.chooseFolder.addEventListener("click", chooseFolder);
    elements.removeCurrentProject.addEventListener("click", removeCurrentProject);
    elements.projectList.addEventListener("change", syncProject);
    elements.buildHistory.addEventListener("click", (event) => {
      const button = event.target.closest("button[data-index]");
      if (!button || running) return;
      const record = buildHistory[Number(button.dataset.index)];
      if (!record) return;
      selectProject({ path: record.path, type: record.type }, true, true, true);
    });
    elements.outputChecks.forEach((input) => {
      input.addEventListener("change", () => syncOutputChecks(input));
    });
    elements.versionBumps.forEach((input) => {
      input.addEventListener("change", refreshVersionPreview);
    });
    elements.startBuild.addEventListener("click", startBuild);
    elements.cancelBuild.addEventListener("click", cancelBuild);
    elements.copyLog.addEventListener("click", copyBuildLog);
    elements.localeOptions.forEach((button) => {
      button.addEventListener("click", () => selectLocale(button.dataset.locale));
    });
    if (listen) await listen("build-log", ({ payload }) => appendLog(payload));
    if (!invoke || !openDialog) setProjectState(text("desktopOnly"), "error");
    syncScreen();
  }

  initialize().catch((error) => setProjectState(String(error), "error"));
})();
