extends Node
## Web proof-of-concept: proves a standalone Emscripten WASM module can be
## driven from a Godot web export via JavaScriptBridge, and measures the WASM
## kernel vs GDScript step_block running IN THE BROWSER. Set as the temporary
## main scene, exported to web, and checked with headless Chrome.
## Sentinel lines: WEB_POC_RESULT / WEB_POC_ERROR / WEB_POC_DONE.

var _phase := 0
var _waited := 0.0


func _ready() -> void:
	if not OS.has_feature("web"):
		print("WEB_POC skipped (not a web export)")
		print("WEB_POC_DONE")
		return
	print("WEB_POC injecting wasm loader")
	JavaScriptBridge.eval("""
		(function(){
		  if (window.__nb_started) return;
		  window.__nb_started = true;
		  window.__nb_ready = false;
		  window.__nb_err = '';
		  var s = document.createElement('script');
		  s.src = 'nbody.js';
		  s.onerror = function(){ window.__nb_err = 'nbody.js failed to load'; };
		  s.onload = function(){
		    try {
		      NBodyModule().then(function(m){ window.__nbm = m; window.__nb_ready = true; })
		                   .catch(function(e){ window.__nb_err = 'instantiate: ' + e; });
		    } catch(e){ window.__nb_err = 'onload: ' + e; }
		  };
		  document.body.appendChild(s);
		})();
	""", true)


func _process(delta: float) -> void:
	if not OS.has_feature("web") or _phase >= 2:
		return
	if _phase == 0:
		var err := str(JavaScriptBridge.eval("window.__nb_err || ''", true))
		if err != "":
			print("WEB_POC_ERROR ", err)
			print("WEB_POC_DONE")
			_phase = 2
			return
		var ready = JavaScriptBridge.eval("window.__nb_ready === true ? 1 : 0", true)
		_waited += delta
		if int(ready) == 1:
			_phase = 1
		elif _waited > 20.0:
			print("WEB_POC_ERROR wasm never became ready")
			print("WEB_POC_DONE")
			_phase = 2
	elif _phase == 1:
		_run_bench()
		_phase = 2
		print("WEB_POC_DONE")


func _run_bench() -> void:
	# --- WASM bench (in-browser, via JavaScriptBridge) ---
	var wasm_js := """
		(function(){
		  var m = window.__nbm;
		  m.ccall('nb_seed_demo', null, ['number'], [16]);
		  m.ccall('nb_bench','number',['number','number','number'],[200,0.1,1.0]);
		  var t0 = performance.now();
		  var chk = m.ccall('nb_bench','number',['number','number','number'],[20000,0.1,1.0]);
		  var t1 = performance.now();
		  window.__nb_chk = chk;
		  return (t1 - t0) * 1000.0 / 20000.0;
		})();
	"""
	var wasm_us := float(JavaScriptBridge.eval(wasm_js, true))

	# --- GDScript bench (same synthetic system, in-browser) ---
	var nb := _seed_gd(16)
	var gd_count := 4000
	# warm-up
	for k in 200:
		nb.step_block(0.1, 1.0)
	var t0 := Time.get_ticks_usec()
	for k in gd_count:
		nb.step_block(0.1, 1.0)
	var gd_us := float(Time.get_ticks_usec() - t0) / float(gd_count)

	print("WEB_POC_RESULT wasm_us_per_block=%.4f gd_us_per_block=%.4f speedup=%.1f" % [
		wasm_us, gd_us, gd_us / maxf(wasm_us, 0.0001)])


## mirror nb_seed_demo (nbody_wasm.cpp) so both kernels run the same workload
func _seed_gd(n: int) -> NBodySystem:
	var nb := NBodySystem.new()
	for i in n:
		nb.add_body(SimBody.new(), 1.0)
	nb.px[0] = 0.0; nb.py[0] = 0.0; nb.pz[0] = 0.0
	nb.vx[0] = 0.0; nb.vy[0] = 0.0; nb.vz[0] = 0.0
	nb.m[0] = 1.0
	for i in range(1, n):
		var a := 0.4 + i * 0.35
		var v := sqrt(Units.GM_SUN / a)
		nb.px[i] = a; nb.py[i] = 0.0; nb.pz[i] = 0.0
		nb.vx[i] = 0.0; nb.vy[i] = v; nb.vz[i] = 0.0
		nb.m[i] = 1e-3 if (i % 4 == 0) else 1e-7
	if n > 6:
		var host := 4
		for k in 2:
			var mi := host + 1 + k
			if mi < n:
				var da := 0.002 + k * 0.001
				nb.px[mi] = nb.px[host] + da; nb.py[mi] = 0.0; nb.pz[mi] = 0.0
				var vmoon := sqrt(Units.GM_SUN * nb.m[host] / da)
				nb.vx[mi] = 0.0; nb.vy[mi] = nb.vy[host] + vmoon; nb.vz[mi] = 0.0
				nb.m[mi] = 1e-8
	nb.compute_accel(1.0)
	return nb
