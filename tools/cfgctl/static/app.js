/* ═══════════════════════════════════════════════════════════════════
   Centenarian 配置上位机 · 前端逻辑
   零依赖原生 JS。所有 ITEM 语义来自后端 /api/meta，前端不硬编码编号。
   ═══════════════════════════════════════════════════════════════════ */
'use strict';

// ─────────── 全局状态 ───────────
const S = {
  meta: null,          // 后端元数据
  items: [],           // ITEM 列表
  byCode: new Map(),   // code -> item meta
  connected: false,
  host: '',            // 设备 IP
  udpPort: 0,          // 命令通道的 UDP 端口号（不是网口索引！）
  portNum: 0,          // 网口总数
  geom: {},            // port -> [9] 几何原始字节
  view: 'overview',
  group: 'addr',       // 配置页当前分组
  snapshot: {},        // "item:port:set" -> {text, display, raw}
  dirty: new Set(),    // 已改但未写的 key
  dirtyText: new Map(),// key -> 用户输入的文本（用于写后收敛 dirty 标记）
  logCount: 0,
  es: null,            // EventSource
};

// ─────────── 工具 ───────────
const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => Array.from(document.querySelectorAll(sel));
const key = (item, port, set) => `${item}:${port}:${set}`;

function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function toast(msg, kind = 'info', ms = 3600) {
  const el = document.createElement('div');
  el.className = `toast ${kind}`;
  el.textContent = msg;
  $('#toasts').appendChild(el);
  setTimeout(() => {
    el.style.transition = 'opacity .25s, transform .25s';
    el.style.opacity = '0';
    el.style.transform = 'translateX(14px)';
    setTimeout(() => el.remove(), 260);
  }, ms);
}

function setBusy(on) { $('#busy-veil').hidden = !on; }


// 统计位图 → 一句人话（列出置位的原因；全 0 则说"无异常"）
function statBrief(snap, item) {
  if (!snap || !snap.raw) return '—';
  const v = hexToLeInt(snap.raw);
  const defs = (S.meta.stat_bits && S.meta.stat_bits[String(item)]) || [];
  const hits = defs.filter((d) => (v >> d.bit) & 1);
  if (!hits.length) return '无异常（全 0）';
  return hits.map((d) => d.short).join('；');
}

// 把 VALUE 的 hex 串按【小端整数】解析（协议里数值类都是小端）
// 例：ARP_STAT 4 字节 raw="48000000" → 0x00000048
function hexToLeInt(hex) {
  if (!hex) return 0;
  const b = [];
  for (let i = 0; i + 1 < hex.length; i += 2) b.push(parseInt(hex.substr(i, 2), 16));
  let v = 0;
  for (let i = b.length - 1; i >= 0; i--) v = v * 256 + b[i];
  return v;
}


// ─────────── API ───────────
async function api(path, opts = {}) {
  const res = await fetch(path, {
    headers: { 'Content-Type': 'application/json' },
    ...opts,
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  let data;
  try { data = await res.json(); }
  catch { throw new Error(`HTTP ${res.status}：响应不是 JSON`); }
  if (!res.ok && !data.error) throw new Error(`HTTP ${res.status}`);
  if (data.error) {
    const e = new Error(data.error);
    e.payload = data;
    throw e;
  }
  return data;
}

// ─────────── 模态框 ───────────
let modalResolve = null;
function confirmModal(title, body, okText = '确认执行') {
  $('#modal-title').textContent = title;
  $('#modal-body').innerHTML = body;
  $('#modal-ok').textContent = okText;
  $('#modal-wrap').hidden = false;
  return new Promise((res) => { modalResolve = res; });
}
function closeModal(v) {
  $('#modal-wrap').hidden = true;
  if (modalResolve) { modalResolve(v); modalResolve = null; }
}
$('#modal-cancel').onclick = () => closeModal(false);
$('#modal-ok').onclick = () => closeModal(true);
$('#modal-wrap').addEventListener('click', (e) => {
  if (e.target === $('#modal-wrap')) closeModal(false);
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && !$('#modal-wrap').hidden) closeModal(false);
  if (e.key === 'Enter' && !$('#modal-wrap').hidden) closeModal(true);
});

// ─────────── 连接 ───────────
function setLinkState(kind, text) {
  const el = $('#link-state');
  el.className = `link-state ${kind}`;
  el.querySelector('.txt').textContent = text;
  // 主按钮恒为「连接 / 重新连接」（改 IP 后点它即可重连到另一台设备）；
  // 断开用旁边的独立 ✕，避免一个按钮承担两种语义
  const btn = $('#btn-connect');
  btn.textContent = kind === 'online' ? '重新连接' : '连接';
  // 已连接时主按钮降级为次要样式 —— 让顶栏的注意力回到内容上
  btn.classList.toggle('primary', kind !== 'online');
  $('#btn-disconnect').hidden = kind !== 'online';
}

async function doConnect() {
  const host = $('#host').value.trim();
  if (!host) { toast('请填写设备 IP', 'warn'); return; }
  let port;
  try {
    port = parseInt($('#udpport').value.trim(), 0);
  } catch {
    toast('端口需为整数（可写 0xC0DE）', 'warn');
    return;
  }
  if (!Number.isFinite(port) || port <= 0 || port > 65535) {
    toast('UDP 端口需在 1~65535', 'warn'); return;
  }
  const timeout = 0.2;          // 固定 200ms：够局域网用，重试由客户端做

  setLinkState('busy', '连接中…');
  $('#btn-connect').disabled = true;
  try {
    // 已连接时先断开再连：允许改 IP / 端口后重连到另一台设备
    if (S.connected) {
      try { await api('/api/disconnect', { method: 'POST' }); } catch { /* 忽略 */ }
      S.connected = false;
    }
    const r = await api('/api/connect', {
      method: 'POST',
      body: { host, port, timeout },
    });
    S.connected = true;
    S.host = r.host; S.udpPort = r.port;
    S.portNum = r.port_num || 0;
    S.geom = r.geom || {};
    setLinkState('online', `已连接 ${r.host}:${r.port}`);
    $('#btn-connect').disabled = false;
    toast(`已连接 ${r.host}:${r.port}`, 'ok');
    await refreshOverview();
    await readAll();
    switchView(S.view);
  } catch (e) {
    S.connected = false;
    setLinkState('error', '连接失败');
    $('#btn-connect').disabled = false;
    toast(e.message, 'err', 8000);
  }
}

async function doDisconnect() {
  try { await api('/api/disconnect', { method: 'POST' }); } catch { /* 忽略 */ }
  S.connected = false;
  S.snapshot = {};
  S.dirty.clear();
  S.dirtyText.clear();
  updateDirtyNote();
  setLinkState('offline', '未连接');
  $('#btn-connect').disabled = false;
  toast('已断开', 'info');
  refreshOverview();
  switchView(S.view);
}

// 主按钮：连接 / 重新连接（后端会先断再连，可改 IP/端口后连到别的设备）
$('#btn-connect').onclick = doConnect;
$('#btn-disconnect').onclick = doDisconnect;
$('#host').addEventListener('keydown', (e) => { if (e.key === 'Enter') doConnect(); });
$('#udpport').addEventListener('keydown', (e) => { if (e.key === 'Enter') doConnect(); });

// ─────────── 导航 ───────────
function switchView(view) {
  S.view = view;
  $$('.nav-item').forEach((b) => b.classList.toggle('active', b.dataset.view === view));

  const isCfg = ['addr', 'route', 'behavior', 'status', 'stat', 'bound'].includes(view);
  $('#view-overview').hidden = view !== 'overview';
  $('#view-config').hidden = !isCfg;
  $('#view-actions').hidden = view !== 'actions';
  $('#view-raw').hidden = view !== 'raw';

  if (isCfg) { S.group = view; renderConfig(); }
  if (view === 'actions') renderActions();
}
$$('.nav-item').forEach((b) => { b.onclick = () => switchView(b.dataset.view); });

// ─────────── 槽位切换 ───────────
// 每个 ITEM 单独记一个当前槽（不同 ITEM 档数不同，共用一个槽号会串）
const slotSel = new Map();   // "code:port" -> slot index

function slotsOf(itemMeta, port) {
  if (!itemMeta.indexed) return 1;
  const g = S.geom[String(port)];
  if (!g) return 1;
  // 字段名由后端给出（/api/meta 的 slot_field），前端不硬编码 ITEM→字段的映射
  const field = itemMeta.slot_field;
  if (!field) return 1;
  const idx = S.meta.geometry_fields.indexOf(field);
  if (idx < 0 || idx >= g.length) return 1;
  return Math.max(1, g[idx]);
}

// ─────────── 配置页渲染 ───────────
function renderConfig() {
  const title = $('#cfg-title');
  const grp = S.meta.groups.find((g) => g.key === S.group);
  title.textContent = grp ? grp.label : '配置';

  const host = $('#cfg-groups');
  // 「写入修改」出现条件：该分组可写，或全局还有别的分组留下的待写入项
  // （改完地址页切到统计页，仍要有办法把改动提交上去）
  const writable = S.items.some((it) => it.group === S.group && it.mode !== 'r');
  $('#btn-cfg-write').hidden = !(writable || S.dirty.size);
  // 边界页的三个协议项（GEOMETRY / GEOMETRY_MAX / PORT_NUM）不单独列行 ——
  // 它们的内容已被下方「配置能力表」完整覆盖（逐字段 × 各口 + 全局上限），
  // 重复展示同一批数字只会让人两边对看。
  const BOUND_COVERED = new Set([0x70, 0x71, 0x72]);
  const items = S.items.filter((it) => it.group === S.group &&
    !(S.group === 'bound' && BOUND_COVERED.has(it.code)));
  if (!items.length && S.group !== 'bound') {
    host.innerHTML = '<div class="panel"><div class="empty">该分组暂无条目</div></div>';
    return;
  }

  // 按每口分节
  const ports = S.portNum > 1 ? Array.from({ length: S.portNum }, (_, i) => i) : [0];
  let html = '';

  for (const p of ports) {
    const rows = items.map((it) => renderItem(it, p)).join('');
    if (!rows) continue;
    html += `<div class="cfg-group">
      <div class="cfg-group-head">
        <h2>${esc(grp ? grp.label : '')}</h2>
        ${ports.length > 1 ? `<span class="count">网口 ${p}</span>` : ''}
      </div>
      <div class="cfg-list">${rows}</div>
    </div>`;
  }
  host.innerHTML = html;
  bindConfigEvents();

  // 边界页额外挂一张「能力表」，把每个数字的含义讲清楚
  const isBound = (S.group === 'bound');
  $('#bound-extra').hidden = !isBound;
  if (isBound) {
    const pn = S.snapshot[key(0x72, 0, 0)];
    $('#bound-ports').textContent = pn ? pn.text : (S.portNum || '—');
    renderGeometryTable();
  }
}

function renderItem(it, port) {
  const nSlots = slotsOf(it, port);
  const isRO = it.mode === 'r';
  const isAction = it.mode === 'w';

  // 动作类不放在配置页渲染
  if (isAction) return '';

  // 全局项（per_port=false）只在口 0 出现一次
  if (!it.per_port && port !== 0) return '';

  // 槽位按钮
  let slotTabs = '';
  if (nSlots > 1) {
    const cur = slotSel.get(`${it.code}:${port}`) || 0;
    let tabs = '';
    for (let s = 0; s < nSlots; s++) {
      tabs += `<button class="slot-tab${s === cur ? ' active' : ''}"
        data-item="${it.code}" data-port="${port}" data-slot="${s}">${s}</button>`;
    }
    slotTabs = `<div class="slot-tabs">${tabs}</div>`;
  }
  const curSlot = nSlots > 1 ? (slotSel.get(`${it.code}:${port}`) || 0) : 0;
  const k = key(it.code, port, curSlot);
  const snap = S.snapshot[k];
  const dirty = S.dirty.has(k);

  // 值区：可写项用编辑器（未读回时也允许直接输入），只读项用纯文本
  let valHtml;
  if (isRO) {
    if (!snap) {
      valHtml = '<span class="ro-none">未读取</span>';
    } else if (snap.status && !snap.status.startsWith('OK')) {
      valHtml = `<span class="ro-value" style="color:var(--danger)">${esc(snap.status)}</span>`;
    } else {
      // 只读项用 fmt_value：带格式化与含义（如 ARP_STAT 显示成 0x00000000 ← 原因）
      valHtml = `<span class="ro-value">${esc(snap.text || snap.display || '—')}</span>`;
    }
  } else {
    valHtml = editorFor(it, snap);
  }

  // 行内操作：写按钮紧贴它作用的值（不单独占一列，避免大片空白）
  // 未改动时按钮极淡 —— 有改动才亮起，形成渐进披露
  const failed = snap && snap.status && !snap.status.startsWith('OK');
  const ops = `${failed ? `<button class="icon-btn retry" title="读回失败，重试"
        data-act="read" data-item="${it.code}" data-port="${port}"
        data-set="${curSlot}">↻</button>` : ''}
      ${isRO ? '' : `<button class="icon-btn write${DANGER_ITEMS[it.code] ? ' danger' : ''}"
        title="写入此项" data-act="write" data-item="${it.code}" data-port="${port}"
        data-set="${curSlot}" ${dirty ? '' : 'disabled'}>↑</button>`}`;

  // 只读项：额外展开这个数值代表什么（来自 /api/meta 的 readonly_hints）
  let hintHtml = '';
  if (isRO) {
    const hint = (S.meta.readonly_hints || {})[String(it.code)];
    if (hint) hintHtml = `<div class="item-hint">${esc(hint)}</div>`;
    // TX_ACTIVE 展开成通道表
    if (it.code === 0x54) {
      const lanes = S.meta.tx_lanes || [];
      const cur = snap && snap.raw ? (hexToLeInt(snap.raw) & 0x07) : null;
      hintHtml += '<div class="lane-list">' + lanes.map((l) => `
        <div class="lane-row${cur === l.idx ? ' cur' : ''}">
          <span class="lane-idx">lane${l.idx}</span>
          <div class="lane-txt"><b>${esc(l.name)}</b><span>${esc(l.desc)}</span></div>
        </div>`).join('') + '</div>';
    }
  }

  // 编辑器
  const editHtml = valHtml;

  // 统计位展开
  let bitsHtml = '';
  if (it.editor === 'stat') {
    const defs = (S.meta.stat_bits && S.meta.stat_bits[String(it.code)])
      || (it.code === 0x60 ? S.meta.arp_stat_bits : S.meta.icmp_stat_bits) || [];
    const v = (snap && snap.raw) ? hexToLeInt(snap.raw) : null;
    const isLevel = (d) => (d.level === 'level');
    const rows = defs.map((d) => {
      const on = v !== null && ((v >> d.bit) & 1);
      const lvl = isLevel(d);
      return `<div class="bit-row${on ? ' set' : ''}${lvl ? ' level' : ''}">
        <span class="bit-led"></span>
        <span class="b">bit${d.bit}</span>
        <div class="bit-txt">
          <div class="bit-short">${esc(d.short || d.desc || '')}
            ${lvl ? '<span class="bit-kind">电平状态</span>' : ''}</div>
          <div class="bit-desc">${esc(d.desc || '')}</div>
          ${d.src ? `<div class="bit-src">${esc(d.src)}</div>` : ''}
        </div>
        <span class="bit-state">${v === null ? '未读' : (on ? '置位' : '未置位')}</span>
      </div>`;
    }).join('');

    // 摘要要把「电平位（恒 1，不值得关注）」和「事件位（真异常）」分开说
    let sum = '';
    if (v !== null) {
      const evDefs = defs.filter((d) => !isLevel(d));
      const lvDefs = defs.filter((d) => isLevel(d));
      const evHits = evDefs.filter((d) => (v >> d.bit) & 1);
      const lvHits = lvDefs.filter((d) => (v >> d.bit) & 1);
      const evTxt = evHits.length
        ? evHits.map((d) => d.short).join('；')
        : '无（该口没有记录到真实异常事件）';
      const lvTxt = lvHits.length
        ? `${lvHits.length} 个电平状态位为 1（属正常现象，不代表发生过异常）`
        : '电平状态位均未置位';
      sum = `<div class="bit-summary">
        <div class="bs-row real">
          <span class="bs-k">真实异常</span>
          <span class="bs-v">${esc(evTxt)}</span>
        </div>
        <div class="bs-row aux">
          <span class="bs-k">电平状态</span>
          <span class="bs-v">${esc(lvTxt)}</span>
        </div>
      </div>`;
    }
    bitsHtml = `<div class="bit-list">${sum}${rows}</div>`;
  }

  // hint / bits 用 grid-column:1/-1 跨到下一行，因此必须与三列同处一个 grid
  return `<div class="cfg-row${dirty ? ' dirty' : ''}" data-key="${k}">
      <div class="cfg-name" title="${esc(it.desc)}">
        <span class="cn">${esc(it.name)}</span>
        ${isRO ? '<span class="tag r">只读</span>' : ''}
        ${slotTabs}
        <span class="cd">${esc(it.desc)}</span>
      </div>
      <div class="cfg-val item-edit" data-item="${it.code}" data-port="${port}" data-set="${curSlot}">
        ${editHtml}
        <div class="cfg-ops">${ops}</div>
      </div>
      ${hintHtml}${bitsHtml}
    </div>`;
}

// 危险项提示
const DANGER_ITEMS = {
  0x33: '改的是命令通道自己的端口，改错将无法再连接设备。',
  0x34: '改成 0 会让应答发不出去。',
};

// ─────────── 各类编辑器 ───────────
function editorFor(it, snap) {
  const val = snap ? (snap.text ?? '') : '';
  const dis = snap ? '' : 'placeholder="读回后显示"';
  switch (it.editor) {
    case 'ipv4':
      return `<input type="text" class="ip4" value="${esc(val)}" ${dis}
        placeholder="192.168.1.9" spellcheck="false">`;
    case 'ipv6':
      return `<input type="text" class="ip6" value="${esc(val)}" ${dis}
        placeholder="fe80::1" spellcheck="false">`;
    case 'mac':
      return `<input type="text" class="mac" value="${esc(val)}" ${dis}
        placeholder="00:19:31:00:00:01" spellcheck="false">`;
    case 'hex8':
      return `<input type="text" class="hex" value="${esc(val)}" ${dis}
        placeholder="0x06" spellcheck="false">`;
    case 'hex16':
      return `<input type="text" class="hex" value="${esc(val)}" ${dis}
        placeholder="0x88B5" spellcheck="false">`;
    case 'range':
      return `<input type="text" class="range" value="${esc(val)}" ${dis}
        placeholder="2-8" spellcheck="false">`;
    case 'prio':
      return `<select class="prio" ${snap ? '' : 'disabled'}>
        ${Array.from({ length: 16 }, (_, i) => `<option value="${i}"
          ${String(i) === String(val) ? 'selected' : ''}>${i}${i === 0 ? '（禁用）' : ''}</option>`).join('')}
      </select>`;
    case 'port':
      return `<input type="text" class="port" value="${esc(val)}" ${dis}
        placeholder="0xC0DE" spellcheck="false">`;
    case 'cycles':
      return `<input type="text" class="num" value="${esc(val)}" ${dis}
        placeholder="400000000" spellcheck="false">
        <span class="unit" data-unit-for="cycles"></span>`;
    default:
      return `<input type="text" class="num" value="${esc(val)}" ${dis}
        placeholder="—" spellcheck="false">`;
  }
}

// ─────────── 配置页事件 ───────────
function bindConfigEvents() {
  // 槽位切换
  $$('.slot-tab').forEach((b) => {
    b.onclick = () => {
      slotSel.set(`${b.dataset.item}:${b.dataset.port}`, parseInt(b.dataset.slot, 10));
      renderConfig();
    };
  });

  // 输入 → 标记 dirty + 本地校验
  $$('.item-edit input, .item-edit select').forEach((el) => {
    const wrap = el.closest('.item-edit');
    const item = S.byCode.get(parseInt(wrap.dataset.item, 10));
    const k = key(item.code, parseInt(wrap.dataset.port, 10), parseInt(wrap.dataset.set, 10));

    const mark = () => {
      const cur = (S.snapshot[k] && S.snapshot[k].text) || '';
      const now = el.value;
      if (now === cur) { S.dirty.delete(k); S.dirtyText.delete(k); }
      else { S.dirty.add(k); S.dirtyText.set(k, now); }
      const row = el.closest('.cfg-row');
      row.classList.toggle('dirty', S.dirty.has(k));
      // 写按钮仅在有改动时可用
      const wb = row.querySelector('[data-act="write"]');
      if (wb) wb.disabled = !S.dirty.has(k);
      validate(el, item);
      updateUnit(el, item);
      updateDirtyNote();
    };
    el.addEventListener('input', mark);
    el.addEventListener('change', mark);
    if (el.tagName === 'SELECT') el.addEventListener('change', mark);
    if (el.value) { validate(el, item); updateUnit(el, item); }
  });

  // 读 / 写
  $$('[data-act="read"]').forEach((b) => { b.onclick = () => doRead(b); });
  $$('[data-act="write"]').forEach((b) => { b.onclick = () => doWrite(b); });
}

// 顶部提示「N 项待写入」
function updateDirtyNote() {
  const el = $('#dirty-note');
  if (!el) return;
  const n = S.dirty.size;
  el.hidden = n === 0;
  el.textContent = n ? `${n} 项待写入` : '';
}

// ─────────── 本地校验 ───────────
function validate(el, item) {
  if (!item || item.mode === 'r') return true;
  const v = el.value.trim();
  let ok = true;
  if (v === '') { ok = true; }
  else if (item.editor === 'ipv4') {
    ok = /^\d{1,3}(\.\d{1,3}){3}$/.test(v) &&
         v.split('.').every((p) => parseInt(p, 10) <= 255);
  } else if (item.editor === 'ipv6') {
    ok = /^[0-9a-fA-F:]+$/.test(v) && v.includes(':');
  } else if (item.editor === 'mac') {
    ok = /^[0-9a-fA-F]{2}([:-][0-9a-fA-F]{2}){5}$/.test(v) ||
         /^[0-9a-fA-F]{12}$/.test(v);
  } else if (item.editor === 'hex8') {
    ok = /^0x[0-9a-fA-F]{1,2}$/.test(v);
  } else if (item.editor === 'hex16') {
    ok = /^0x[0-9a-fA-F]{1,4}$/.test(v);
  } else if (item.editor === 'range') {
    const m = v.match(/^(\d+)\s*-\s*(\d+)$/);
    ok = !!m && parseInt(m[1], 10) <= parseInt(m[2], 10) &&
         parseInt(m[2], 10) <= 65535;
  } else if (item.editor === 'prio') {
    ok = true;
  } else if (item.editor === 'port') {
    ok = /^(0x[0-9a-fA-F]+|\d+)$/.test(v) && parseInt(v, 0) <= 65535;
  } else if (item.editor === 'cycles') {
    ok = /^\d+$/.test(v);
  } else {
    ok = /^(0x[0-9a-fA-F]+|\d+)$/.test(v);
  }
  el.classList.toggle('invalid', !ok);
  return ok;
}

function updateUnit(el, item) {
  if (!item) return;
  const unit = el.parentElement.querySelector('.unit');
  if (!unit) return;
  if (item.editor === 'cycles') {
    const n = parseInt(el.value, 10);
    unit.textContent = Number.isFinite(n) && n >= 0
      ? `周期 ≈ ${(n / 400000000).toFixed(3)} s` : '';
  } else unit.textContent = '';
}

// ─────────── 读 / 写 ───────────
async function doRead(btn) {
  const code = parseInt(btn.dataset.item, 10);
  const port = parseInt(btn.dataset.port, 10);
  const set = parseInt(btn.dataset.set, 10);
  btn.disabled = true;
  try {
    const r = await api('/api/read', {
      method: 'POST',
      body: { items: [{ item: code, port, set }] },
    });
    applyRows(r.rows);
    toast(`${S.byCode.get(code).name} 已读回`, 'ok', 1800);
  } catch (e) {
    toast(`读失败：${e.message}`, 'err', 6000);
  } finally {
    btn.disabled = false;
  }
}

async function doWrite(btn) {
  const code = parseInt(btn.dataset.item, 10);
  const port = parseInt(btn.dataset.port, 10);
  const set = parseInt(btn.dataset.set, 10);
  const item = S.byCode.get(code);
  const wrap = btn.closest('.cfg-row').querySelector('.item-edit');
  const input = wrap.querySelector('input, select');
  const val = input.value.trim();

  if (!validate(input, item)) {
    toast(`「${item.name}」的值格式不合法`, 'warn');
    input.focus();
    return;
  }
  if (val === '') { toast(`「${item.name}」不能为空`, 'warn'); return; }

  const danger = DANGER_ITEMS[code];
  if (danger) {
    const ok = await confirmModal(
      `确认写入 ${item.name}`,
      `即将写入网口 ${port}${set ? ` 档 ${set}` : ''}：\n\n  ${item.name} = ${val}\n\n${danger}\n\n确认继续？`,
      '确认写入');
    if (!ok) return;
  }

  btn.disabled = true;
  try {
    await api('/api/write', {
      method: 'POST',
      body: { item: code, port, set, value: val },
    });
    S.dirty.delete(key(code, port, set));
    updateDirtyNote();
    toast(`${item.name} 已写入`, 'ok', 2200);
    // 写完回读确认
    const r = await api('/api/read', {
      method: 'POST', body: { items: [{ item: code, port, set }] },
    });
    applyRows(r.rows);
    renderConfig();
  } catch (e) {
    toast(`写失败：${e.message}`, 'err', 7000);
  } finally {
    btn.disabled = false;
  }
}

// ─────────── 批量读 ───────────
async function readAll() {
  if (!S.connected) return;
  setBusy(true);
  try {
    const r = await api('/api/read', {
      method: 'POST',
      body: { items: buildReadRequests() },
    });
    applyRows(r.rows);
    const bad = r.rows.filter((x) => !x.ok).length;
    toast(bad ? `读回 ${r.rows.length} 项，${bad} 项被设备拒绝`
               : `读回 ${r.rows.length} 项`, bad ? 'warn' : 'ok');
  } catch (e) {
    toast(`读取失败：${e.message}`, 'err', 7000);
  } finally {
    setBusy(false);
    if (S.view !== 'overview') renderConfig();
    refreshOverview();
  }
}

function buildReadRequests() {
  const reqs = [];
  const n = S.portNum || 1;
  for (const it of S.items) {
    if (it.mode === 'w') continue;                 // 动作不可读
    if (!it.per_port) { reqs.push({ item: it.code, port: 0, set: 0 }); continue; }
    for (let p = 0; p < n; p++) {
      const cnt = slotsOf(it, p);
      for (let s = 0; s < cnt; s++) reqs.push({ item: it.code, port: p, set: s });
    }
  }
  return reqs;
}

function applyRows(rows) {
  // 读回值若已与用户输入一致，说明该项已落盘 —— 清掉 dirty 标记
  for (const r of rows) {
    const k = key(r.item, r.port, r.set);
    if (S.dirty.has(k) && r.ok && r.text === (S.dirtyText.get(k) || r.text)) {
      S.dirty.delete(k);
    }
  }
  updateDirtyNote();
  for (const r of rows) {
    const k = key(r.item, r.port, r.set);
    S.snapshot[k] = {
      text: r.text, display: r.display, raw: r.raw,
      status: r.ok ? 'OK' : r.status,
    };
  }
}

// ─────────── 批量写（只写本页改过的） ───────────
$('#btn-cfg-write').onclick = async () => {
  if (!S.connected) { toast('请先连接设备', 'warn'); return; }
  const edits = [];
  $$('.cfg-row').forEach((row) => {
    const k = row.dataset.key;
    if (!S.dirty.has(k)) return;
    const [code, port, set] = k.split(':').map(Number);
    const input = row.querySelector('.item-edit input, .item-edit select');
    if (!input) return;
    edits.push({ code, port, set, value: input.value.trim(),
                 name: S.byCode.get(code).name });
  });
  if (!edits.length) { toast('本页没有待写入的修改', 'info'); return; }

  const danger = edits.filter((e) => DANGER_ITEMS[e.code]);
  const list = edits.map((e) => `  ${e.name}（口${e.port}）= ${e.value}`).join('\n');
  const warn = danger.length
    ? `\n\n⚠ 其中 ${danger.map((d) => d.name).join('、')} 属于危险项，改错将无法连接设备。`
    : '';
  const ok = await confirmModal(`确认写入 ${edits.length} 项`,
    `即将写入：\n\n${list}${warn}\n\n确认继续？`, '确认写入');
  if (!ok) return;

  setBusy(true);
  let done = 0;
  const failed = [];
  for (const e of edits) {
    try {
      await api('/api/write', {
        method: 'POST',
        body: { item: e.code, port: e.port, set: e.set, value: e.value },
      });
      S.dirty.delete(key(e.code, e.port, e.set));
      done++;
    } catch (ex) {
      failed.push(`${e.name}: ${ex.message}`);
    }
  }
  setBusy(false);
  if (failed.length) {
    toast(`成功 ${done} 项，失败 ${failed.length} 项：\n${failed.join('\n')}`, 'err', 9000);
  } else {
    toast(`已写入 ${done} 项`, 'ok');
  }
  await readAll();
};

$('#btn-cfg-read').onclick = readAll;
$('#btn-read-all').onclick = readAll;

// ─────────── 概览 ───────────
async function refreshOverview() {
  if (!S.connected) {
    $('#ov-version').textContent = '—';
    $('#ov-ports').textContent = '—';
    $('#ov-cmdport').textContent = '—';
    $('#ov-caps').textContent = '—';
    $('#port-table tbody').innerHTML =
      '<tr><td colspan="6" class="empty">连接设备后显示</td></tr>';
    $('#cfg-table tbody').innerHTML =
      '<tr><td colspan="5" class="empty">连接设备后显示</td></tr>';
    $('#geom-table tbody').innerHTML = '<tr><td colspan="4" class="empty">连接后显示</td></tr>';
    $('#geom-head').innerHTML = '<tr><th>能力项</th><th>口 0</th><th>口 1</th><th>全局上限</th></tr>';
    return;
  }

  const snap = (code, port = 0) => S.snapshot[key(code, port, 0)];
  const ver = snap(0x51);
  const pn = snap(0x72);
  const cmdport = snap(0x33, 0);

  const verHex = ver ? (ver.raw ? ver.raw.toUpperCase() : (ver.text || '—')) : '—';
  $('#ov-version').textContent = verHex;
  $('#ov-version').title = ver ? (ver.display || ver.text || '') : '';
  $('#ov-ports').textContent = pn ? pn.text : (S.portNum || '—');
  $('#ov-cmdport').textContent = cmdport ? cmdport.text : '—';
  // 能力摘要：几档 IPv4 分流 / 几档 UDP 区间（取口 0）
  const g = S.geom && S.geom['0'];
  if (g) {
    const f = (n) => g[S.meta.geometry_fields.indexOf(n)];
    $('#ov-caps').textContent =
      `IPv4 ${f('IPV4_RX_NUM')} 档 · UDP ${f('UDP_RX_PORT_NUM')} 档 · 以太 ${f('MAC_RX_NUM')} 档`;
  } else {
    $('#ov-caps').textContent = '—';
  }

  // 网口状态：表格便于横向对比两个口
  const rows = [];
  for (let p = 0; p < (S.portNum || 1); p++) {
    const link = snap(0x52, p);
    const idle = snap(0x53, p);
    const df = snap(0x55, p);
    const txa = snap(0x54, p);
    const arp = snap(0x60, p);
    const icmp = snap(0x61, p);
    const up = link && link.raw && (hexToLeInt(link.raw) & 1);
    const isIdle = idle && idle.raw && (hexToLeInt(idle.raw) & 1);
    const dfOn = df && df.raw && (hexToLeInt(df.raw) & 1);
    rows.push(`<tr>
      <td class="name">网口 ${p}</td>
      <td>${up === undefined ? '—'
        : `<span class="dot-ok" style="background:${up ? 'var(--ok)' : 'var(--danger)'}"></span>${up ? '链路可用' : '链路断开'}`}</td>
      <td>${isIdle === undefined ? '—'
        : `<span class="dot-ok" style="background:${isIdle ? 'var(--ok)' : 'var(--warn)'}"></span>${isIdle ? '空闲' : '忙'}`}</td>
      <td>${df === undefined ? '—' : (dfOn ? '禁止' : '允许')}</td>
      <td class="cell-sub">${esc(statBrief(arp, 0x60))}</td>
      <td class="cell-sub">${esc(statBrief(icmp, 0x61))}</td>
    </tr>`);
  }
  $('#port-table tbody').innerHTML = rows.join('') ||
    '<tr><td colspan="6" class="empty">无数据</td></tr>';

  // 当前配置速查：只读快照。地址页是"改"的入口，这里是"看一眼"
  const cfgRows = [];
  for (let p = 0; p < (S.portNum || 1); p++) {
    const ip = snap(0x00, p), mac = snap(0x01, p);
    const gw = snap(0x02, p), msk = snap(0x03, p);
    if (!ip && !mac) continue;
    cfgRows.push(`<tr>
      <td class="name">网口 ${p}</td>
      <td class="cell-mono">${esc(ip ? ip.text : '—')}</td>
      <td class="cell-mono">${esc(mac ? mac.text : '—')}</td>
      <td class="cell-mono">${esc(gw ? gw.text : '—')}</td>
      <td class="cell-mono">${esc(msk ? msk.text : '—')}</td>
    </tr>`);
  }
  $('#cfg-table tbody').innerHTML = cfgRows.join('') ||
    '<tr><td colspan="5" class="empty">连接后显示</td></tr>';

  renderGeometryTable();
}

// 渲染「配置能力表」：每个字段的数值 + 中文含义 + 约束了哪些 ITEM
function renderGeometryTable() {
  const nPorts = S.portNum || 1;
  const headCells = ['<th>能力项</th>'];
  for (let p = 0; p < nPorts; p++) headCells.push(`<th>口 ${p}</th>`);
  headCells.push('<th>全局上限</th>');
  $('#geom-head').innerHTML = `<tr>${headCells.join('')}</tr>`;

  const rows = [];
  const fields = S.meta.geometry_fields;
  const sem = S.meta.geometry_semantics || [];
  const gmax = S.snapshot[key(0x71, 0, 0)];
  for (let i = 0; i < fields.length; i++) {
    const cells = [];
    for (let p = 0; p < nPorts; p++) {
      const g = S.geom[String(p)];
      cells.push(g ? `<td class="num">${g[i]}</td>` : '<td class="num">—</td>');
    }
    let mx = '—';
    if (gmax && gmax.raw) {
      // 浏览器没有 Buffer，用纯 JS 取第 i 个字节
      const hex = gmax.raw;
      const off = i * 2;
      mx = (off + 1 < hex.length) ? parseInt(hex.substr(off, 2), 16) : '—';
    }
    const m = sem[i] || {};
    // 中文名 + 字段名 + 这个数字代表什么 + 约束了哪些 ITEM
    const bound = (m.item_names && m.item_names.length)
      ? `<span class="g-bind">约束 ${m.item_names.map(esc).join(' / ')}</span>` : '';
    const valNote = (m.kind === 'width')
      ? `（${m.unit}）` : (m.unit ? ` ${m.unit}` : '');
    rows.push(`<tr>
      <td class="g-name">
        <div class="g-title">${esc(m.label || fields[i])}
          <span class="g-field">${esc(fields[i])}</span></div>
        <div class="g-desc">${esc(m.desc || '')}</div>
        ${bound}
      </td>
      ${cells.join('')}
      <td class="num">${mx}${valNote}</td>
    </tr>`);
  }
  $('#geom-table tbody').innerHTML = rows.join('');
}

$('#btn-refresh-status').onclick = async () => {
  if (!S.connected) return;
  const reqs = [];
  const n = S.portNum || 1;
  for (let p = 0; p < n; p++) {
    for (const c of [0x52, 0x53, 0x54, 0x55, 0x60, 0x61]) {
      reqs.push({ item: c, port: p, set: 0 });
    }
  }
  try {
    const r = await api('/api/read', { method: 'POST', body: { items: reqs } });
    applyRows(r.rows);
    refreshOverview();
  } catch (e) { toast(`刷新失败：${e.message}`, 'err'); }
};

$('#btn-dump').onclick = async () => {
  if (!S.connected) { toast('请先连接设备', 'warn'); return; }
  setBusy(true);
  try {
    const r = await api('/api/dump', { method: 'POST' });
    applyRows(r.rows);
    const blob = new Blob([JSON.stringify(r, null, 2)], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = `centenarian-cfg-${S.host}-${Date.now()}.json`;
    a.click();
    URL.revokeObjectURL(a.href);
    toast(`已导出 ${r.rows.length} 项`, 'ok');
  } catch (e) {
    toast(`导出失败：${e.message}`, 'err');
  } finally { setBusy(false); }
};

// ─────────── 动作页 ───────────
const ACTION_META = {
  0x40: { ico: '↺', danger: true,
    warn: '会把地址、命令端口、优先级全部恢复到默认值。\n若当前是通过非默认端口连上的，执行后可能再也连不上。' },
  0x41: { ico: '⌫', danger: false, warn: '' },
  0x42: { ico: '⌦', danger: false, warn: '' },
  0x43: { ico: '⌧', danger: false, warn: '' },
};

function renderActions() {
  const host = $('#action-list');
  const acts = S.items.filter((it) => it.mode === 'w');
  if (!acts.length) { host.innerHTML = '<div class="panel"><div class="empty">无动作</div></div>'; return; }
  host.innerHTML = acts.map((it) => {
    const m = ACTION_META[it.code] || { ico: '⚡', danger: false, warn: '' };
    const ports = it.per_port
      ? Array.from({ length: S.portNum || 1 }, (_, p) => p)
      : [0];
    const btns = ports.map((p) => `
      <button class="btn${m.danger ? ' danger' : ''}"
        data-action="${it.code}" data-port="${p}">
        ${esc(it.name)}${it.per_port ? ` · 口${p}` : ''}
      </button>`).join('');
    return `<div class="action-item${m.danger ? ' danger' : ''}">
      <div class="ai-ico">${m.ico}</div>
      <div class="ai-txt">
        <b>${esc(it.name)} <span class="tag w">动作</span></b>
        <span>${esc(it.desc)}</span>
        ${m.warn ? `<span class="warn-note">${esc(m.warn)}</span>` : ''}
      </div>
      <div>${btns}</div>
    </div>`;
  }).join('');

  host.querySelectorAll('[data-action]').forEach((b) => {
    b.onclick = () => doAction(parseInt(b.dataset.action, 10), parseInt(b.dataset.port, 10));
  });
}

async function doAction(code, port) {
  const it = S.byCode.get(code);
  const m = ACTION_META[code] || {};
  const ok = await confirmModal(
    `确认执行 ${it.name}`,
    `即将对网口 ${port} 执行动作：\n\n  ${it.name}\n\n${it.desc}\n${m.warn ? '\n' + m.warn : ''}\n\n确认执行？`,
    '确认执行');
  if (!ok) return;

  setBusy(true);
  try {
    await api('/api/action', { method: 'POST', body: { item: code, port } });
    toast(`${it.name} 执行成功`, 'ok');
    if (code === 0x40) { S.snapshot = {}; S.dirty.clear(); S.dirtyText.clear(); }
    await readAll();
  } catch (e) {
    toast(`执行失败：${e.message}`, 'err', 7000);
  } finally { setBusy(false); }
}

// ─────────── 原始帧 ───────────
$('#btn-raw-send').onclick = async () => {
  const hex = $('#raw-hex').value.trim();
  if (!hex) { toast('请输入要发送的字节', 'warn'); return; }
  if (!S.connected) { toast('请先连接设备', 'warn'); return; }
  const box = $('#raw-result');
  box.innerHTML = '<div class="empty">发送中…</div>';
  try {
    const r = await api('/api/raw', { method: 'POST', body: { hex } });
    let html = `<div class="raw-line"><span class="lb">发送</span>${esc(r.tx)}</div>`;
    if (r.error) {
      html += `<div class="raw-line err"><span class="lb">应答</span>${esc(r.error)}</div>`;
    } else {
      html += `<div class="raw-line"><span class="lb">收��</span>${esc(r.rx)}</div>`;
      if (r.rsps && r.rsps.length) {
        html += `<div class="raw-line"><span class="lb">解析</span></div>`;
        r.rsps.forEach((x) => {
          html += `<div class="raw-line">
            <span class="lb">${esc(x.op)}</span>
            seq=${x.seq} ${esc(x.item_name)} 口${x.port} 档${x.set}
            状态=${esc(x.status)}${x.value ? ` 值=${esc(x.value)}` : ''}
            ${x.display ? `<br><span class="lb" style="margin-left:0">${esc(x.display)}</span>` : ''}
          </div>`;
        });
      } else {
        html += '<div class="raw-line">（未解析出应答条目）</div>';
      }
    }
    box.innerHTML = html;
  } catch (e) {
    box.innerHTML = `<div class="raw-line err">${esc(e.message)}</div>`;
  }
};

// ─────────── 日志 ───────────
function appendLog(line) {
  const box = $('#log-lines');
  const div = document.createElement('div');
  div.className = 'ln';
  const m = line.match(/^\[(\d\d:\d\d:\d\d)\]\s*(.*)$/);
  if (m) {
    div.innerHTML = `<span class="t">${m[1]}</span>${esc(m[2])}`;
  } else {
    div.textContent = line;
  }
  if (/✗|失败|错误|Exception|超时|拒绝/.test(line)) div.classList.add('err');
  else if (/✓|成功|完成/.test(line)) div.classList.add('ok');
  else if (/警告|重试|缺/.test(line)) div.classList.add('warn');
  box.appendChild(div);
  box.scrollTop = box.scrollHeight;
  S.logCount++;
  $('#log-count').textContent = S.logCount;
}

// 日志抽屉折叠态以 .logbar 元素上的 class 为准（初始就在元素上），
// body 上的同名 class 只是让 CSS 选择器更省事，同步过去即可
$('#logbar-toggle').onclick = () => {
  const collapsed = $('#logbar').classList.toggle('log-collapsed');
  document.body.classList.toggle('log-collapsed', collapsed);
};
$('#btn-log-clear').onclick = () => {
  $('#log-lines').innerHTML = '';
  S.logCount = 0;
  $('#log-count').textContent = '0';
};
$('#chk-log-wrap').onchange = (e) => {
  $('#log-lines').classList.toggle('wrap', e.target.checked);
};

function connectLogStream() {
  if (S.es) S.es.close();
  const es = new EventSource('/api/events');
  S.es = es;
  es.onmessage = (ev) => appendLog(ev.data);
  es.onerror = () => {
    if (es.readyState === EventSource.CLOSED) {
      setTimeout(connectLogStream, 2500);
    }
  };
}

// ─────────── 启动 ───────────
async function boot() {
  connectLogStream();
  try {
    const m = await api('/api/meta');
    S.meta = m;
    S.items = m.items;
    S.items.forEach((it) => S.byCode.set(it.code, it));
    renderActions();
  } catch (e) {
    toast(`无法获取元数据：${e.message}`, 'err', 9000);
  }

  try {
    const st = await api('/api/state');
    if (st.connected) {
      S.connected = true;
      S.host = st.host; S.udpPort = st.port;
      S.portNum = st.port_num || 0;
      S.geom = st.geom || {};
      S.snapshot = st.snapshot || {};
      setLinkState('online', `已连接 ${st.host}:${st.port}`);
      $('#btn-connect').disabled = false;
      await refreshOverview();
    }
  } catch { /* 后端未就绪 */ }
}

boot();
