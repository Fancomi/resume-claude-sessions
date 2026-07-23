#!/usr/bin/env python3
# GUI session picker for resume-claude-sessions.sh (macOS / Linux desktop).
# Reads TSV records on stdin, one per line:
#     idx  date  day_label  time  group  checked  cwd
# Writes chosen sessions on stdout, one per line:
#     idx  group  cli
# Exit 0 = confirmed (possibly empty), non-zero = cancelled.
#
# Real table via ttk.Treeview: date groups are collapsible parent rows, sessions
# are child rows. Columns align perfectly. Per session row:
#   开(☑/☐ click)  组(number, double-click to edit)  +CLI(✔ click)  时间  路径(#0)
# Clicking a date parent's 开 cell toggles the whole group. Space toggles 开.
import sys
import tkinter as tk
from tkinter import ttk

CHECK_ON = "[✓]"    # checked box
CHECK_OFF = "[  ]"  # empty box
CLI_ON = "[CLI]"    # CLI on
CLI_OFF = "[   ]"


def read_records():
    recs = []
    for line in sys.stdin.read().splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 7:
            continue
        idx, date, label, tm, group, checked, cwd = parts[:7]
        recs.append({
            "idx": idx, "date": date, "label": label, "time": tm,
            "group": group, "checked": checked == "1", "cwd": cwd,
        })
    return recs


class Picker:
    def __init__(self, root, recs):
        self.root = root
        self.recs = recs
        self.result = None
        # per tree-item state
        self.sess = {}      # item_id -> {idx, open, grp, cli, cwd, time}
        self.parent_of = {} # session item_id -> date parent item_id
        self.date_item = {} # date -> parent item_id
        self.kids = {}      # parent item_id -> [session item_id]
        self._editor = None

        root.title("Claude Code · 恢复会话（按日期分组）")
        root.geometry("1040x660")
        root.minsize(760, 420)
        try:
            root.tk.call("tk", "scaling", 1.2)
        except Exception:
            pass

        top = ttk.Frame(root, padding=(12, 10))
        top.pack(fill="x")
        ttk.Label(
            top,
            text="勾选要恢复的会话（点“开”列的框）。相同 组 号 = 合并到一个窗口的多个标签页"
                 "（双击“组”列改号）；+CLI = 为该会话再开一个可跑命令的终端。",
            wraplength=1000, justify="left",
        ).pack(anchor="w")
        bar = ttk.Frame(top)
        bar.pack(fill="x", pady=(8, 0))
        ttk.Button(bar, text="全选", command=lambda: self.set_all(True)).pack(side="left")
        ttk.Button(bar, text="全不选", command=lambda: self.set_all(False)).pack(side="left", padx=(6, 0))
        ttk.Button(bar, text="展开/折叠", command=self.toggle_expand).pack(side="left", padx=(6, 0))
        self.count_var = tk.StringVar()
        ttk.Label(bar, textvariable=self.count_var).pack(side="right")

        # real table -----------------------------------------------------------
        mid = ttk.Frame(root)
        mid.pack(fill="both", expand=True, padx=12)
        cols = ("open", "grp", "cli", "time")
        self.tree = ttk.Treeview(mid, columns=cols, show="tree headings",
                                 selectmode="browse")
        self.tree.heading("#0", text="日期 / 路径")
        self.tree.heading("open", text="开")
        self.tree.heading("grp", text="组")
        self.tree.heading("cli", text="+CLI")
        self.tree.heading("time", text="时间")
        self.tree.column("#0", width=560, minwidth=260, stretch=True, anchor="w")
        self.tree.column("open", width=68, minwidth=56, stretch=False, anchor="center")
        self.tree.column("grp", width=56, minwidth=44, stretch=False, anchor="center")
        self.tree.column("cli", width=76, minwidth=60, stretch=False, anchor="center")
        self.tree.column("time", width=120, minwidth=90, stretch=False, anchor="center")

        style = ttk.Style()
        try:
            style.configure("Treeview", rowheight=34, font=("", 13))
            style.configure("Treeview.Heading", font=("", 11, "bold"))
        except Exception:
            pass
        self.tree.tag_configure("date", font=("", 10, "bold"))

        vsb = ttk.Scrollbar(mid, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=vsb.set)
        self.tree.pack(side="left", fill="both", expand=True)
        vsb.pack(side="right", fill="y")

        self.build_tree()

        self.tree.bind("<Button-1>", self.on_click)
        self.tree.bind("<Double-1>", self.on_double)
        self.tree.bind("<space>", self.on_space)
        self.tree.bind("<Return>", lambda e: self.confirm())

        bottom = ttk.Frame(root, padding=(12, 10))
        bottom.pack(fill="x")
        ttk.Button(bottom, text="取消", command=self.cancel).pack(side="right")
        ttk.Button(bottom, text="打开选中的会话", command=self.confirm).pack(side="right", padx=(0, 8))
        root.bind("<Escape>", lambda e: self.cancel())
        self.update_count()

    def build_tree(self):
        last = None
        for rec in self.recs:
            if rec["date"] != last:
                last = rec["date"]
                pid = self.tree.insert("", "end", text="  " + rec["label"],
                                       values=(CHECK_OFF, "", "", ""),
                                       open=True, tags=("date",))
                self.date_item[last] = pid
                self.kids[pid] = []
            pid = self.date_item[rec["date"]]
            iid = self.tree.insert(
                pid, "end", text="    " + rec["cwd"],
                values=(CHECK_ON if rec["checked"] else CHECK_OFF,
                        rec["group"], CLI_OFF, rec["time"]),
            )
            self.sess[iid] = {
                "idx": rec["idx"], "open": rec["checked"],
                "grp": rec["group"], "cli": False,
                "cwd": rec["cwd"], "time": rec["time"],
            }
            self.parent_of[iid] = pid
            self.kids[pid].append(iid)
        self.refresh_all_headers()

    # --- rendering ----------------------------------------------------------
    def render_session(self, iid):
        s = self.sess[iid]
        self.tree.set(iid, "open", CHECK_ON if s["open"] else CHECK_OFF)
        self.tree.set(iid, "grp", s["grp"])
        self.tree.set(iid, "cli", CLI_ON if s["cli"] else CLI_OFF)

    def refresh_header(self, pid):
        kids = self.kids[pid]
        allon = kids and all(self.sess[k]["open"] for k in kids)
        self.tree.set(pid, "open", CHECK_ON if allon else CHECK_OFF)

    def refresh_all_headers(self):
        for pid in self.kids:
            self.refresh_header(pid)

    # --- interaction --------------------------------------------------------
    def toggle_session(self, iid):
        s = self.sess[iid]
        s["open"] = not s["open"]
        self.render_session(iid)
        self.refresh_header(self.parent_of[iid])
        self.update_count()

    def toggle_cli(self, iid):
        s = self.sess[iid]
        s["cli"] = not s["cli"]
        self.render_session(iid)

    def toggle_group_by_parent(self, pid):
        kids = self.kids[pid]
        target = not (kids and all(self.sess[k]["open"] for k in kids))
        for k in kids:
            self.sess[k]["open"] = target
            self.render_session(k)
        self.refresh_header(pid)
        self.update_count()

    def on_click(self, event):
        if self.tree.identify("region", event.x, event.y) != "cell":
            return
        iid = self.tree.identify_row(event.y)
        col = self.tree.identify_column(event.x)  # '#1'=open '#2'=grp '#3'=cli '#4'=time
        if not iid:
            return
        if iid in self.kids:            # a date parent
            if col == "#1":
                self.toggle_group_by_parent(iid)
                return "break"
            return
        if col == "#1":
            self.toggle_session(iid); return "break"
        if col == "#3":
            self.toggle_cli(iid); return "break"

    def on_double(self, event):
        iid = self.tree.identify_row(event.y)
        col = self.tree.identify_column(event.x)
        if iid in self.sess:
            if col == "#2":              # double-click 组 column = edit group number
                self.edit_group(iid)
            else:                        # double-click anywhere else on row = toggle 开
                self.toggle_session(iid)
            return "break"
        if iid in self.kids:             # double-click a date row = toggle whole group
            self.toggle_group_by_parent(iid)
            return "break"

    def on_space(self, event):
        iid = self.tree.focus()
        if iid in self.sess:
            self.toggle_session(iid); return "break"
        if iid in self.kids:
            self.toggle_group_by_parent(iid); return "break"

    def edit_group(self, iid):
        x, y, w, h = self.tree.bbox(iid, "#2")
        var = tk.StringVar(value=self.sess[iid]["grp"])
        ent = ttk.Entry(self.tree, textvariable=var, justify="center")
        ent.place(x=x, y=y, width=w, height=h)
        ent.focus_set()
        ent.select_range(0, "end")

        def commit(_=None):
            v = var.get().strip()
            if v.isdigit():
                self.sess[iid]["grp"] = v
                self.render_session(iid)
            ent.destroy()

        ent.bind("<Return>", commit)
        ent.bind("<FocusOut>", commit)
        ent.bind("<Escape>", lambda e: ent.destroy())

    def toggle_expand(self):
        any_open = any(self.tree.item(p, "open") for p in self.kids)
        for p in self.kids:
            self.tree.item(p, open=not any_open)

    def set_all(self, val):
        for iid, s in self.sess.items():
            s["open"] = val
            self.render_session(iid)
        self.refresh_all_headers()
        self.update_count()

    def update_count(self):
        n = sum(1 for s in self.sess.values() if s["open"])
        self.count_var.set("已选 %d / %d" % (n, len(self.sess)))

    def confirm(self):
        out = []
        for s in self.sess.values():
            if not s["open"]:
                continue
            grp = s["grp"].strip() if s["grp"].strip().isdigit() else "0"
            out.append("%s\t%s\t%s" % (s["idx"], grp, "1" if s["cli"] else "0"))
        self.result = "\n".join(out)
        self.root.destroy()

    def cancel(self):
        self.result = None
        self.root.destroy()


def main():
    recs = read_records()
    if not recs:
        sys.exit(1)
    root = tk.Tk()
    app = Picker(root, recs)
    root.mainloop()
    if app.result is None:
        sys.exit(1)
    if app.result:
        sys.stdout.write(app.result + "\n")
    sys.exit(0)


if __name__ == "__main__":
    main()
