"use strict";

const $ = (id) => document.getElementById(id);
const keyFor = (code, index) => `${code}:${index}`;
const hexCode = (code) => `0x${code.toString(16).toUpperCase().padStart(2, "0")}`;

const sections = {
  connection: ["设备连接", "每个端点对应一个物理网口。"],
  management: ["管理接口", "管理 IPv4 或 UDP 端口变更后，上位机会尝试在新端点读回。"],
  ipv4: ["IPv4 地址", "按索引配置本机地址、MAC、网关与子网掩码。"],
  ipv6: ["IPv6 地址", "源地址表与目的地址表各自使用独立索引。"],
  udp: ["UDP 分流", "区间包含两端。多个业务区间重叠时，索引较小的区间优先。"],
  policy: ["ARP 与 ICMP", "设置 ARP 策略、免费 ARP 的发送范围和 ICMP 发送优先级。"],
  status: ["链路与错误", "显示最近一次读取的状态。错误记录可在「维护动作」中清除。"],
  actions: ["维护动作", "发送免费 ARP、清除状态或缓存，或恢复当前端口的默认值。"],
  log: ["UDP 报文日志", ""],
  audit: ["操作日志", "查看网页操作、服务处理结果和相关 UDP 收发。"],
  settings: ["设置", ""],
};
const tableGroups = {ipv4: "IPv4 地址表", ipv6_source: "源地址表", ipv6_destination: "目的地址表",
  udp: "UDP(IPV4) 接收区间表", udp_ipv6: "UDP(IPV6) 接收区间表", arp_announce: "免费 ARP 发送掩码"};
const statusNames = {TIMEOUT: "应答超时", BAD_OP: "操作码无效", BAD_ITEM: "配置项无效", BAD_INDEX: "索引越界", ACCESS_DENIED: "访问方式不支持", BAD_VALUE_LENGTH: "值长度无效"};
const arpClearStates = [
  "未完成",
  "缓存完成",
  "队列完成",
  "已完成",
];
const diagnostics = {
  LINK_STATE: {
    title: "网口链路",
    description: "查看物理网口的接收链路是否就绪。",
  },
  IP_TX_DROP_FLAGS: {
    title: "发送丢包",
    description: "设备记录了哪些类型的报文在发送前被丢弃。",
    checks: ["IPv4 发送丢包", "IPv6 发送丢包"],
  },
  ARP_ERROR_FLAGS: {
    title: "局域网地址解析（ARP）",
    description: "设备通过地址解析查找目标设备或网关的网卡地址。",
    checks: [
      "收到无法处理的地址解析报文",
      "接收地址解析应答的队列已满",
      "等待地址解析的报文队列已满",
      "查询使用了本口未配置的源 IP 地址",
    ],
  },
  ARP_CLEAR_STATE: {
    title: "ARP 清除状态",
    description: "查看已保存的网卡地址和等待查找地址的报文是否已清除。",
    checks: ["地址缓存", "等待查找地址的报文"],
  },
  ICMP_ERROR_FLAGS: {
    title: "ping 请求检查",
    description: "ping 用于测试网络连通性。可转发次数用完的请求会被丢弃。",
    checks: ["收到可转发次数已用完的请求"],
  },
};
const defaultSettings = {blockCrossPort: true, heartbeatEnabled: true, heartbeatInterval: 5};
const state = {
  meta: null, section: "connection", target: null, counts: {},
  values: new Map(), drafts: new Map(), reviews: new Map(), reviewTimers: new Map(), validationWarnings: new Map(),
  automaticPeer: null, busy: "", trace: [], selectedPacket: null, selectedField: null,
  lastReply: null, checkedAt: 0, noReply: false, recovery: null,
  settings: {...defaultSettings}, presets: [], presetEdit: null, lastHeartbeat: null,
};
const feedbackDuration = {success: 3200, warn: 6000, error: 8000};
const packetTime = new Intl.DateTimeFormat("zh-CN", {
  hour: "2-digit", minute: "2-digit", second: "2-digit", fractionalSecondDigits: 3, hourCycle: "h23",
});
let feedbackTimer;
let heartbeatTimer;
let heartbeatPending = false;

function node(tag, text, className) {
  const el = document.createElement(tag);
  if (text !== undefined) el.textContent = text;
  if (className) el.className = className;
  return el;
}

function control(text, handler) {
  const button = node("button", text, "button compact");
  button.type = "button";
  button.addEventListener("click", handler);
  return button;
}

function feedback(message = "", kind = "") {
  clearTimeout(feedbackTimer);
  const toast = $("feedback");
  toast.className = `feedback ${kind}`;
  toast.toggleAttribute("data-visible", Boolean(message));
  $("feedback-message").textContent = message;
  $("feedback-close").hidden = !message;
  if (message) {
    const outcome = {success: "ok", warn: "warning", error: "error"}[kind];
    OperationLog.record("ui.notice", {message}, {operation: state.auditOperation || OperationLog.current() || undefined, outcome});
    feedbackTimer = setTimeout(feedback, feedbackDuration[kind] ?? 4200);
  }
}

function record(entries = []) {
  if (!entries.length) return;
  state.trace = [...state.trace, ...entries].sort((a, b) => a.time - b.time).slice(-400);
  if (state.section === "log") renderLog(!state.selectedPacket);
}

function renderLog(scrollToEnd = false) {
  const log = $("packet-log");
  const top = log.scrollTop;
  const hideProbe = $("hide-probe-log").checked;
  const visible = state.trace.filter((entry) => !hideProbe || !entry.probeBoundary);
  const hidden = state.trace.length - visible.length;
  $("hidden-probe-count").textContent = hidden ? `（${hidden} 条）` : "";
  if (!visible.includes(state.selectedPacket)) {
    state.selectedPacket = null;
    state.selectedField = null;
  }
  log.replaceChildren();
  if (!visible.length) log.append(node("p", hidden ? "筛选后无记录" : "暂无收发记录", "empty"));
  for (const entry of visible) {
    const line = control("", () => {
      log.querySelector('[aria-pressed="true"]')?.setAttribute("aria-pressed", "false");
      line.setAttribute("aria-pressed", "true");
      state.selectedPacket = entry;
      state.selectedField = null;
      renderPacketDetails();
    });
    line.className = "packet";
    line.dataset.action = "udp-log.select";
    line.setAttribute("aria-pressed", String(state.selectedPacket === entry));
    line.append(node("time", packetTime.format(entry.time)), node("strong", entry.direction, entry.direction.toLowerCase()),
      node("span", entry.peer || "", "peer"), node("span", entry.hex || entry.text, "packet-data"));
    log.append(line);
  }
  log.scrollTop = scrollToEnd ? log.scrollHeight : top;
  $("clear-log").disabled = !state.trace.length;
  $("export-log").disabled = !state.trace.length;
  renderPacketDetails();
}

function renderPacketDetails() {
  const entry = state.selectedPacket;
  const summary = $("packet-summary");
  $("packet-details").hidden = !entry?.fields;
  if (!entry) {
    summary.textContent = "点击一条记录，查看配置协议字段和对应字节。";
    return;
  }
  if (!entry.fields) {
    summary.textContent = `${packetTime.format(entry.time)} · ${entry.target} · ${entry.text}`;
    return;
  }
  const bytes = entry.hex.split(" ");
  const validation = entry.validationError ? ` · 读回异常：${entry.validationError}` : "";
  summary.textContent = `${packetTime.format(entry.time)} · ${entry.direction === "TX" ? "发送至" : "接收自"} ${entry.peer} · ${bytes.length} 字节${validation}`;
  const hex = $("packet-bytes");
  hex.replaceChildren();
  const cells = bytes.map((byte) => node("span", byte.toUpperCase(), "packet-byte"));
  for (let offset = 0; offset < cells.length; offset += 8) {
    const row = node("div", undefined, "byte-row");
    row.append(node("span", offset.toString(16).padStart(2, "0"), "byte-offset"), ...cells.slice(offset, offset + 8));
    hex.append(row);
  }

  const fields = $("packet-fields");
  fields.replaceChildren();
  const buttons = entry.fields.map((field, index) => {
    const button = control("", () => selectField(state.selectedField === index ? null : index));
    button.className = "packet-field";
    button.dataset.action = "udp-log.field";
    const end = field.offset + field.size - 1;
    const offset = field.size === 1 ? field.offset : `${field.offset}–${end}`;
    button.append(node("span", `字节 ${offset}`, "field-offset"), node("strong", field.label), node("span", field.value, "mono"));
    return button;
  });
  fields.append(...buttons);
  function selectField(index) {
    state.selectedField = index;
    const field = entry.fields[index];
    buttons.forEach((button, position) => button.setAttribute("aria-pressed", String(index === position)));
    cells.forEach((cell, position) => cell.classList.toggle("highlighted", Boolean(field && position >= field.offset && position < field.offset + field.size)));
  }
  selectField(state.selectedField);
}

function exportLog() {
  if (!state.trace.length) return;
  const lines = state.trace.map((entry) =>
    [new Date(entry.time).toISOString(), entry.direction, entry.peer || entry.target, entry.hex || entry.text].filter(Boolean).join("  "));
  const file = new Blob([lines.join("\r\n"), "\r\n"], {type: "text/plain;charset=utf-8"});
  const link = node("a");
  link.href = URL.createObjectURL(file);
  link.download = "centenarian-udp.txt";
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(link.href), 0);
}

function observeReply(entries, target) {
  const relevant = entries?.filter((entry) => entry.target === target.join(":"));
  if (!relevant?.length) return;
  const replies = relevant.filter((entry) => entry.direction === "RX");
  if (replies.length) state.lastReply = Math.max(state.lastReply ?? 0, ...replies.map((entry) => entry.time));
  const checkedAt = Math.max(...relevant.map((entry) => entry.time));
  if (checkedAt >= state.checkedAt) {
    state.checkedAt = checkedAt;
    state.noReply = !replies.length;
  }
  if (replies.length && state.lastHeartbeat?.requestFailed && checkedAt >= state.lastHeartbeat.time) {
    state.lastHeartbeat = null;
    renderHeartbeatStatus();
  }
  updateConnectionStatus();
}

async function api(path, data, trackReply = true, signal, relatedOperation) {
  const active = state.target;
  const operation = relatedOperation || (path === "heartbeat" ? null : state.auditOperation || OperationLog.current()) || OperationLog.newId();
  const request = OperationLog.newId();
  let response;
  let result;
  try {
    response = await fetch(`/api/${path}`, data === undefined ? undefined : {
      method: "POST", headers: {"Content-Type": "application/json", "X-Cfg-Operation": operation, "X-Cfg-Request": request},
      body: JSON.stringify(data), signal,
    });
    result = await response.json();
  } catch (error) {
    OperationLog.record("ui.request_failed", {path, message: error.message, target: active},
      {operation, request, outcome: error.name === "AbortError" ? "cancelled" : "error"});
    throw error;
  }
  if (result.auditWarning) OperationLog.health(result.auditWarning);
  record(result.trace);
  if (trackReply && active && state.target === active && `${data?.host}:${data?.port}` === active.join(":")) {
    observeReply(result.trace, active);
  }
  if (!response.ok || result.error) throw new Error(result.error || `HTTP ${response.status}`);
  return result;
}

function targetBody() {
  return {host: state.target[0], port: state.target[1], blockCrossPort: state.settings.blockCrossPort};
}

function applyRows(rows) {
  for (const row of rows) state.values.set(keyFor(row.code, row.index), row);
}

function sectionItems(section = state.section) {
  return state.meta.items.filter((item) => item.group === section);
}

function sectionRows() {
  return sectionItems().filter((item) => item.access !== "exec").flatMap((item) => {
    const count = item.table ? state.counts[item.table] ?? 0 : 1;
    return Array.from({length: count}, (_, index) => ({code: item.code, index}));
  });
}

function summary(item) {
  const info = state.values.get(keyFor(item.code, 0));
  if (!info) return ["—", ""];
  if (info.status !== "OK") return [statusNames[info.status] || info.status, "error"];
  if (item.group === "management") return [info.value, "mono"];
  if (info.validation?.errors.length) return ["读回异常", "error"];
  const flags = Number(info.value);
  if (item.kind === "link") return flags ? ["已建立", "good"] : ["未建立", "warn"];
  if (item.code === 0x27) return [arpClearStates[flags] ?? "未知状态", flags === 3 ? "good" : ""];
  return flags ? ["有异常", "warn"] : ["无异常", "good"];
}

function appendReadbackValidation(value, validation) {
  if (validation?.errors.length) {
    value.append(node("div", `读回异常：${validation.errors.join(" ")}`, "field-error"));
  }
  if (validation?.warnings.length) {
    value.append(node("div", validation.warnings.join(" "), "field-warning"));
  }
}

function overviewRow(label, value, kind, validation) {
  const row = node("div", undefined, "overview-row");
  const details = node("dd", value, kind);
  appendReadbackValidation(details, validation);
  if (validation?.notes?.length) details.append(node("div", validation.notes.join(" "), "secondary"));
  row.append(node("dt", label), details);
  return row;
}

function renderOverview() {
  for (const group of ["management", "status"]) {
    $(`overview-${group}`).replaceChildren(...sectionItems(group).map((item) => {
      const reading = state.values.get(keyFor(item.code, 0));
      return overviewRow(item.label, ...summary(item), reading?.validation);
    }));
  }
  const tables = {
    ipv4: "IPv4 地址表",
    ipv6_source: "IPv6 源地址表",
    ipv6_destination: "IPv6 目的地址表",
    udp: "UDP(IPV4) 分流表",
    udp_ipv6: "UDP(IPV6) 分流表",
  };
  $("overview-tables").replaceChildren(...Object.entries(tables).map(([table, label]) => {
    const count = state.counts[table];
    const value = count == null ? (state.target ? "未探测到" : "—") : `${count} 项`;
    return overviewRow(label, value);
  }));
}

function renderDiagnostics(content) {
  content.classList.add("split");
  for (const item of sectionItems("status")) {
    const {title, description, checks} = diagnostics[item.name];
    const info = state.values.get(keyFor(item.code, 0));
    const card = node("article", undefined, "card diagnostic-card");
    const heading = node("div", undefined, "diagnostic-head");
    const [status, kind] = summary(item);
    const label = !info ? "尚未读取" : info.status === "OK" ? status
      : info.status === "TIMEOUT" ? "读取超时" : "读取失败";
    heading.append(node("h2", title), node("strong", label, `diagnostic-badge ${kind}`));
    card.append(heading, node("p", description));
    appendReadbackValidation(card, info?.validation);
    content.append(card);
    if (!checks || info?.status !== "OK" || info.validation?.errors.length) continue;

    const entries = node("dl");
    const flags = Number(info.value);
    const isClearState = item.name === "ARP_CLEAR_STATE";
    for (const [bit, check] of checks.entries()) {
      const set = Boolean(flags & (1 << bit));
      const text = isClearState ? (set ? "已完成" : "未完成") : (set ? "有记录" : "无记录");
      const color = isClearState ? (set ? "good" : "") : (set ? "warn" : "");
      entries.append(overviewRow(check, text, color));
    }
    card.append(entries);
  }
}

function updateConnectionStatus() {
  const pill = $("connection");
  const issue = state.lastHeartbeat?.requestFailed ? "心跳请求失败" : state.noReply ? "设备无应答" : "";
  const kind = state.busy ? "working" : issue ? "unresponsive" : state.target ? "online" : "";
  pill.className = `pill ${kind}`;
  pill.lastElementChild.textContent = state.busy || issue || state.target?.join(":") || "未连接";
  pill.title = state.target?.join(":") || "";
  const last = $("last-reply");
  last.hidden = state.lastReply === null;
  if (!last.hidden) {
    last.textContent = `最近应答 ${packetTime.format(state.lastReply)}`;
    last.dateTime = new Date(state.lastReply).toISOString();
  }
}

function updateControls() {
  const busy = Boolean(state.busy);
  const connected = Boolean(state.target);
  updateConnectionStatus();
  $("connect").textContent = connected ? "重新连接" : "连接设备";
  $("disconnect").hidden = !connected;
  for (const id of ["profile", "host", "port", "peer-host", "peer-port", "disconnect"]) $(id).disabled = busy || !state.meta;
  const validEndpoint = !busy && state.meta && validateEndpoint();
  $("connect").disabled = !validEndpoint;
  $("save-preset").hidden = $("profile").value !== "custom";
  $("save-preset").disabled = !validEndpoint;
  $("refresh-overview").disabled = busy || !connected;
  $("retry-tables").hidden = !connected || !Object.values(state.counts).some((count) => count == null);
  $("retry-tables").disabled = busy;
  $("probe-old").disabled = busy;
  $("probe-new").disabled = busy;
  $("config-tools").hidden = state.section === "actions";
  $("read-section").disabled = busy || !connected || !sectionRows().length;
  $("connection-required").hidden = connected;
  for (const control of $("navigation").querySelectorAll("button")) {
    control.disabled = busy || (!state.meta && control.dataset.section !== "audit");
  }
  for (const field of $("config-content").querySelectorAll("input, button")) {
    field.disabled = busy || !connected || field.dataset.unavailable === "true";
  }
}

function render() {
  if (!state.meta && state.section !== "audit") return;
  const [title, description] = sections[state.section];
  $("section-title").textContent = title;
  $("section-note").textContent = description;
  $("section-note").hidden = !description;
  const notices = state.validationWarnings.get(state.section) ?? [];
  $("validation-notice").textContent = notices.join(" ");
  $("validation-notice").hidden = !notices.length;
  $("read-section").textContent = state.section === "status" ? "刷新状态" : "读取本页";
  for (const entry of $("navigation").querySelectorAll("button")) {
    if (entry.dataset.section === state.section) entry.setAttribute("aria-current", "page");
    else entry.removeAttribute("aria-current");
  }
  const connection = state.section === "connection";
  const log = state.section === "log";
  const audit = state.section === "audit";
  const settings = state.section === "settings";
  $("connection-view").hidden = !connection;
  $("log-view").hidden = !log;
  $("audit-view").hidden = !audit;
  $("settings-view").hidden = !settings;
  $("config-view").hidden = connection || log || audit || settings;
  if (connection || log || audit || settings) $("config-content").replaceChildren();
  else renderSection();
  if (connection) {
    renderOverview();
    renderRecovery();
  }
  if (log) renderLog(!state.selectedPacket);
  if (settings) renderSettings();
  updateControls();
}

function renderSection() {
  const content = $("config-content");
  content.replaceChildren();
  if (state.section === "status") {
    renderDiagnostics(content);
    return;
  }
  const groups = new Map();
  for (const item of sectionItems()) {
    const name = item.table || (item.group === "policy" ? item.name.split("_")[0] : "");
    if (!groups.has(name)) groups.set(name, []);
    groups.get(name).push(item);
  }
  content.classList.toggle("split", groups.size > 1);
  for (const [name, items] of groups) {
    const table = items[0].table;
    const count = table ? state.counts[table] : 1;
    const group = node("div", undefined, "card config-group");
    content.append(group);
    if (table) group.append(tableHeading(table, count));
    else if (name) group.append(node("h2", name, "subhead"));
    if (!count) continue;
    if (state.section !== "actions") {
      const labels = node("div", undefined, "rows-title");
      labels.append(node("span", "配置项"), node("span", "读回值与输入"), node("span"));
      group.append(labels);
    }
    const showIndexInRow = table && items.length === 1;
    for (let index = 0; index < count; index++) {
      if (table && !showIndexInRow) group.append(node("h3", `索引 ${index}`, "index-heading"));
      for (const item of items) {
        const label = showIndexInRow ? `索引 ${index}` : item.label;
        group.append(item.access === "exec" ? actionRow(item) : parameterRow(item, index, label));
      }
    }
  }
}

function tableHeading(table, count) {
  const heading = node("div", undefined, "subhead");
  heading.append(node("h2", tableGroups[table]));
  if (count == null && state.target) heading.append(control("重探项数", () => retryTables([table])));
  else heading.append(node("span", count == null ? "项数待探测" : `${count} 项`, "secondary"));
  return heading;
}

function unsignedValue(text, label, min, max) {
  const value = text.trim();
  if (!/^(?:[0-9]+|0x[0-9a-f]+)$/i.test(value)) {
    throw new Error(`${label}须为非负整数，可使用十进制或以 0x 开头的十六进制。`);
  }
  const maxLength = Math.max(22, max.toString().length);
  if (value.length > maxLength) throw new Error(`${label}最多输入 ${maxLength} 个字符。`);
  const number = BigInt(value);
  if (number < min || number > max) throw new Error(`${label}必须在 ${min} 到 ${max} 之间。`);
  return number;
}

function ipv4Value(item, value) {
  const parts = value.split(".");
  const isMask = item.name === "IPV4_MASK";
  const example = isMask ? "255.255.255.0" : "192.168.1.9";
  if (parts.length !== 4 || !parts.every((part) => /^[0-9]+$/.test(part))) {
    throw new Error(`${item.label}须为点分隔的四段数字，如 ${example}。`);
  }
  if (parts.some((part) => Number(part) > 255)) throw new Error("IPv4 地址的每一段必须在 0 到 255 之间。");
  if (parts.some((part) => part.length > 1 && part.startsWith("0"))) throw new Error("IPv4 地址的各段不能带前导零。");
  if (isMask) {
    const mask = parts.reduce((number, part) => number * 256 + Number(part), 0);
    const zeroBits = 0xFFFFFFFF - mask;
    if ((zeroBits & (zeroBits + 1)) !== 0) {
      throw new Error("子网掩码的二进制位须由连续的 1 和随后的 0 组成，例如 255.255.255.0。");
    }
  }
  if (item.name === "MGMT_IPV4_ADDR") {
    const first = Number(parts[0]);
    if (value === "0.0.0.0" || value === "255.255.255.255" || (first >= 224 && first <= 239)) {
      throw new Error("管理 IPv4 必须是单播地址。0.0.0.0、广播地址和组播地址不能用于设备连接。");
    }
  }
  return value;
}

function normalizedValue(item, text, index = 0) {
  const value = text.trim();
  if (!value) throw new Error(`请输入${item.label}。`);
  switch (item.kind) {
    case "ipv4":
      return ipv4Value(item, value);
    case "mac":
      if (!/^(?:[0-9a-f]{2}:){5}[0-9a-f]{2}$/i.test(value)) {
        throw new Error("MAC 地址须为六组两位十六进制数并用冒号分隔，如 00:11:22:33:44:55。");
      }
      return value.toLowerCase();
    case "ipv6":
      if (value.includes("%")) throw new Error("IPv6 地址无需填写 % 后面的接口名称。");
      if (value.includes(":") && /^[0-9a-f:.]+$/i.test(value)) {
        try {
          return new URL(`http://[${value}]/`).hostname.slice(1, -1);
        } catch {
          // Fall through to the same format error as an invalid character.
        }
      }
      throw new Error("IPv6 地址格式无效。各段用冒号分隔，连续的零可用一次 :: 缩写，如 fe80::1。");
    case "range": {
      const parts = value.split("-");
      if (parts.length !== 2 || !parts.every((part) => part.trim())) {
        throw new Error("请输入起始端口和结束端口，中间用半角短横线分隔，如 1024-2048。");
      }
      const low = unsignedValue(parts[0], "起始端口", 0n, 65535n);
      const high = unsignedValue(parts[1], "结束端口", 0n, 65535n);
      if (low > high) throw new Error("起始端口不能大于结束端口。");
      return `${low}-${high}`;
    }
    case "port":
      return unsignedValue(value, "UDP 端口", 1n, 65535n).toString();
    case "timeout":
      return unsignedValue(value, item.label, 0n, BigInt(state.meta.pendingMax)).toString();
    case "priority":
      return unsignedValue(value, item.label, 0n, BigInt(state.meta.priorityMax)).toString();
    case "bitmask": {
      const count = state.counts.ipv4;
      if (count == null) throw new Error("请先探测本口 IPv4 地址表项数。");
      if (index !== 0) throw new Error("免费 ARP 掩码的索引必须为 0。");
      const bits = count + 1;
      if (bits > 128) throw new Error("免费 ARP 掩码最多支持 128 个 IPv4 地址（含管理地址）。");
      const mask = unsignedValue(value, item.label, 0n, (1n << BigInt(bits)) - 1n);
      const digits = Math.ceil(bits / 8) * 2;
      return `0x${mask.toString(16).toUpperCase().padStart(digits, "0")}`;
    }
    default:
      return value;
  }
}

function checkValue(item, input, index = 0) {
  try {
    return {value: normalizedValue(item, input, index), error: ""};
  } catch (error) {
    return {error: error.message};
  }
}

function showFieldError(input, messageElement, message) {
  input.setAttribute("aria-invalid", String(Boolean(message)));
  if (messageElement.textContent !== message) messageElement.textContent = message;
}

function validateEndpoint(prefix = "") {
  const endpoint = {};
  let valid = true;
  for (const [id, code] of [["host", 0x11], ["port", 0x12]]) {
    const input = $(`${prefix}${id}`);
    const item = state.meta.items.find((entry) => entry.code === code);
    const result = checkValue(item, input.value);
    showFieldError(input, $(`${prefix}${id}-error`), result.error);
    valid = valid && !result.error;
    endpoint[id] = result.value;
  }
  return valid ? endpoint : null;
}

function peerBody() {
  const host = $("peer-host").value.trim();
  const port = $("peer-port").value.trim();
  if (host || port) return validateEndpoint("peer-") ?? {host, port};
  for (const id of ["peer-host", "peer-port"]) showFieldError($(id), $(`${id}-error`), "");
  return state.automaticPeer;
}

function forgetReview(key) {
  clearTimeout(state.reviewTimers.get(key));
  state.reviewTimers.delete(key);
  state.reviews.delete(key);
}

function clearReviews() {
  for (const timer of state.reviewTimers.values()) clearTimeout(timer);
  state.reviewTimers.clear();
  state.reviews.clear();
}

function queueReview(item, index, input, update) {
  if (!state.target || !state.meta.conflictItems?.includes(item.code)) return;
  const key = keyFor(item.code, index);
  const operation = OperationLog.current() || OperationLog.newId();
  const target = state.target;
  const value = input.value;
  const timer = setTimeout(async () => {
    let review;
    try {
      ({review} = await api("check", {...targetBody(), peer: peerBody(), code: item.code, index, value}, true, undefined, operation));
    } catch {
      review = {errors: [], warnings: ["预检未完成，提交时会重新核对。"]};
    }
    if (state.reviewTimers.get(key) !== timer || state.target !== target || state.drafts.get(key) !== value) return;
    state.reviewTimers.delete(key);
    state.reviews.set(key, review);
    if (input.isConnected) update();
  }, 350);
  state.reviewTimers.set(key, timer);
}

function parameterRow(item, index, label) {
  const key = keyFor(item.code, index);
  const saved = state.values.get(key);
  const row = node("div", undefined, "parameter-row");
  const title = node("div", undefined, "parameter-name");
  title.append(node("strong", label), node("div", `${hexCode(item.code)} · ${item.name}`, "secondary mono"));
  const value = node("div", undefined, "parameter-value");
  const readback = saved?.bigEndian
    ? node("div", `读回 ${saved.bigEndian}`, "secondary mono readback") : null;
  row.append(title, value);

  const input = node("input", undefined, "mono");
  const fieldLabel = `${item.label}${item.table ? `，索引 ${index}` : ""}`;
  input.setAttribute("aria-label", fieldLabel);
  input.autocomplete = "off";
  input.spellcheck = false;
  input.maxLength = 64;
  input.placeholder = state.target ? "待读取" : "连接后可读写";
  const errorMessage = node("div", undefined, "field-error");
  errorMessage.id = `item-error-${item.code}-${index}`;
  errorMessage.setAttribute("aria-live", "polite");
  const warning = node("div", undefined, "field-warning");
  warning.id = `item-warning-${item.code}-${index}`;
  warning.setAttribute("aria-live", "polite");
  const note = node("div", undefined, "secondary field-note");
  note.id = `item-note-${item.code}-${index}`;
  note.setAttribute("aria-live", "polite");
  input.setAttribute("aria-describedby", `${errorMessage.id} ${warning.id} ${note.id}`);
  const original = saved?.value ?? "";
  const originalValue = checkValue(item, original, index).value;
  input.value = state.drafts.get(key) ?? original;
  const accept = control("确定", () => writeItem(item, index, input.value));
  accept.classList.add("primary");
  accept.setAttribute("aria-label", `确定${fieldLabel}`);
  const cancel = control("取消", () => {
    forgetReview(key);
    input.value = original;
    update();
    input.focus();
  });
  cancel.setAttribute("aria-label", `取消${fieldLabel}的修改`);
  for (const element of [input, accept, cancel]) {
    element.dataset.item = `CFG_${item.name}`;
    element.dataset.index = index;
  }
  const actions = node("div", undefined, "parameter-actions");
  actions.append(accept, cancel);
  const update = () => {
    const checked = checkValue(item, input.value, index);
    const dirty = input.value.trim() !== original && (Boolean(checked.error) || checked.value !== originalValue);
    const review = dirty && !checked.error ? state.reviews.get(key) : null;
    const error = dirty ? checked.error || review?.errors.join(" ") || "" : "";
    if (dirty) state.drafts.set(key, input.value);
    else state.drafts.delete(key);
    input.classList.toggle("edited", dirty);
    showFieldError(input, errorMessage, error);
    const caution = review?.warnings.join(" ") ?? "";
    if (warning.textContent !== caution) warning.textContent = caution;
    const information = (dirty ? review : saved?.validation)?.notes?.join(" ") ?? "";
    if (note.textContent !== information) note.textContent = information;
    const canEdit = dirty && state.target && !state.busy;
    accept.dataset.unavailable = String(!dirty || Boolean(error));
    accept.disabled = !canEdit || Boolean(error);
    cancel.dataset.unavailable = String(!dirty);
    cancel.disabled = !canEdit;
  };
  input.addEventListener("input", () => {
    forgetReview(key);
    update();
    if (state.drafts.has(key) && input.getAttribute("aria-invalid") === "false") queueReview(item, index, input, update);
  });
  update();
  value.append(input, errorMessage, warning);
  if (readback) value.append(readback);
  appendReadbackValidation(value, saved?.validation);
  value.append(note);
  const hint = item.kind === "timeout" ? `0–${state.meta.pendingMax} ms`
    : item.kind === "priority" ? `0–${state.meta.priorityMax}` : item.note;
  if (saved && saved.status !== "OK") value.append(node("div", statusNames[saved.status] || saved.status, "secondary"));
  else if (hint) value.append(node("div", hint, "secondary"));
  row.append(actions);
  return row;
}

function actionRow(item) {
  const row = node("div", undefined, `action-row${item.code === 0x16 ? " danger" : ""}`);
  const description = node("div");
  description.append(node("h3", item.label), node("p", item.note));
  const execute = control("执行", () => executeAction(item));
  execute.setAttribute("aria-label", `执行${item.label}`);
  execute.dataset.item = `CFG_${item.name}`;
  row.append(description, execute);
  return row;
}

async function run(label, operation, id = OperationLog.current() || OperationLog.newId()) {
  if (state.busy) return;
  state.busy = label;
  state.auditOperation = id;
  OperationLog.record("ui.operation", {label}, {operation: id});
  feedback();
  updateControls();
  try {
    await operation();
  } catch (error) {
    feedback(error.message, "error");
  } finally {
    state.auditOperation = null;
    state.busy = "";
    render();
  }
}

function resetConnection() {
  state.target = null;
  state.counts = {};
  state.automaticPeer = null;
  state.lastReply = null;
  state.checkedAt = 0;
  state.noReply = false;
  state.lastHeartbeat = null;
  scheduleHeartbeat();
  state.validationWarnings.clear();
  clearReviews();
  state.values.clear();
  state.drafts.clear();
}

function fillTarget(host, port) {
  $("host").value = host;
  $("port").value = port;
}

function factoryProfile(host, port) {
  return Object.entries(state.meta.profiles).find(([, pair]) => pair[0] === host && pair[1] === port)?.[0] || "custom";
}

function currentProfile(host, port) {
  const matches = state.presets.filter((preset) => preset.host === host && preset.port === port);
  return matches.find((preset) => preset.id === $("profile").value)?.id ?? matches[0]?.id ?? "custom";
}

function preferencesKey() {
  return state.meta.demo ? "centenarian-console-demo-v1" : "centenarian-console-v1";
}

function loadPreferences() {
  const defaults = Object.entries(state.meta.profiles).map(([id, [host, port]]) => ({id, name: `${id} 口`, host, port}));
  state.presets = defaults;
  let saved;
  try {
    saved = JSON.parse(localStorage.getItem(preferencesKey()));
  } catch {
    return;
  }
  const settings = saved?.settings;
  if (settings) {
    const {heartbeatInterval: interval} = settings;
    state.settings = {
      blockCrossPort: settings.blockCrossPort !== false,
      heartbeatEnabled: settings.heartbeatEnabled !== false,
      heartbeatInterval: Number.isInteger(interval) && interval >= 1 && interval <= 300
        ? interval : defaultSettings.heartbeatInterval,
    };
  }
  if (!Array.isArray(saved?.presets)) return;

  const hostItem = state.meta.items.find((item) => item.code === 0x11);
  const portItem = state.meta.items.find((item) => item.code === 0x12);
  const presets = new Map();
  for (const preset of saved.presets) {
    if (typeof preset?.id !== "string" || !preset.id || preset.id === "custom" || typeof preset.name !== "string"
        || typeof preset.host !== "string" || !Number.isInteger(preset.port)) continue;
    const name = preset.name.trim();
    if (!name || name.length > 32 || checkValue(hostItem, preset.host).error
        || checkValue(portItem, String(preset.port)).error) continue;
    presets.set(preset.id, {...preset, name, host: preset.host.trim()});
  }
  state.presets = Array.from(presets.values());
}

function persistPreferences(message) {
  try {
    localStorage.setItem(preferencesKey(), JSON.stringify({settings: state.settings, presets: state.presets}));
    feedback(message, "success");
  } catch {
    feedback("浏览器本地存储不可用，本次改动仅在当前页面有效。", "warn");
  }
}

function renderPresetOptions(preferred) {
  const select = $("profile");
  const current = preferred ?? currentProfile($("host").value.trim(), Number($("port").value.trim()));
  select.replaceChildren(...state.presets.map((preset) => new Option(preset.name, preset.id)), new Option("自定义", "custom"));
  select.value = current;
}

function openPreset(preset) {
  const endpoint = preset ?? validateEndpoint();
  if (!endpoint) return;
  state.presetEdit = {id: preset?.id, host: endpoint.host, port: Number(endpoint.port)};
  $("preset-dialog-title").textContent = preset ? "重命名端口预设" : "保存端口预设";
  $("preset-endpoint").textContent = `${endpoint.host}:${endpoint.port}`;
  $("preset-name").value = preset?.name ?? "";
  $("preset-name").setCustomValidity("");
  $("preset-dialog").showModal();
}

function savePreset() {
  const input = $("preset-name");
  const name = input.value.trim();
  input.setCustomValidity(name ? "" : "请输入预设名称。");
  if (!input.reportValidity() || !state.presetEdit) return;
  const {id, host, port} = state.presetEdit;
  const preset = {id: id ?? crypto.randomUUID(), name, host, port};
  if (id) state.presets = state.presets.map((entry) => entry.id === id ? preset : entry);
  else state.presets.push(preset);
  $("preset-dialog").close();
  renderPresetOptions(id ? undefined : preset.id);
  if (state.section === "settings") renderPresets();
  updateControls();
  persistPreferences(id ? "预设已重命名。" : "端口预设已保存。");
}

function renderPresets() {
  const list = $("preset-list");
  list.replaceChildren();
  if (!state.presets.length) list.append(node("p", "暂无端口预设", "settings-note"));
  for (const preset of state.presets) {
    const row = node("div", undefined, "preset-row");
    const details = node("div");
    details.append(node("strong", preset.name), node("span", `${preset.host}:${preset.port}`, "mono secondary"));
    const actions = node("div", undefined, "preset-actions");
    const rename = control("重命名", () => openPreset(preset));
    rename.setAttribute("aria-label", `重命名预设 ${preset.name}`);
    const remove = control("删除", () => {
      state.presets = state.presets.filter((entry) => entry.id !== preset.id);
      renderPresetOptions();
      renderPresets();
      updateControls();
      persistPreferences("端口预设已删除。");
    });
    remove.setAttribute("aria-label", `删除预设 ${preset.name}`);
    actions.append(rename, remove);
    row.append(details, actions);
    list.append(row);
  }
}

function renderHeartbeatStatus() {
  const status = $("heartbeat-status");
  if (!state.settings.heartbeatEnabled) status.textContent = "心跳已关闭";
  else if (!state.target) status.textContent = "连接设备后开始检测";
  else if (!state.lastHeartbeat) status.textContent = "等待首次心跳";
  else status.textContent = `${state.lastHeartbeat.text} · ${packetTime.format(state.lastHeartbeat.time)}`;
}

function renderSettings() {
  $("block-cross-port").checked = state.settings.blockCrossPort;
  $("heartbeat-enabled").checked = state.settings.heartbeatEnabled;
  $("heartbeat-interval").value = state.settings.heartbeatInterval;
  showFieldError($("heartbeat-interval"), $("heartbeat-interval-error"), "");
  renderHeartbeatStatus();
  renderPresets();
}

function saveSettings() {
  const interval = $("heartbeat-interval");
  const seconds = Number(interval.value);
  if (!/^[0-9]+$/.test(interval.value) || seconds < 1 || seconds > 300) {
    showFieldError(interval, $("heartbeat-interval-error"), "请输入 1 到 300 之间的整数秒数。");
    return;
  }
  state.settings = {blockCrossPort: $("block-cross-port").checked,
    heartbeatEnabled: $("heartbeat-enabled").checked, heartbeatInterval: seconds};
  state.lastHeartbeat = null;
  clearReviews();
  scheduleHeartbeat();
  renderSettings();
  updateConnectionStatus();
  persistPreferences("设置已保存。");
}

function scheduleHeartbeat() {
  clearTimeout(heartbeatTimer);
  if (state.settings.heartbeatEnabled && state.target && !heartbeatPending) {
    heartbeatTimer = setTimeout(checkHeartbeat, state.settings.heartbeatInterval * 1000);
  }
}

async function checkHeartbeat() {
  if (!state.target || !state.settings.heartbeatEnabled || state.busy) {
    scheduleHeartbeat();
    return;
  }
  const target = state.target;
  const settings = state.settings;
  heartbeatPending = true;
  try {
    const result = await api("heartbeat", targetBody(), false, AbortSignal.timeout(3000));
    if (state.target !== target || state.settings !== settings) return;
    const [link] = result.rows;
    const latest = Math.max(0, ...result.trace.map((entry) => entry.time));
    if (!state.busy && latest >= state.checkedAt) {
      applyRows(result.rows);
      if (state.section === "connection") renderOverview();
      if (state.section === "status") renderSection();
    }
    observeReply(result.trace, target);
    let text;
    if (link.status === "TIMEOUT") text = "设备无应答";
    else if (link.status !== "OK" || link.validation?.errors.length) text = "链路状态读回异常";
    else text = Number(link.value) ? "物理链路已建立" : "物理链路未建立";
    state.lastHeartbeat = {text, time: latest || Date.now()};
    renderHeartbeatStatus();
  } catch {
    if (state.target === target && state.settings === settings) {
      state.lastHeartbeat = {text: "心跳请求失败", time: Date.now(), requestFailed: true};
      renderHeartbeatStatus();
      updateConnectionStatus();
    }
  } finally {
    heartbeatPending = false;
    scheduleHeartbeat();
  }
}

function updateCounts(tables) {
  for (const [table, count] of Object.entries(tables)) {
    state.counts[table] = Number.isInteger(count) && count >= 1 && count <= 254 ? count : null;
  }
}

function adoptTarget(target, result, automaticPeer = null) {
  resetConnection();
  state.recovery = null;
  state.target = target;
  const profile = factoryProfile(...target);
  const other = Object.entries(state.meta.profiles).find(([name]) => name !== profile);
  state.automaticPeer = profile !== "custom" && other ? {host: other[1][0], port: other[1][1]} : automaticPeer;
  updateCounts(result.counts);
  applyRows(result.rows);
  state.validationWarnings.set("connection", result.validationWarnings ?? []);
  observeReply(result.trace, target);
  fillTarget(...target);
  $("profile").value = currentProfile(...target);
  scheduleHeartbeat();
}

async function connect() {
  if (!state.meta || state.busy) return;
  const endpoint = validateEndpoint();
  if (!endpoint) return;
  const {host, port} = endpoint;
  await run("正在连接", async () => {
    const target = [host, Number(port)];
    const result = await api("probe", {host, port: target[1], peer: peerBody(), blockCrossPort: state.settings.blockCrossPort});
    adoptTarget(target, result);
    if (Object.values(state.counts).some((count) => count == null)) {
      feedback("设备已响应，部分表项数量未能读出。可重探未读表项。", "warn");
    } else {
      feedback(`${state.target.join(":")} 已响应。`, "success");
    }
  });
}

function renderRecovery() {
  const recovery = state.recovery;
  $("endpoint-recovery").hidden = !recovery;
  if (!recovery) return;
  $("old-endpoint").textContent = recovery.old.join(":");
  $("new-endpoint").textContent = recovery.new.join(":");
  $("recovery-message").textContent = recovery.message;
}

async function recoverEndpoint(which) {
  const recovery = state.recovery;
  if (!recovery) return;
  const target = recovery[which];
  const [host, port] = target;
  await run("正在探测端点", async () => {
    try {
      const result = await api("probe", {host, port, peer: peerBody() ?? recovery.automaticPeer,
        blockCrossPort: state.settings.blockCrossPort});
      const mac = result.rows.find((row) => row.code === 0x10)?.value;
      if (!mac || mac !== recovery.expectedMac) {
        recovery.message = mac ? `${target.join(":")} 返回的管理 MAC 为 ${mac}，与原设备不同。`
          : `${target.join(":")} 已应答，管理 MAC 读取失败。`;
        return;
      }
      adoptTarget(target, result, recovery.automaticPeer);
      feedback(`已确认设备身份并连接 ${target.join(":")}。`, "success");
    } catch (error) {
      recovery.message = `${target.join(":")} · ${error.message}`;
    }
  });
}

async function readRows(items) {
  let failures = 0;
  const trace = [];
  const warnings = new Set();
  const target = state.target;
  const limit = state.meta.readLimit ?? state.meta.items.length;
  try {
    for (let start = 0; start < items.length; start += limit) {
      const result = await api("read", {...targetBody(), peer: peerBody(), items: items.slice(start, start + limit)}, false);
      trace.push(...result.trace);
      applyRows(result.rows);
      for (const warning of result.validationWarnings ?? []) warnings.add(warning);
      failures += result.rows.filter((row) => row.status !== "OK" || row.validation?.errors.length).length;
    }
  } finally {
    if (state.target === target) {
      state.validationWarnings.set(state.section, Array.from(warnings));
      observeReply(trace, target);
    }
  }
  return failures;
}

async function retryTables(tables) {
  if (!state.target || !tables.length) return;
  await run("正在探测表项", async () => {
    const result = await api("probe-tables", {...targetBody(), tables});
    updateCounts(result.counts);
    const recovered = tables.filter((table) => state.counts[table] != null);
    const items = sectionRows().filter(({code}) =>
      recovered.includes(state.meta.items.find((item) => item.code === code).table));
    const failures = await readRows(items);
    const remaining = tables.length - recovered.length;
    if (remaining) feedback(`仍有 ${remaining} 张表的项数未探测到。`, "warn");
    else if (failures) feedback(`项数已确认，${failures} 项读取或校验未通过。`, "warn");
    else feedback("配置表项数已确认。", "success");
  });
}

async function refreshOverview() {
  if (!state.target) return;
  const items = [...sectionItems("management"), ...sectionItems("status")].map((item) => ({code: item.code, index: 0}));
  await run("正在刷新", async () => {
    const failures = await readRows(items);
    feedback(failures ? `${failures} 项概况读取或校验未通过。` : "设备概况已刷新。", failures ? "warn" : "success");
  });
}

async function loadSection(onlyMissing = false) {
  if (!state.target || state.section === "actions") return;
  const items = sectionRows().filter(({code, index}) => !onlyMissing || !state.values.has(keyFor(code, index)));
  if (!items.length) return;
  await run("正在读取", async () => {
    const failures = await readRows(items);
    if (state.section === "status") {
      feedback(failures ? `${failures} 项状态读取或校验未通过。` : "状态已刷新。", failures ? "warn" : "success");
    } else {
      feedback(failures ? `${failures} 项读取或校验未通过，请查看各行。` : `已读取 ${items.length} 项。`, failures ? "warn" : "success");
    }
  });
}

function confirmOperation(title, description, operation, details) {
  const dialog = $("confirm");
  dialog.dataset.operation = operation;
  $("confirm-title").textContent = title;
  $("confirm-note").textContent = description;
  dialog.returnValue = "cancel";
  dialog.showModal();
  return new Promise((resolve) => dialog.addEventListener("close", () => {
    const confirmed = dialog.returnValue === "ok";
    delete dialog.dataset.operation;
    OperationLog.record("ui.confirmation", {title, ...details, confirmed}, {operation, outcome: confirmed ? "ok" : "cancelled"});
    resolve(confirmed);
  }, {once: true}));
}

async function writeItem(item, index, value) {
  if (!state.target || state.busy) return;
  const operation = OperationLog.current() || OperationLog.newId();
  const {error} = checkValue(item, value, index);
  if (error) {
    feedback(error, "warn");
    return;
  }
  if (item.group === "management" && !await confirmOperation(`确认修改${item.label}`,
    `设备 ${state.target.join(":")} 将立即应用 ${value.trim()}。管理参数变更可能暂时中断通信。`,
    operation, {item: `CFG_${item.name}`, index, value})) return;
  const key = keyFor(item.code, index);
  forgetReview(key);
  await run("正在写入", async () => {
    const result = await api("write", {...targetBody(), peer: peerBody(), code: item.code, index, value});
    if (result.status === "CONFLICT") {
      state.reviews.set(key, result.review);
      feedback("发现配置冲突，请查看该项下方的原因。", "warn");
      return;
    }
    if (result.status !== "OK" && result.status !== "TIMEOUT") {
      feedback(`设备拒绝写入 · ${statusNames[result.status] || result.status}`, "error");
      return;
    }
    const moved = result.nextTarget.join(":") !== state.target.join(":");
    if (moved) {
      fillTarget(...result.nextTarget);
      $("profile").value = currentProfile(...result.nextTarget);
      if (!result.verified) {
        state.recovery = {
          old: state.target, new: result.nextTarget, expectedMac: result.expectedMac,
          automaticPeer: state.automaticPeer,
          message: result.verificationError || "新端点读回未确认。探测端点会读取配置并核对原设备的管理 MAC。",
        };
        resetConnection();
        state.section = "connection";
        return;
      }
      state.target = result.nextTarget;
      state.lastReply = null;
      state.checkedAt = 0;
      state.noReply = false;
      state.lastHeartbeat = null;
      observeReply(result.trace, state.target);
      scheduleHeartbeat();
    }
    if (result.readback) applyRows([result.readback]);
    if (result.verified) {
      clearReviews();
      state.drafts.delete(key);
      const prefix = result.status === "OK" ? "写入成功，读回" : "写入应答超时，已读回";
      const label = item.table ? `${item.label}（索引 ${index}）` : item.label;
      const warnings = [...(result.review?.warnings ?? []), ...(result.readback.validation?.errors ?? [])];
      if (state.meta.conflictItems?.includes(item.code)) {
        try {
          if (await readRows(sectionRows())) warnings.push("本页有配置项读取或校验未通过。");
        } catch {
          warnings.push("本页未能完成重新校验。");
        }
      }
      feedback(`${prefix} ${label} ${result.readback.value}。${warnings.join(" ")}`, warnings.length ? "warn" : "success");
    } else if (result.readback?.status === "OK") {
      feedback(`读回值为 ${result.readback.value}，与写入值不同。`, "warn");
    } else {
      feedback(result.status === "OK" ? "设备已应答，读回失败。" : "写入应答与读回均失败，结果待核对。", "warn");
    }
  }, operation);
}

async function executeAction(item) {
  if (!state.target || state.busy) return;
  const operation = OperationLog.current() || OperationLog.newId();
  if (!await confirmOperation(item.label, `${state.target.join(":")} · ${item.note}`, operation, {item: `CFG_${item.name}`})) return;
  await run("正在执行", async () => {
    const result = await api("action", {...targetBody(), code: item.code});
    if (result.status !== "OK" && result.status !== "TIMEOUT") {
      feedback(`设备拒绝执行 · ${statusNames[result.status] || result.status}`, "error");
      return;
    }
    if (item.code === 0x16) {
      resetConnection();
      feedback(result.status === "OK" ? "设备已确认恢复。请选择对应网口的出厂端点并重新连接。"
        : "设备未应答，恢复结果待核对。请在该网口的出厂端点重新连接。", result.status === "OK" ? "success" : "warn");
      return;
    }
    if (item.name === "ARP_ANNOUNCE_SEND") {
      feedback(result.status === "OK" ? "设备已保存本次免费 ARP 发送请求。"
        : "设备未应答，发送请求是否已接收待核对。", result.status === "OK" ? "success" : "warn");
      return;
    }
    if (result.status === "TIMEOUT") {
      feedback("设备未应答，执行结果待核对。可在「链路与错误」页刷新状态。", "warn");
      return;
    }
    const failures = await readRows(sectionItems("status").map((entry) => ({code: entry.code, index: 0})));
    feedback(`${item.label}已获应答。${failures ? ` ${failures} 项状态读取或校验未通过。` : ""}`, failures ? "warn" : "success");
  }, operation);
}

function initializeTheme() {
  const key = "centenarian-theme";
  const buttons = document.querySelectorAll("[data-theme-choice]");
  const apply = (theme) => {
    document.documentElement.dataset.theme = theme;
    for (const button of buttons) {
      button.setAttribute("aria-pressed", String(button.dataset.themeChoice === theme));
    }
  };

  let theme = "light";
  try {
    if (localStorage.getItem(key) === "dark") theme = "dark";
  } catch {
    // The theme can still be switched when browser storage is unavailable.
  }
  apply(theme);
  for (const button of buttons) {
    button.addEventListener("click", () => {
      const selected = button.dataset.themeChoice;
      apply(selected);
      try {
        localStorage.setItem(key, selected);
      } catch {
        // The current page has already applied the selection.
      }
    });
  }
}

async function boot() {
  updateControls();
  try {
    state.meta = await api("meta");
    loadPreferences();
    const first = state.meta.demo ? null : state.presets[0];
    fillTarget(...(first ? [first.host, first.port] : state.meta.profiles.A));
    renderPresetOptions();
    if (state.meta.demo) {
      $("mode").classList.add("demo");
      $("mode").textContent = "虚拟设备";
    }
    render();
    if (state.meta.demo) await connect();
  } catch (error) {
    feedback(`无法读取上位机接口 · ${error.message}`, "error");
  }
}

$("navigation").addEventListener("click", (event) => {
  const button = event.target.closest("button[data-section]");
  if (!button || state.busy || button.dataset.section === state.section) return;
  state.section = button.dataset.section;
  feedback();
  render();
  if (state.section === "connection") refreshOverview();
  else if (state.section === "audit") OperationLog.load();
  else if (state.section === "settings") OperationLog.settings();
  else loadSection(!sectionItems().some((item) => state.meta.conflictItems?.includes(item.code)));
});
$("connection-form").addEventListener("submit", (event) => { event.preventDefault(); connect(); });
$("profile").addEventListener("change", () => {
  const preset = state.presets.find((entry) => entry.id === $("profile").value);
  if (preset) fillTarget(preset.host, preset.port);
  resetConnection();
  feedback();
  render();
});
$("save-preset").addEventListener("click", () => openPreset());
$("preset-form").addEventListener("submit", (event) => { event.preventDefault(); savePreset(); });
$("preset-name").addEventListener("input", () => $("preset-name").setCustomValidity(""));
$("cancel-preset").addEventListener("click", () => $("preset-dialog").close());
$("preset-dialog").addEventListener("close", () => { state.presetEdit = null; });
$("settings-form").addEventListener("submit", (event) => { event.preventDefault(); saveSettings(); });
$("heartbeat-interval").addEventListener("input", () => showFieldError($("heartbeat-interval"), $("heartbeat-interval-error"), ""));
for (const id of ["host", "port"]) $(id).addEventListener("input", () => {
  $("profile").value = currentProfile($("host").value.trim(), Number($("port").value.trim()));
  if (state.target) {
    resetConnection();
    feedback("端点已编辑，请重新连接。");
    render();
  } else {
    updateControls();
  }
});
$("disconnect").addEventListener("click", () => { resetConnection(); feedback(); render(); });
$("refresh-overview").addEventListener("click", refreshOverview);
$("retry-tables").addEventListener("click", () => retryTables(Object.keys(state.counts).filter((table) => state.counts[table] == null)));
$("probe-old").addEventListener("click", () => recoverEndpoint("old"));
$("probe-new").addEventListener("click", () => recoverEndpoint("new"));
for (const id of ["peer-host", "peer-port"]) $(id).addEventListener("input", () => {
  clearReviews();
  peerBody();
});
$("read-section").addEventListener("click", () => {
  clearReviews();
  loadSection();
});
$("feedback-close").addEventListener("click", () => feedback());
$("clear-log").addEventListener("click", () => { state.trace = []; renderLog(); });
$("export-log").addEventListener("click", exportLog);
$("hide-probe-log").addEventListener("change", () => renderLog());
OperationLog.setContext(() => ({page: state.section, target: state.target}));
OperationLog.record("ui.opened", {label: document.title});
initializeTheme();
boot();
