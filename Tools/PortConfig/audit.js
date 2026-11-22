"use strict";

const OperationLog = (() => {
  const el = (id) => document.getElementById(id);
  const url = "/api/audit/";
  const newId = () => Array.from(crypto.getRandomValues(new Uint8Array(16)), (byte) => byte.toString(16).padStart(2, "0")).join("");
  const session = newId();
  const names = {ui: "网页", server: "上位机服务", udp: "UDP"};
  const outcomes = {ok: "完成", warning: "需核对", error: "失败", cancelled: "取消"};
  const labels = {
    "ui.click": "点击", "ui.change": "修改", "ui.submit": "提交", "ui.notice": "操作结果", "ui.operation": "开始操作",
    "ui.confirmation": "确认操作", "ui.opened": "打开上位机", "ui.exception": "网页异常",
    "ui.request_failed": "网页请求失败", "ui.section_toggle": "栏目展开状态", "ui.audit_export": "导出操作日志",
    "bridge.started": "服务启动", "api.started": "处理请求", "api.finished": "请求结果",
    "api.rows": "设备读回", "audit.capacity": "设置日志上限",
  };
  let context = () => ({});
  let active = null;
  let queue = [];
  let sending;
  let timer;
  let entries = [];
  let cursor = null;
  let filterOperation = "";
  let selected = null;
  let loading = false;
  const edits = new Map();
  const lastEdit = new WeakMap();

  function health(message = "") {
    const status = el("audit-health");
    status.textContent = message;
    status.hidden = !message;
  }

  function record(event, details, {operation = active || newId(), request, outcome} = {}) {
    queue.push({session, operation, request, event, outcome, clientEvent: newId(), time: new Date().toISOString(), ...context(), details});
    clearTimeout(timer);
    timer = setTimeout(flush, 120);
  }

  async function flush() {
    clearTimeout(timer);
    if (sending) return sending;
    if (!queue.length) return true;
    sending = (async () => {
      while (queue.length) {
        const batch = queue.splice(0, 12);
        try {
          await request("events", {events: batch});
        } catch {
          queue.unshift(...batch);
          health("操作日志暂未保存。请检查上位机服务和日志目录。");
          timer = setTimeout(flush, 3000);
          return false;
        }
      }
      health();
      return true;
    })().finally(() => { sending = undefined; });
    return sending;
  }

  async function request(path, body, operation) {
    const response = await fetch(url + path, body === undefined ? undefined : {
      method: "POST", headers: {"Content-Type": "application/json", "X-Cfg-Operation": operation || newId()},
      body: JSON.stringify(body), keepalive: path === "events",
    });
    if (!response.ok) {
      const result = await response.json().catch(() => ({}));
      throw new Error(result.error || `HTTP ${response.status}`);
    }
    return response.json();
  }

  function activate(id = newId()) {
    active = id;
    setTimeout(() => { if (active === id) active = null; }, 0);
    return id;
  }

  function controlDetails(target) {
    return {control: target.id || target.dataset.section || target.dataset.action || target.name || target.tagName,
            label: (target.getAttribute("aria-label") || target.textContent).trim().slice(0, 240),
            item: target.dataset.item, index: target.dataset.index};
  }

  function inputValue(control) {
    return control.type === "checkbox" ? control.checked : String(control.value).slice(0, 512);
  }

  function commitEdit(control, operation) {
    clearTimeout(edits.get(control)?.timer);
    edits.delete(control);
    const value = inputValue(control);
    if (lastEdit.get(control) === value) return;
    lastEdit.set(control, value);
    record("ui.change", {...controlDetails(control), value}, {operation});
  }

  function text(tag, value, className) {
    const node = document.createElement(tag);
    node.textContent = value;
    if (className) node.className = className;
    return node;
  }

  function describe(entry) {
    const detail = entry.details || {};
    const data = detail.data || {};
    const parts = [labels[entry.event] || entry.event];
    if (entry.source === "ui") parts.push(data.label || data.control || data.message || detail.page);
    if (entry.source === "server") parts.push(detail.action, detail.rtlItem, detail.status || detail.error);
    if (entry.source === "udp") parts.push(detail.command?.rtlItem, detail.peer || detail.target,
      detail.statusCode == null ? "" : `0x${detail.statusCode.toString(16).padStart(2, "0")}`);
    return parts.filter(Boolean).join(" · ");
  }

  function showDetails(entry) {
    selected = entry;
    el("audit-detail-hint").hidden = Boolean(entry);
    el("audit-detail-actions").hidden = !entry;
    el("audit-related").disabled = !entry?.operation;
    el("audit-detail-json").hidden = !entry;
    el("audit-detail-json").textContent = entry ? JSON.stringify(entry, null, 2) : "";
  }

  function renderEntries() {
    const list = el("audit-list");
    list.replaceChildren();
    if (!entries.length) list.append(text("p", "暂无匹配记录", "settings-note"));
    for (const entry of [...entries].sort((left, right) => right.time.localeCompare(left.time))) {
      const row = text("button", "", "audit-row");
      row.type = "button";
      row.setAttribute("aria-pressed", String(entry.id === selected?.id));
      row.append(text("time", new Date(entry.time).toLocaleString("zh-CN", {hour12: false}) + entry.time.slice(19, 23), "mono"),
        text("span", names[entry.source] || entry.source), text("strong", describe(entry)),
        text("span", outcomes[entry.outcome] || "", `audit-outcome ${entry.outcome || ""}`));
      row.addEventListener("click", () => {
        list.querySelector('[aria-pressed="true"]')?.setAttribute("aria-pressed", "false");
        row.setAttribute("aria-pressed", "true");
        showDetails(entry);
      });
      list.append(row);
    }
    el("audit-older").hidden = !cursor;
  }

  async function load(older = false) {
    if (loading) return;
    loading = true;
    const changed = ["audit-source", "audit-refresh", "audit-unfilter", "audit-related", "audit-older"];
    for (const id of changed) el(id).disabled = true;
    const status = el("audit-status");
    status.textContent = "正在读取操作日志…";
    try {
      await flush();
      const query = new URLSearchParams({source: el("audit-source").value, operation: filterOperation, before: older ? cursor : ""});
      const result = await request(`events?${query}`);
      entries = older ? entries.concat(result.entries) : result.entries;
      cursor = result.next;
      showDetails(entries.find((entry) => entry.id === selected?.id) || null);
      renderEntries();
      status.textContent = result.expired ? "部分旧记录已轮换，请刷新。" : `已显示 ${entries.length} 条记录`;
    } catch (error) {
      status.textContent = error.message;
    } finally {
      loading = false;
      for (const id of changed) el(id).disabled = false;
      el("audit-related").disabled = !selected?.operation;
    }
  }

  function filterBy(operation) {
    filterOperation = operation;
    el("audit-filter").hidden = !operation;
    el("audit-filter-label").textContent = operation ? `操作 ${operation}` : "";
    if (operation) el("audit-source").value = "";
    return load();
  }

  function showSettings(settings) {
    el("audit-capacity").value = settings.maxMiB;
    el("audit-capacity").max = settings.maxAllowedMiB;
    el("audit-capacity").disabled = false;
    el("audit-save").disabled = false;
    el("audit-storage").textContent = `已用 ${(settings.sizeBytes / 1048576).toFixed(2)} / ${settings.maxMiB} MiB`;
    el("audit-path").textContent = settings.path;
  }

  async function settings() {
    try {
      showSettings(await request("settings"));
    } catch (error) {
      el("audit-storage").textContent = error.message;
    }
  }

  document.addEventListener("click", (event) => {
    const control = event.target.closest("button, summary, a[href]");
    if (!control || control.disabled) return;
    activate(control.closest("dialog[data-operation]")?.dataset.operation);
    record("ui.click", controlDetails(control));
  }, true);
  document.addEventListener("change", (event) => {
    const control = event.target;
    if (!control.matches("input, select, textarea") || control.type === "password") return;
    commitEdit(control, activate(edits.get(control)?.operation));
  }, true);
  document.addEventListener("input", (event) => {
    const control = event.target;
    if (!control.matches('input:not([type="checkbox"], [type="password"]), textarea')) return;
    clearTimeout(edits.get(control)?.timer);
    const operation = activate();
    edits.set(control, {operation, timer: setTimeout(() => commitEdit(control, operation), 500)});
  }, true);
  document.addEventListener("submit", (event) => {
    if (event.target.method === "dialog") return;
    if (!active) activate();
    const fields = Array.from(event.target.elements).filter((control) => control.id && control.matches("input, select, textarea") && control.type !== "password");
    record("ui.submit", {control: event.target.id, fields: Object.fromEntries(fields.map((control) => [control.id, inputValue(control)]))});
  }, true);
  document.addEventListener("toggle", (event) => {
    if (event.target instanceof HTMLDetailsElement) record("ui.section_toggle", {
      ...controlDetails(event.target.querySelector("summary")), open: event.target.open,
    });
  }, true);
  window.addEventListener("error", (event) => record("ui.exception", {
    message: event.message, file: event.filename, line: event.lineno, stack: event.error?.stack?.slice(0, 4000),
  }, {outcome: "error"}));
  window.addEventListener("unhandledrejection", (event) => record("ui.exception", {
    message: String(event.reason), stack: event.reason?.stack?.slice(0, 4000),
  }, {outcome: "error"}));
  window.addEventListener("pagehide", () => {
    for (const [control, {operation}] of edits) commitEdit(control, operation);
    if (!queue.length) return;
    while (queue.length) {
      const payload = new Blob([JSON.stringify({events: queue.slice(0, 12)})], {type: "application/json"});
      if (!navigator.sendBeacon(url + "events", payload)) break;
      queue.splice(0, 12);
    }
  });

  el("audit-refresh").addEventListener("click", () => load());
  el("audit-source").addEventListener("change", () => load());
  el("audit-older").addEventListener("click", () => load(true));
  el("audit-related").addEventListener("click", () => filterBy(selected?.operation || ""));
  el("audit-unfilter").addEventListener("click", () => filterBy(""));
  el("audit-copy").addEventListener("click", async () => {
    if (!selected) return;
    const operation = active;
    try {
      await navigator.clipboard.writeText(JSON.stringify(selected, null, 2));
      el("audit-status").textContent = "已复制操作详情。";
      record("ui.notice", {message: "已复制操作详情。"}, {operation, outcome: "ok"});
    } catch {
      el("audit-status").textContent = "无法复制，可选中详情复制或导出日志。";
      record("ui.notice", {message: "浏览器拒绝写入剪贴板。"}, {operation, outcome: "warning"});
    }
  });
  el("audit-download").addEventListener("click", async () => {
    record("ui.audit_export", {format: "jsonl"});
    if (!await flush()) return;
    const link = text("a", "");
    link.href = url + "download";
    link.download = "centenarian-operations.jsonl";
    link.click();
  });
  el("audit-settings-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const operation = active || newId();
    el("audit-save").disabled = true;
    try {
      const result = await request("settings", {maxMiB: Number(el("audit-capacity").value)}, operation);
      showSettings(result);
      record("ui.notice", {message: "日志设置已保存。"}, {operation, outcome: "ok"});
    } catch (error) {
      el("audit-storage").textContent = error.message;
      record("ui.notice", {message: error.message}, {operation, outcome: "error"});
    } finally {
      el("audit-save").disabled = false;
    }
  });

  return {record, newId, current: () => active, load, settings, health, setContext: (getter) => { context = getter; }};
})();
