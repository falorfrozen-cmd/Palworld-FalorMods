# Edits the user's own Workshop item through the Steam client that is running
# and logged in (same Steam API library the official uploader uses).
#   python steam_page.py <tool dir> <item id> describe <description file>
#   python steam_page.py <tool dir> <item id> deps <child id> [<child id> ...]
#   python steam_page.py <tool dir> <item id> visibility <0 public | 1 friends | 2 private | 3 unlisted>
#   python steam_page.py <tool dir> <item id> subscribe
import ctypes, os, sys, time

APP_ID = 1623730            # Palworld
tool_dir, ITEM_ID, mode, rest = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4:]

# steam_appid.txt is read from the current folder; STEAM_CWD picks another folder
# (one whose steam_appid.txt holds 1623730 = act as Palworld, needed to subscribe)
os.chdir(os.environ.get("STEAM_CWD", tool_dir))
os.add_dll_directory(tool_dir)
api = ctypes.CDLL(os.path.join(tool_dir, "steam_api64.dll"))

P, U64, U32, I32, B = ctypes.c_void_p, ctypes.c_uint64, ctypes.c_uint32, ctypes.c_int, ctypes.c_bool
def fn(name, restype, *argtypes):
    f = getattr(api, name); f.restype = restype; f.argtypes = list(argtypes); return f

init = fn("SteamAPI_InitFlat", I32, ctypes.c_char_p)
shutdown = fn("SteamAPI_Shutdown", None)
run_callbacks = fn("SteamAPI_RunCallbacks", None)
get_ugc = fn("SteamAPI_SteamUGC_v021", P)
get_utils = fn("SteamAPI_SteamUtils_v010", P)
start_update = fn("SteamAPI_ISteamUGC_StartItemUpdate", U64, P, U32, U64)
set_desc = fn("SteamAPI_ISteamUGC_SetItemDescription", B, P, U64, ctypes.c_char_p)
set_vis = fn("SteamAPI_ISteamUGC_SetItemVisibility", B, P, U64, I32)
submit = fn("SteamAPI_ISteamUGC_SubmitItemUpdate", U64, P, U64, ctypes.c_char_p)
add_dep = fn("SteamAPI_ISteamUGC_AddDependency", U64, P, U64, U64)
subscribe = fn("SteamAPI_ISteamUGC_SubscribeItem", U64, P, U64)
is_done = fn("SteamAPI_ISteamUtils_IsAPICallCompleted", B, P, U64, ctypes.POINTER(B))
get_result = fn("SteamAPI_ISteamUtils_GetAPICallResult", B, P, U64, P, I32, I32, ctypes.POINTER(B))

class SubmitResult(ctypes.Structure):          # SubmitItemUpdateResult_t, callback 3404
    _pack_ = 8
    _fields_ = [("result", I32), ("needs_agreement", B), ("item", U64)]
class DepResult(ctypes.Structure):             # AddUGCDependencyResult_t, callback 3412
    _pack_ = 8
    _fields_ = [("result", I32), ("parent", U64), ("child", U64)]

err = ctypes.create_string_buffer(1024)
rc = init(err)
if rc != 0:
    print("Steam init failed:", rc, err.value.decode("utf-8", "replace")); sys.exit(2)
ugc, utils = get_ugc(), get_utils()
if not ugc or not utils:
    print("no UGC/Utils interface"); shutdown(); sys.exit(2)

def wait(call, struct_type, callback_id, seconds=60):
    failed = B(False)
    end = time.time() + seconds
    while time.time() < end:
        run_callbacks()
        if is_done(utils, call, ctypes.byref(failed)):
            out = struct_type()
            ok = get_result(utils, call, ctypes.byref(out), ctypes.sizeof(out), callback_id, ctypes.byref(failed))
            return ok and not failed.value, out
        time.sleep(0.2)
    return False, None

code = 0
try:
    if mode in ("describe", "visibility"):
        h = start_update(ugc, APP_ID, ITEM_ID)
        if mode == "describe":
            text = open(rest[0], "rb").read()
            if len(text) >= 8000:
                print("description too long:", len(text)); sys.exit(2)
            print("SetItemDescription ->", set_desc(ugc, h, text))
        else:
            print("SetItemVisibility(%s) ->" % rest[0], set_vis(ugc, h, int(rest[0])))
        call = submit(ugc, h, None)
        ok, r = wait(call, SubmitResult, 3404)
        if r is None:
            print("no answer from Steam (timeout)"); code = 1
        else:
            print("submit: ok=%s EResult=%d needs_legal_agreement=%s item=%d" % (ok, r.result, r.needs_agreement, r.item))
            if not ok or r.result != 1: code = 1
    elif mode == "deps":
        for child in rest:
            call = add_dep(ugc, ITEM_ID, int(child))
            ok, r = wait(call, DepResult, 3412)
            if r is None:
                print("dependency %s: no answer (timeout)" % child); code = 1
            else:
                print("dependency %s: ok=%s EResult=%d" % (child, ok, r.result))
                if not ok or r.result != 1: code = 1
    elif mode == "subscribe":
        call = subscribe(ugc, ITEM_ID)
        ok, r = wait(call, DepResult, 1313)   # RemoteStorageSubscribePublishedFileResult_t: result + item id
        if r is None:
            print("subscribe: no answer (timeout)"); code = 1
        else:
            print("subscribe: ok=%s EResult=%d item=%d" % (ok, r.result, r.parent))
            if not ok or r.result != 1: code = 1
    else:
        print("unknown mode"); code = 2
finally:
    shutdown()
sys.exit(code)
