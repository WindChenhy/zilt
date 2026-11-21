#!/usr/bin/env python3
"""最小 X11 探针（仅依赖系统 libX11 / libXtst，无第三方包）。

v0.4.3 L6 托盘挂窗 E2E 用：窗口枚举 / 几何 / 可见性 + XTest 合成点击。
CI 与本地都不需要 xdotool / xwininfo。

用法：
  xtool.py list                       列出全部窗口（id class title geom mapped depth）
  xtool.py find <class>               按 WM_CLASS 找可见窗口（小窗口优先，图标 24px 级）
  xtool.py geom <id>                  打印 "x y w h"（根坐标）
  xtool.py visible <id>               可见 → exit 0；不可见 → exit 1
  xtool.py click <x> <y> [button]     指针移到根坐标并点击（默认左键 1）
  xtool.py active                     打印 _NET_ACTIVE_WINDOW
"""

import ctypes
import sys

xlib = ctypes.CDLL("libX11.so.6")
xtst = ctypes.CDLL("libXtst.so.6")

Window = ctypes.c_ulong
Atom = ctypes.c_ulong
Display = ctypes.c_void_p

xlib.XOpenDisplay.argtypes = [ctypes.c_char_p]
xlib.XOpenDisplay.restype = Display
xlib.XDefaultRootWindow.argtypes = [Display]
xlib.XDefaultRootWindow.restype = Window
xlib.XQueryTree.argtypes = [
    Display, Window,
    ctypes.POINTER(Window), ctypes.POINTER(Window),
    ctypes.POINTER(ctypes.POINTER(Window)), ctypes.POINTER(ctypes.c_uint),
]
xlib.XQueryTree.restype = ctypes.c_int
xlib.XFree.argtypes = [ctypes.c_void_p]
xlib.XInternAtom.argtypes = [Display, ctypes.c_char_p, ctypes.c_int]
xlib.XInternAtom.restype = Atom
xlib.XGetWindowProperty.argtypes = [
    Display, Window, Atom, ctypes.c_long, ctypes.c_long, ctypes.c_int, Atom,
    ctypes.POINTER(Atom), ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_ulong),
    ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_void_p),
]
xlib.XGetWindowProperty.restype = ctypes.c_int
xlib.XTranslateCoordinates.argtypes = [
    Display, Window, Window, ctypes.c_int, ctypes.c_int,
    ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int), ctypes.POINTER(Window),
]
xlib.XTranslateCoordinates.restype = ctypes.c_int
xlib.XGetGeometry.argtypes = [
    Display, Window, ctypes.POINTER(Window),
    ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int),
    ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint),
    ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint),
]
xlib.XGetGeometry.restype = ctypes.c_int
xlib.XSync.argtypes = [Display, ctypes.c_int]
xlib.XFlush.argtypes = [Display]


class XWindowAttributes(ctypes.Structure):
    _fields_ = [
        ("x", ctypes.c_int), ("y", ctypes.c_int),
        ("width", ctypes.c_int), ("height", ctypes.c_int),
        ("border_width", ctypes.c_int), ("depth", ctypes.c_int),
        ("visual", ctypes.c_void_p), ("root", Window),
        ("class_", ctypes.c_int), ("bit_gravity", ctypes.c_int),
        ("win_gravity", ctypes.c_int), ("backing_store", ctypes.c_int),
        ("backing_planes", ctypes.c_ulong), ("backing_pixel", ctypes.c_ulong),
        ("save_under", ctypes.c_int), ("colormap", ctypes.c_ulong),
        ("map_installed", ctypes.c_int), ("map_state", ctypes.c_int),
        ("all_event_masks", ctypes.c_long), ("your_event_mask", ctypes.c_long),
        ("do_not_propagate_mask", ctypes.c_long), ("override_redirect", ctypes.c_int),
        ("screen", ctypes.c_void_p),
    ]


xlib.XGetWindowAttributes.argtypes = [Display, Window, ctypes.POINTER(XWindowAttributes)]
xlib.XGetWindowAttributes.restype = ctypes.c_int
xlib.XGetSelectionOwner.argtypes = [Display, Atom]
xlib.XGetSelectionOwner.restype = Window
xlib.XDefaultScreen.argtypes = [Display]
xlib.XDefaultScreen.restype = ctypes.c_int

xtst.XTestFakeMotionEvent.argtypes = [Display, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]
xtst.XTestFakeMotionEvent.restype = ctypes.c_int
xtst.XTestFakeButtonEvent.argtypes = [Display, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
xtst.XTestFakeButtonEvent.restype = ctypes.c_int

dpy = xlib.XOpenDisplay(None)
if not dpy:
    sys.exit("xtool: cannot open display")
root = xlib.XDefaultRootWindow(dpy)
IsViewable = 2


def get_prop(win, name):
    atom = xlib.XInternAtom(dpy, name.encode(), 0)
    if atom == 0:
        return None
    actual_type = Atom(0)
    actual_format = ctypes.c_int(0)
    nitems = ctypes.c_ulong(0)
    bytes_after = ctypes.c_ulong(0)
    prop = ctypes.c_void_p()
    status = xlib.XGetWindowProperty(
        dpy, win, atom, 0, 4096, 0, 0,
        ctypes.byref(actual_type), ctypes.byref(actual_format),
        ctypes.byref(nitems), ctypes.byref(bytes_after), ctypes.byref(prop),
    )
    if status != 0 or not prop.value or nitems.value == 0:
        return None
    fmt = actual_format.value
    if fmt == 8:
        raw = ctypes.string_at(prop.value, nitems.value)
        xlib.XFree(prop)
        return raw
    if fmt == 32:
        arr = ctypes.cast(prop.value, ctypes.POINTER(ctypes.c_ulong))
        out = [arr[i] for i in range(nitems.value)]
        xlib.XFree(prop)
        return out
    xlib.XFree(prop)
    return None


def wm_class(win):
    raw = get_prop(win, "WM_CLASS")
    if not raw:
        return ""
    parts = [p.decode("utf-8", "replace") for p in raw.split(b"\x00") if p]
    return parts[-1] if parts else ""


def title(win):
    raw = get_prop(win, "_NET_WM_NAME") or get_prop(win, "WM_NAME")
    if not raw:
        return ""
    return raw.decode("utf-8", "replace").rstrip("\x00")


def attrs(win):
    a = XWindowAttributes()
    if xlib.XGetWindowAttributes(dpy, win, ctypes.byref(a)) == 0:
        return None
    return a


def abs_geom(win):
    rx, ry = ctypes.c_int(0), ctypes.c_int(0)
    child = Window(0)
    if xlib.XTranslateCoordinates(dpy, win, root, 0, 0, ctypes.byref(rx), ctypes.byref(ry), ctypes.byref(child)) == 0:
        return None
    r = Window(0)
    gx, gy = ctypes.c_int(0), ctypes.c_int(0)
    gw, gh = ctypes.c_uint(0), ctypes.c_uint(0)
    bw, depth = ctypes.c_uint(0), ctypes.c_uint(0)
    if xlib.XGetGeometry(dpy, win, ctypes.byref(r), ctypes.byref(gx), ctypes.byref(gy),
                         ctypes.byref(gw), ctypes.byref(gh), ctypes.byref(bw), ctypes.byref(depth)) == 0:
        return None
    return (rx.value, ry.value, gw.value, gh.value)


def walk(win, depth, out, max_depth=6):
    a = attrs(win)
    if a is None:
        return
    if win != root:
        g = abs_geom(win)
        out.append({
            "id": win, "class": wm_class(win), "title": title(win),
            "geom": g, "viewable": a.map_state == IsViewable,
            "depth": depth,
        })
    if depth >= max_depth:
        return
    r, p = Window(0), Window(0)
    children = ctypes.POINTER(Window)()
    n = ctypes.c_uint(0)
    if xlib.XQueryTree(dpy, win, ctypes.byref(r), ctypes.byref(p), ctypes.byref(children), ctypes.byref(n)) == 0:
        return
    kids = [children[i] for i in range(n.value)] if children else []
    if children:
        xlib.XFree(children)
    for k in kids:
        walk(k, depth + 1, out, max_depth)


def scan(win, depth_left, found):
    """递归找 XEmbed 图标窗口：(w, h, id) 入 found。"""
    r, p = Window(0), Window(0)
    children = ctypes.POINTER(Window)()
    n = ctypes.c_uint(0)
    if xlib.XQueryTree(dpy, win, ctypes.byref(r), ctypes.byref(p), ctypes.byref(children), ctypes.byref(n)) == 0:
        return
    kids = [children[i] for i in range(n.value)] if children else []
    if children:
        xlib.XFree(children)
    for k in kids:
        a = attrs(k)
        if a is None or a.map_state != IsViewable:
            continue
        g = abs_geom(k)
        if g and get_prop(k, "_XEMBED_INFO") is not None:
            found.append((g[2], g[3], k))
        elif depth_left > 1:
            scan(k, depth_left - 1, found)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd = sys.argv[1]

    if cmd == "list":
        wins = []
        walk(root, 0, wins)
        for w in wins:
            g = w["geom"] or (-1, -1, 0, 0)
            print(f'{w["id"]}\t{w["class"]}\t{w["title"][:32]}\t{g[0]},{g[1]} {g[2]}x{g[3]}\t'
                  f'mapped={int(w["viewable"])}\tdepth={w["depth"]}')
        return

    if cmd in ("find", "findclass", "findtitle"):
        want = sys.argv[2].lower()
        wins = []
        walk(root, 0, wins)
        hits = []
        for w in wins:
            if not w["viewable"] or not w["geom"]:
                continue
            in_class = want in w["class"].lower()
            in_title = want in w["title"].lower()
            if cmd == "findclass":
                hit = in_class
            elif cmd == "findtitle":
                hit = in_title
            else:
                hit = in_class or in_title
            if hit:
                hits.append(w)
        hits.sort(key=lambda w: w["geom"][2] * w["geom"][3])
        for w in hits:
            print(w["id"])
        return 0 if hits else 1

    if cmd == "geom":
        g = abs_geom(int(sys.argv[2]))
        if not g:
            return 1
        print(f"{g[0]} {g[1]} {g[2]} {g[3]}")
        return

    if cmd == "visible":
        a = attrs(int(sys.argv[2]))
        return 0 if a and a.map_state == IsViewable else 1

    if cmd == "click":
        x, y = int(sys.argv[2]), int(sys.argv[3])
        button = int(sys.argv[4]) if len(sys.argv) > 4 else 1
        xtst.XTestFakeMotionEvent(dpy, -1, x, y, 0)
        xlib.XSync(dpy, 0)
        xtst.XTestFakeButtonEvent(dpy, button, 1, 0)
        xtst.XTestFakeButtonEvent(dpy, button, 0, 0)
        xlib.XSync(dpy, 0)
        return

    if cmd == "trayicon":
        # XEmbed 托盘图标：_NET_SYSTEM_TRAY_S<n> 拥有者子树里带 _XEMBED_INFO 的可见窗口
        screen = xlib.XDefaultScreen(dpy)
        atom = xlib.XInternAtom(dpy, f"_NET_SYSTEM_TRAY_S{screen}".encode(), 0)
        owner = xlib.XGetSelectionOwner(dpy, atom)
        if not owner:
            return 1
        found = []
        scan(owner, 4, found)
        if not found:
            return 1
        found.sort(key=lambda t: t[0] * t[1])
        print(found[0][2])
        return

    if cmd == "icon":
        # 托盘图标窗口：可见、8..64px 见方、面积最小（GtkStatusIcon 是 24px 级）
        wins = []
        walk(root, 0, wins)
        cands = [
            w for w in wins
            if w["viewable"] and w["geom"]
            and 8 <= w["geom"][2] <= 64 and 8 <= w["geom"][3] <= 64
        ]
        cands.sort(key=lambda w: w["geom"][2] * w["geom"][3])
        if not cands:
            return 1
        print(cands[0]["id"])
        return

    if cmd == "active":
        vals = get_prop(root, "_NET_ACTIVE_WINDOW") or []
        print(vals[0] if vals else 0)
        return

    if cmd == "key":
        # key <keysym-name>，如 Escape / Return / F1（XStringToKeysym → keycode）
        name = sys.argv[2].encode()
        xlib.XStringToKeysym.argtypes = [ctypes.c_char_p]
        xlib.XStringToKeysym.restype = ctypes.c_ulong
        xlib.XKeysymToKeycode.argtypes = [Display, ctypes.c_ulong]
        xlib.XKeysymToKeycode.restype = ctypes.c_uint
        ks = xlib.XStringToKeysym(name)
        kc = xlib.XKeysymToKeycode(dpy, ks)
        xtst.XTestFakeKeyEvent.argtypes = [Display, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
        xtst.XTestFakeKeyEvent(dpy, kc, 1, 0)
        xtst.XTestFakeKeyEvent(dpy, kc, 0, 0)
        xlib.XSync(dpy, 0)
        return 0 if kc else 1

    if cmd == "pointer":
        root_ret, child_ret = Window(0), Window(0)
        rx, ry = ctypes.c_int(0), ctypes.c_int(0)
        wx, wy = ctypes.c_int(0), ctypes.c_int(0)
        mask = ctypes.c_uint(0)
        xlib.XQueryPointer.argtypes = [
            Display, Window, ctypes.POINTER(Window), ctypes.POINTER(Window),
            ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int),
            ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_uint),
        ]
        xlib.XQueryPointer(
            dpy, root, ctypes.byref(root_ret), ctypes.byref(child_ret),
            ctypes.byref(rx), ctypes.byref(ry), ctypes.byref(wx), ctypes.byref(wy), ctypes.byref(mask),
        )
        print(f"{rx.value} {ry.value} under={child_ret.value}")
        return

    sys.exit(f"unknown command: {cmd}")


sys.exit(main() or 0)
