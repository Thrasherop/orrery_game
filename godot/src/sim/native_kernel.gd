class_name NativeKernel
extends RefCounted
## Backend dispatch for the compiled N-body kernel. Routes one whole physics
## frame to the fastest available implementation:
##   desktop / Android → the NBodyNative GDExtension
##   web               → a standalone WASM module driven via JavaScriptBridge
##   neither ready     → not available; Simulation falls back to GDScript
##
## advance() takes the live NBodySystem plus per-body collision inputs, runs the
## whole frame's block loop natively (integration + display + collision
## detection), and returns a normalized result the caller applies. All game
## logic (moon-host binding, trails, merge resolution) stays in GDScript.

const BACKEND_NONE := 0
const BACKEND_EXT := 1     # GDExtension (desktop/Android)
const BACKEND_WEB := 2     # WASM via JavaScriptBridge

# advance() result status (matches NBodyCore)
const ST_DONE := 0
const ST_BUDGET := 1
const ST_MERGE := 2

var _backend := BACKEND_NONE
var _ext: RefCounted = null       # NBodyNative instance
var _web_started := false


func _init() -> void:
	if ClassDB.class_exists("NBodyNative"):
		_ext = ClassDB.instantiate("NBodyNative")
		if _ext != null:
			_backend = BACKEND_EXT
			return
	if OS.has_feature("web") and _has_js():
		_backend = BACKEND_WEB
		_start_web()


func _has_js() -> bool:
	# JavaScriptBridge exists only on the web platform
	return ClassDB.class_exists("JavaScriptBridge") or Engine.has_singleton("JavaScriptBridge")


## Ready to take frames? (web loads its module asynchronously.)
func ready() -> bool:
	if _backend == BACKEND_EXT:
		return true
	if _backend == BACKEND_WEB:
		return int(JavaScriptBridge.eval("window.__nbk_ready === true ? 1 : 0", true)) == 1
	return false


func backend_name() -> String:
	match _backend:
		BACKEND_EXT: return "native (GDExtension)"
		BACKEND_WEB: return "native (WASM)"
		_: return "gdscript"


## Advance one whole frame. `sizes`/`bks` are per-body display radius and moon
## amplification (0 = not a bound moon); `fc` is nb.frame_corr. Returns the
## Dictionary shape produced by NBodyNative.advance_frame (status/merge_i/
## merge_j/work/blocks/remaining_days/tau_min + px..vz/disp/tau_body arrays).
func advance(nb: NBodySystem, sizes: PackedFloat64Array, bks: PackedFloat64Array,
		fc: Vector3, g_scale: float, dt_days: float,
		h_min: float, h_max: float, tau_frac: float, budget: float) -> Dictionary:
	if _backend == BACKEND_EXT:
		return _ext.advance_frame(nb.px, nb.py, nb.pz, nb.vx, nb.vy, nb.vz, nb.m,
			sizes, bks, fc.x, fc.y, fc.z, g_scale, dt_days,
			h_min, h_max, tau_frac, budget, true)
	return _web_advance(nb, sizes, bks, fc, g_scale, dt_days, h_min, h_max, tau_frac, budget)


# ================================================================
# Web (WASM via JavaScriptBridge)
# ================================================================
func _start_web() -> void:
	if _web_started:
		return
	_web_started = true
	# Inject the module loader + a one-call-per-frame helper. The wasm holds the
	# integration state; JS marshals arrays through its heap so GDScript crosses
	# the bridge just once per frame.
	JavaScriptBridge.eval("""
		(function(){
		  if (window.__nbk_boot) return;
		  window.__nbk_boot = true;
		  window.__nbk_ready = false;
		  window.__nbk_err = '';
		  window.__nb_frame = function(jsonIn){
		    var o = JSON.parse(jsonIn);
		    var m = window.__nbm, n = o.n;
		    var inN = 9 * n, outN = 7 + 10 * n;
		    if (!window.__nb_inPtr || window.__nb_cap < Math.max(inN, outN)) {
		      if (window.__nb_inPtr) { m._free(window.__nb_inPtr); m._free(window.__nb_outPtr); }
		      window.__nb_cap = Math.max(inN, outN) + 64;
		      window.__nb_inPtr = m._malloc(window.__nb_cap * 8);
		      window.__nb_outPtr = m._malloc(window.__nb_cap * 8);
		    }
		    m.HEAPF64.set(o.state, window.__nb_inPtr / 8);
		    m.ccall('nb_frame', 'number',
		      ['number','number','number','number','number','number','number','number','number','number','number','number'],
		      [n, window.__nb_inPtr, o.g, o.dt, o.hmin, o.hmax, o.tfrac, o.budget, o.fcx, o.fcy, o.fcz, window.__nb_outPtr]);
		    var out = m.HEAPF64.subarray(window.__nb_outPtr / 8, window.__nb_outPtr / 8 + outN);
		    return JSON.stringify(Array.prototype.slice.call(out));
		  };
		  var s = document.createElement('script');
		  s.src = 'nbody.js';
		  s.onerror = function(){ window.__nbk_err = 'nbody.js failed to load'; };
		  s.onload = function(){
		    try { NBodyModule().then(function(mod){ window.__nbm = mod; window.__nbk_ready = true; })
		                       .catch(function(e){ window.__nbk_err = '' + e; }); }
		    catch(e){ window.__nbk_err = '' + e; }
		  };
		  document.body.appendChild(s);
		})();
	""", true)


func _web_advance(nb: NBodySystem, sizes: PackedFloat64Array, bks: PackedFloat64Array,
		fc: Vector3, g_scale: float, dt_days: float,
		h_min: float, h_max: float, tau_frac: float, budget: float) -> Dictionary:
	var n := nb.count()
	# pack state: px,py,pz,vx,vy,vz,m,size,bound_k (9n)
	var state := PackedFloat64Array()
	state.resize(9 * n)
	for i in n:
		state[i] = nb.px[i]
		state[n + i] = nb.py[i]
		state[2 * n + i] = nb.pz[i]
		state[3 * n + i] = nb.vx[i]
		state[4 * n + i] = nb.vy[i]
		state[5 * n + i] = nb.vz[i]
		state[6 * n + i] = nb.m[i]
		state[7 * n + i] = sizes[i]
		state[8 * n + i] = bks[i]
	var payload := {
		n = n, state = state, g = g_scale, dt = dt_days,
		hmin = h_min, hmax = h_max, tfrac = tau_frac, budget = budget,
		fcx = fc.x, fcy = fc.y, fcz = fc.z,
	}
	var code := "window.__nb_frame('" + JSON.stringify(payload) + "')"
	var out_json := str(JavaScriptBridge.eval(code, true))
	var arr = JSON.parse_string(out_json)
	if typeof(arr) != TYPE_ARRAY:
		return {}   # bridge hiccup — caller falls back to GDScript this frame
	# unpack: [status, merge_i, merge_j, work, blocks, remaining, tau_min, then arrays]
	var px := PackedFloat64Array(); var py := PackedFloat64Array(); var pz := PackedFloat64Array()
	var vx := PackedFloat64Array(); var vy := PackedFloat64Array(); var vz := PackedFloat64Array()
	var disp := PackedFloat64Array(); var tau := PackedFloat64Array()
	px.resize(n); py.resize(n); pz.resize(n); vx.resize(n); vy.resize(n); vz.resize(n)
	disp.resize(3 * n); tau.resize(n)
	var o := 7
	for i in n: px[i] = arr[o + i]
	o += n
	for i in n: py[i] = arr[o + i]
	o += n
	for i in n: pz[i] = arr[o + i]
	o += n
	for i in n: vx[i] = arr[o + i]
	o += n
	for i in n: vy[i] = arr[o + i]
	o += n
	for i in n: vz[i] = arr[o + i]
	o += n
	for i in 3 * n: disp[i] = arr[o + i]
	o += 3 * n
	for i in n: tau[i] = arr[o + i]
	return {
		status = int(arr[0]), merge_i = int(arr[1]), merge_j = int(arr[2]),
		work = float(arr[3]), blocks = int(arr[4]), remaining_days = float(arr[5]),
		tau_min = float(arr[6]),
		px = px, py = py, pz = pz, vx = vx, vy = vy, vz = vz, disp = disp, tau_body = tau,
	}
