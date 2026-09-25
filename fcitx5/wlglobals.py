#!/usr/bin/env python3
"""枚举当前 Wayland compositor 暴露的协议（无需 root、无需编译器）。

用法: python3 wlglobals.py
关注: zwp_text_input_manager_v3（应用侧）、zwp_input_method_manager_v2（输入法侧，
GNOME 不暴露此协议，所以 fcitx5 的 waylandim 前端在 GNOME 上不可用）。
"""
import ctypes, sys

wl = ctypes.CDLL("libwayland-client.so.0")

wl.wl_display_connect.restype = ctypes.c_void_p
wl.wl_display_roundtrip.restype = ctypes.c_int
wl.wl_proxy_marshal_flags.restype = ctypes.c_void_p
wl.wl_proxy_marshal_flags.argtypes = [ctypes.c_void_p, ctypes.c_uint32,
                                      ctypes.c_void_p, ctypes.c_uint32,
                                      ctypes.c_uint32]
wl.wl_proxy_get_version.restype = ctypes.c_uint32
wl.wl_proxy_get_version.argtypes = [ctypes.c_void_p]
wl.wl_proxy_add_listener.restype = ctypes.c_int
wl.wl_proxy_add_listener.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]

registry_iface = ctypes.c_void_p.in_dll(wl, "wl_registry_interface")

GLOBAL_CB = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p,
                             ctypes.c_uint32, ctypes.c_char_p, ctypes.c_uint32)
REMOVE_CB = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32)

def on_global(data, registry, name, interface, version):
    print(f"{interface.decode()} version={version} name={name}")

def on_remove(data, registry, name):
    pass

class Listener(ctypes.Structure):
    _fields_ = [("global_", GLOBAL_CB), ("global_remove", REMOVE_CB)]

display = wl.wl_display_connect(None)
if not display:
    sys.exit("cannot connect to wayland")
ver = wl.wl_proxy_get_version(display)
registry = wl.wl_proxy_marshal_flags(display, 1, ctypes.byref(registry_iface), ver, 0)
listener = Listener(GLOBAL_CB(on_global), REMOVE_CB(on_remove))
wl.wl_proxy_add_listener(registry, ctypes.cast(ctypes.byref(listener), ctypes.c_void_p), None)
wl.wl_display_roundtrip(display)
