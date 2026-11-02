#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cfg_gui.py — Centenarian 配置通道图形上位机

Windows / Linux 通用，只依赖 Python 标准库（tkinter + socket）。
网络收发交给 cfgproto.CfgClient，协议细节见该文件与 Docs/05-config-command.md。

用法:
    python cfg_gui.py                      # 打开界面
    python cfg_gui.py -H 192.168.1.9       # 预填设备 IP
    python cfg_gui.py -H 192.168.1.9 -P 49374

Linux 若提示找不到 tkinter：
    sudo apt install python3-tk
"""

from __future__ import annotations

import argparse
import queue
import sys
import threading
import tkinter as tk
import tkinter.font as tkfont
from tkinter import messagebox, ttk
from tkinter.scrolledtext import ScrolledText
from typing import Any, Callable, Dict, List, Optional, Tuple

import cfgproto as P

APP_TITLE = "Centenarian 配置上位机"

# 危险操作二次确认文案
DANGER_ACTIONS = {
    0x40: "RESET_DEF 会把地址、命令端口、优先级全部恢复到默认值。\n"
          "若当前是通过非默认端口连上的，执行后可能再也连不上。\n\n确认继续？",
}
DANGER_ITEMS = {
    0x33: "CMD_UDP_PORT 改的是命令通道自己的端口。\n"
          "改错就再也连不上，只能靠上电复位恢复默认。\n\n确认继续？",
    0x34: "CMD_UDP_PRIO 改成 0 会让应答发不出去。\n\n确认继续？",
}

# 分页布局：(页名, [(组标题, [item代码...])...])
PAGES: List[Tuple[str, List[Tuple[str, List[int]]]]] = [
    ("地址", [
        ("IPv4", [0x00, 0x01, 0x02, 0x03]),
        ("IPv6", [0x04, 0x05, 0x06, 0x07]),
    ]),
    ("分流", [
        ("关键字表", [0x10, 0x11, 0x12, 0x13]),
    ]),
    ("行为", [
        ("ARP / ICMP", [0x30, 0x31, 0x32]),
        ("命令通道自身", [0x33, 0x34]),
    ]),
    ("状态", [
        ("链路与发送", [0x51, 0x52, 0x53, 0x54, 0x55]),
        ("统计（sticky）", [0x60, 0x61]),
    ]),
    ("边界", [
        ("配置能力", [0x70, 0x71, 0x72]),
    ]),
]

ACTIONS = [
    ("恢复默认 RESET_DEF", 0x40, False),
    ("清 ARP 缓存", 0x41, True),
    ("清 ARP 等待队列", 0x42, True),
    ("清锁存统计", 0x43, True),
]


# ---------------------------------------------------------------------------
# 一行配置控件
# ---------------------------------------------------------------------------

class ItemRow:
    """一个 ITEM × 口 × 槽 的编辑行。"""

    def __init__(self, parent: ttk.Frame, gui: "CfgGui", item: P.Item,
                 port: int, slot: int, row: int) -> None:
        self.gui = gui
        self.item = item
        self.port = port
        self.slot = slot

        label = item.name
        if item.indexed:
            label += f"  口{port}·槽{slot}"
        elif item.per_port:
            label += f"  口{port}"

        self.lbl = ttk.Label(parent, text=label, width=30, anchor="w")
        self.lbl.grid(row=row, column=0, sticky="w", padx=(6, 4), pady=2)

        self.lbl_probe = ttk.Label(parent, text="—", width=26, anchor="w",
                                   foreground="#555")
        self.lbl_probe.grid(row=row, column=1, sticky="w", padx=4, pady=2)

        readonly = item.mode == "r"

        self.var = tk.StringVar()
        self.ent = ttk.Entry(parent, textvariable=self.var, width=30)
        self.ent.grid(row=row, column=2, sticky="we", padx=4, pady=2)
        if readonly:
            self.ent.state(["readonly"])

        self.btn_get = ttk.Button(parent, text="读", width=5,
                                  command=self.on_get)
        self.btn_get.grid(row=row, column=3, padx=2, pady=2)

        if not readonly:
            self.btn_set = ttk.Button(parent, text="写", width=5,
                                      command=self.on_set)
            self.btn_set.grid(row=row, column=4, padx=2, pady=2)
            if not item.indexed and not item.per_port:
                pass
        else:
            self.btn_set = None                                     # type: ignore[assignment]

        self.btn_get.state(["!disabled"])

    # ---------- 动作 ----------
    def on_get(self) -> None:
        self.gui.submit(f"读 {self.item.name}", lambda c: c.get(
            self.item.code, self.port, self.slot), self._apply)

    def on_set(self) -> None:
        text = self.var.get().strip()
        try:
            raw = P.parse_value(self.item.code, text)
        except Exception as exc:
            messagebox.showerror("值不合法", f"{self.item.name}：{exc}")
            return
        tip = DANGER_ITEMS.get(self.item.code)
        if tip and not messagebox.askyesno("确认写入", tip):
            return
        self.gui.submit(f"写 {self.item.name}", lambda c: c.set(
            self.item.code, raw, self.port, self.slot, precheck=False),
            self._apply)

    def _apply(self, rsp: P.Rsp) -> None:
        if not rsp.ok:
            self.lbl_probe.configure(text=rsp.status_name, foreground="#c0392b")
            return
        txt = P.fmt_value(rsp.item, rsp.value) if rsp.value else "完成"
        self.lbl_probe.configure(text=txt if len(txt) <= 60 else txt[:57] + "...",
                                 foreground="#16734a")
        if rsp.op == P.RSP_GET and rsp.value:
            # 回填可读文本，方便改一个字符再写回
            self.var.set(P.to_edit_text(self.item.code, rsp.value))


# ---------------------------------------------------------------------------
# 主窗口
# ---------------------------------------------------------------------------

class CfgGui:
    def __init__(self, root: tk.Tk, args) -> None:
        self.root = root
        self.args = args
        self.client: Optional[P.CfgClient] = None
        self.rows: List[ItemRow] = []
        self.q: "queue.Queue[Tuple[str, Any]]" = queue.Queue()
        self.busy = False
        self.port_num = 2
        self.geom: Dict[int, List[int]] = {}

        root.title(APP_TITLE)
        root.geometry("1080x720")
        root.minsize(920, 600)

        self._build()
        self._pump()

        if args.host:
            self.var_host.set(args.host)
        if args.port:
            self.var_port.set(str(args.port))
        if args.host:
            self.root.after(300, self.on_connect)

    # ---------- 界面 ----------
    def _build(self) -> None:
        self._build_conn()
        self.notebook = ttk.Notebook(self.root)
        self.notebook.pack(fill="both", expand=True, padx=8, pady=(0, 4))
        self.pages: Dict[str, ttk.Frame] = {}
        for title, _groups in PAGES:
            f = ttk.Frame(self.notebook)
            self.notebook.add(f, text=f"  {title}  ")
            self.pages[title] = f
        self._build_statusbar()

    def _build_conn(self) -> None:
        bar = ttk.Frame(self.root)
        bar.pack(fill="x", padx=8, pady=8)

        ttk.Label(bar, text="设备 IP").pack(side="left")
        self.var_host = tk.StringVar(value="192.168.1.9")
        ttk.Entry(bar, textvariable=self.var_host, width=16).pack(side="left", padx=(4, 12))

        ttk.Label(bar, text="端口").pack(side="left")
        self.var_port = tk.StringVar(value=str(P.DEFAULT_UDP_PORT))
        ttk.Entry(bar, textvariable=self.var_port, width=8).pack(side="left", padx=(4, 12))

        ttk.Label(bar, text="超时(s)").pack(side="left")
        self.var_timeout = tk.StringVar(value="0.2")
        ttk.Entry(bar, textvariable=self.var_timeout, width=5).pack(side="left", padx=(4, 12))

        self.btn_conn = ttk.Button(bar, text="连接", command=self.on_connect)
        self.btn_conn.pack(side="left", padx=2)
        self.btn_disc = ttk.Button(bar, text="断开", command=self.on_disconnect,
                                   state="disabled")
        self.btn_disc.pack(side="left", padx=2)

        ttk.Separator(bar, orient="vertical").pack(side="left", fill="y", padx=10)

        self.btn_all = ttk.Button(bar, text="全部读取", command=self.on_read_all,
                                  state="disabled")
        self.btn_all.pack(side="left", padx=2)

        self.lbl_conn = ttk.Label(bar, text="未连接", foreground="#c0392b")
        self.lbl_conn.pack(side="right")

    def _build_statusbar(self) -> None:
        wrap = ttk.Frame(self.root)
        wrap.pack(fill="both", expand=False, padx=8, pady=(0, 8))
        self.log = ScrolledText(wrap, height=9, wrap="none", state="disabled",
                                font=("TkFixedFont", 9))
        self.log.pack(fill="both", expand=True)

    # ---------- 日志 ----------
    def _log(self, msg: str) -> None:
        self.log.configure(state="normal")
        self.log.insert("end", msg + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    # ---------- 连接 ----------
    def on_connect(self) -> None:
        host = self.var_host.get().strip()
        if not host:
            messagebox.showwarning("缺少参数", "请填写设备 IP")
            return
        try:
            port = int(self.var_port.get(), 0)
            timeout = float(self.var_timeout.get())
        except ValueError:
            messagebox.showerror("参数错误", "端口需为整数、超时需为小数")
            return

        self.client = P.CfgClient(host, port, timeout=timeout, retries=2)
        self.client._log = lambda m: self.q.put(("log", m))
        try:
            self.client.open()
        except OSError as exc:
            messagebox.showerror("连接失败", str(exc))
            return

        self.lbl_conn.configure(text=f"已连接 {host}:{port}", foreground="#16734a")
        self.btn_conn.state(["disabled"])
        self.btn_disc.state(["!disabled"])
        self.btn_all.state(["!disabled"])
        self._log(f"=== 连接 {host}:{port} ===")
        self.on_read_all()

    def on_disconnect(self) -> None:
        if self.client:
            self.client.close()
            self.client = None
        self.lbl_conn.configure(text="未连接", foreground="#c0392b")
        self.btn_conn.state(["!disabled"])
        self.btn_disc.state(["disabled"])
        self.btn_all.state(["disabled"])
        self._log("=== 已断开 ===")

    # ---------- 后台任务 ----------
    def submit(self, name: str, fn: Callable[[P.CfgClient], Any],
               on_done: Optional[Callable[[Any], None]] = None) -> None:
        if self.client is None:
            messagebox.showwarning("未连接", "请先连接设备")
            return
        if self.busy:
            self._log("! 上一个操作还没完成，稍等")
            return
        self.busy = True
        client = self.client

        def worker() -> None:
            try:
                res = fn(client)
                self.q.put(("done", (name, res, on_done)))
            except P.CfgError as exc:
                self.q.put(("err", (name, f"设备拒绝：{exc.rsp.status_name}")))
            except P.CfgTimeout as exc:
                self.q.put(("err", (name, f"超时：{exc}")))
            except Exception as exc:                    # 兜底，不让线程崩掉
                self.q.put(("err", (name, f"{type(exc).__name__}: {exc}")))

        threading.Thread(target=worker, daemon=True).start()

    def _pump(self) -> None:
        try:
            while True:
                kind, payload = self.q.get_nowait()
                if kind == "log":
                    self._log(str(payload))
                elif kind == "done":
                    name, res, cb = payload
                    self.busy = False
                    if cb:
                        try:
                            cb(res)
                        except Exception as exc:
                            self._log(f"! 界面刷新失败：{exc}")
                    if isinstance(res, P.Rsp):
                        self._log(f"  {name} → {res}")
                elif kind == "err":
                    name, msg = payload
                    self.busy = False
                    self._log(f"  {name} ✗ {msg}")
                    self.lbl_conn.configure(text=f"上次操作失败：{msg}",
                                            foreground="#a86500")
        except queue.Empty:
            pass
        self.root.after(80, self._pump)

    # ---------- 读取 ----------
    def on_read_all(self) -> None:
        if self.client is None:
            return

        def job(c: P.CfgClient):
            # 1) 拿口数与几何
            pn = c.get("PORT_NUM")
            n = (pn.value[0] & 0x0F) if pn.ok and pn.value else 2
            geoms: Dict[int, List[int]] = {}
            reqs = [("GEOMETRY", p, 0) for p in range(n)]
            for p, g in enumerate(c.get_many(reqs)):
                geoms[p] = list(g.value) if g.ok else [1] * 9
            # 2) 批量读所有项
            batch: List[Tuple[int, int, int]] = []
            for code in P.ITEMS:
                it = P.ITEMS[code]
                if it.is_action:
                    continue
                if not it.per_port:
                    batch.append((code, 0, 0))
                    continue
                for p in range(n):
                    cnt = self._slots(it, p, geoms) if it.indexed else 1
                    for s in range(cnt):
                        batch.append((code, p, s))
            rsps = c.get_many(batch)
            return n, geoms, rsps

        self.submit("全部读取", job, self._after_read_all)

    @staticmethod
    def _slots(it: P.Item, port: int, geoms: Dict[int, List[int]]) -> int:
        """档数推导统一走 cfgproto.slots_for（与 Web UI、CLI 同一套逻辑）。"""
        return P.slots_for(it.code, geoms.get(port))

    def _after_read_all(self, payload) -> None:
        n, geoms, rsps = payload
        self.port_num = n
        self.geom = geoms
        # (item, port, slot) 在读取集合里唯一，直接拿它做索引表最稳
        table: Dict[Tuple[int, int, int], P.Rsp] = {
            (r.item, r.port, r.set_idx): r for r in rsps
        }

        # 清空旧控件
        for f in self.pages.values():
            for w in f.winfo_children():
                w.destroy()
        self.rows.clear()

        actions_added = False
        for title, groups in PAGES:
            page = self.pages[title]
            r = 0
            for gtitle, codes in groups:
                ttk.Label(page, text=gtitle, font=("TkDefaultFont", 10, "bold")) \
                    .grid(row=r, column=0, columnspan=5, sticky="w", padx=6, pady=(10, 2))
                r += 1
                for code in codes:
                    it = P.ITEMS.get(code)
                    if it is None:
                        continue
                    if not it.per_port:
                        keys = [(0, 0)]
                    else:
                        keys = []
                        for p in range(n):
                            cnt = self._slots(it, p, geoms) if it.indexed else 1
                            for s in range(cnt):
                                keys.append((p, s))
                    for (p, s) in keys:
                        row = ItemRow(page, self, it, p, s, r)
                        rsp = table.get((code, p, s))
                        if rsp is not None and rsp.ok:
                            row._apply(rsp)
                        self.rows.append(row)
                r += 1

            # 动作页签放在「行为」页底部
            if title == "行为" and not actions_added:
                ttk.Label(page, text="动作（写操作，无返回值）",
                          font=("TkDefaultFont", 10, "bold")) \
                    .grid(row=r, column=0, columnspan=5, sticky="w", padx=6, pady=(14, 2))
                r += 1
                bar = ttk.Frame(page)
                bar.grid(row=r, column=0, columnspan=5, sticky="w", padx=6, pady=4)
                for text, code, per_port in ACTIONS:
                    if per_port:
                        for p in range(n):
                            ttk.Button(bar, text=f"{text} 口{p}", width=20,
                                       command=lambda c=code, pp=p: self.on_action(c, pp)
                                       ).pack(side="left", padx=3, pady=2)
                        bar = ttk.Frame(page)
                        r += 1
                        bar.grid(row=r, column=0, columnspan=5, sticky="w",
                                 padx=6, pady=4)
                    else:
                        ttk.Button(bar, text=text, width=20,
                                   command=lambda c=code: self.on_action(c, 0)
                                   ).pack(side="left", padx=3, pady=2)
                actions_added = True
                r += 1

            page.columnconfigure(2, weight=1)

        self._log(f"=== 读取完成：{n} 个口，{len(rsps)} 项 ===")

    # ---------- 动作 ----------
    def on_action(self, code: int, port: int) -> None:
        it = P.ITEMS.get(code)
        name = it.name if it else f"0x{code:02X}"
        tip = DANGER_ACTIONS.get(code)
        if tip and not messagebox.askyesno("确认执行", tip):
            return
        self.submit(f"动作 {name} 口{port}",
                    lambda c: c.action(code, port, precheck=False),
                    lambda r: None)


# ---------------------------------------------------------------------------

def main(argv: Optional[List[str]] = None) -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[attr-defined]
        except Exception:
            pass

    ap = argparse.ArgumentParser(description="Centenarian 配置通道图形上位机")
    ap.add_argument("-H", "--host", default=None, help="预填设备 IP 并自动连接")
    ap.add_argument("-P", "--port", type=lambda s: int(s, 0), default=None,
                    help="预填 UDP 端口（默认 0xC0DE）")
    args = ap.parse_args(argv)

    try:
        root = tk.Tk()
    except tk.TclError as exc:
        print("无法创建窗口，检查显示环境或安装 tkinter：\n  sudo apt install python3-tk",
              file=sys.stderr)
        print(f"（{exc}）", file=sys.stderr)
        return 1

    # 中文字体回退（Linux 上很常见）
    try:
        families = set(tkfont.families(root))
        for cand in ("Microsoft YaHei UI", "Microsoft YaHei", "PingFang SC",
                     "Noto Sans CJK SC", "WenQuanYi Micro Hei", "Source Han Sans SC"):
            if cand in families:
                for fname in ("TkDefaultFont", "TkTextFont", "TkMenuFont"):
                    try:
                        tkfont.nametofont(fname).configure(family=cand, size=10)
                    except tk.TclError:
                        pass
                break
    except Exception:
        pass

    CfgGui(root, args)
    root.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
