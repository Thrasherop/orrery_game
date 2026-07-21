#include "nbody_core.h"
#include <algorithm>
#include <cmath>

void NBodyCore::resize(int n_) {
	n = n_;
	px.resize(n); py.resize(n); pz.resize(n);
	vx.resize(n); vy.resize(n); vz.resize(n);
	ax.assign(n, 0.0); ay.assign(n, 0.0); az.assign(n, 0.0);
	m.resize(n);
	tau_body.assign(n, INF_D);
	k_sub.assign(n, 1);
	enc_min_r2.assign((size_t)n * n, INF_D);
	size.assign(n, 1.0);
	bound_k.assign(n, 0.0);
	dispx.assign(n, 0.0); dispy.assign(n, 0.0); dispz.assign(n, 0.0);
	pdispx.assign(n, 0.0); pdispy.assign(n, 0.0); pdispz.assign(n, 0.0);
}

// Faithful port of NBodySystem.compute_accel: hoisted inner loop + per-body
// tau (lighter member, both when comparable).
void NBodyCore::compute_accel(double g_scale) {
	const double G = GM_SUN * g_scale;
	double tau2min = INF_D;
	double *P_x = px.data(), *P_y = py.data(), *P_z = pz.data();
	double *A_x = ax.data(), *A_y = ay.data(), *A_z = az.data();
	double *M = m.data(), *TB = tau_body.data();
	for (int q = 0; q < n; q++) {
		A_x[q] = 0.0; A_y[q] = 0.0; A_z[q] = 0.0;
		TB[q] = INF_D;
	}
	for (int i = 0; i < n; i++) {
		const double pxi = P_x[i], pyi = P_y[i], pzi = P_z[i], mi = M[i];
		double axi = 0.0, ayi = 0.0, azi = 0.0;
		double ti = TB[i];
		for (int j = i + 1; j < n; j++) {
			const double mj = M[j];
			const double dx = P_x[j] - pxi;
			const double dy = P_y[j] - pyi;
			const double dz = P_z[j] - pzi;
			const double r2 = dx * dx + dy * dy + dz * dz + EPS2;
			const double r3 = r2 * std::sqrt(r2);
			const double f = G / r3;
			axi += f * mj * dx;
			ayi += f * mj * dy;
			azi += f * mj * dz;
			A_x[j] -= f * mi * dx;
			A_y[j] -= f * mi * dy;
			A_z[j] -= f * mi * dz;
			const double t2 = r3 / (G * (mi + mj));
			if (t2 < tau2min) tau2min = t2;
			if (mj <= mi) {
				if (t2 < TB[j]) TB[j] = t2;
				if (t2 < ti && mj > mi * MASS_COMPARABLE) ti = t2;
			} else {
				if (t2 < ti) ti = t2;
				if (t2 < TB[j] && mi > mj * MASS_COMPARABLE) TB[j] = t2;
			}
		}
		A_x[i] += axi; A_y[i] += ayi; A_z[i] += azi;
		TB[i] = ti;
	}
	for (int q = 0; q < n; q++) TB[q] = std::sqrt(TB[q]);
	tau_min = std::sqrt(tau2min);
}

void NBodyCore::accel_on(int fi, double t, double H, double G) {
	const double pxi = px[fi], pyi = py[fi], pzi = pz[fi];
	const double mi = m[fi];
	double axl = 0.0, ayl = 0.0, azl = 0.0;
	const double back = H - t;
	const size_t base = (size_t)fi * n;
	for (int j = 0; j < n; j++) {
		if (j == fi) continue;
		double pxj = px[j], pyj = py[j], pzj = pz[j];
		if (k_sub[j] == 1) {
			pxj -= vx[j] * back;
			pyj -= vy[j] * back;
			pzj -= vz[j] * back;
		}
		const double dx = pxj - pxi;
		const double dy = pyj - pyi;
		const double dz = pzj - pzi;
		const double r2 = dx * dx + dy * dy + dz * dz + EPS2;
		if (r2 < enc_min_r2[base + j]) enc_min_r2[base + j] = r2;
		const double f = G * m[j] / (r2 * std::sqrt(r2));
		axl += f * dx;
		ayl += f * dy;
		azl += f * dz;
	}
	last_fast_evals += n - 1;
	_f_ax = axl; _f_ay = ayl; _f_az = azl;
}

// Faithful port of NBodySystem.step_block.
void NBodyCore::step_block(double H, double g_scale) {
	int k_big = 1;
	for (int i = 0; i < n; i++) {
		const double need = H * SAFETY / tau_body[i];
		int k = 1;
		while (k < K_MAX && (double)k < need) k *= 2;
		k_sub[i] = k;
		if (k > k_big) k_big = k;
	}
	had_fast = k_big > 1;
	last_fast_evals = 0;
	if (!had_fast) {
		const double h2 = H / 2.0;
		for (int i = 0; i < n; i++) {
			vx[i] += ax[i] * h2; vy[i] += ay[i] * h2; vz[i] += az[i] * h2;
			px[i] += vx[i] * H; py[i] += vy[i] * H; pz[i] += vz[i] * H;
		}
		compute_accel(g_scale);
		for (int i = 0; i < n; i++) {
			vx[i] += ax[i] * h2; vy[i] += ay[i] * h2; vz[i] += az[i] * h2;
		}
		return;
	}

	std::fill(enc_min_r2.begin(), enc_min_r2.end(), INF_D);
	const double G = GM_SUN * g_scale;
	const double h_min_step = H / (double)k_big;

	for (int i = 0; i < n; i++) {
		const double h2 = H / (2.0 * (double)k_sub[i]);
		vx[i] += ax[i] * h2; vy[i] += ay[i] * h2; vz[i] += az[i] * h2;
	}
	for (int i = 0; i < n; i++) {
		if (k_sub[i] == 1) {
			px[i] += vx[i] * H; py[i] += vy[i] * H; pz[i] += vz[i] * H;
		}
	}

	for (int s = 0; s < k_big; s++) {
		for (int i = 0; i < n; i++) {
			const int ki = k_sub[i];
			if (ki > 1 && s % (k_big / ki) == 0) {
				const double h = H / (double)ki;
				px[i] += vx[i] * h; py[i] += vy[i] * h; pz[i] += vz[i] * h;
			}
		}
		for (int i = 0; i < n; i++) {
			const int ki = k_sub[i];
			if (ki > 1 && s % (k_big / ki) == 0) {
				const int s_next = s + k_big / ki;
				if (s_next < k_big) {
					accel_on(i, (double)s_next * h_min_step, H, G);
					const double h = H / (double)ki;
					vx[i] += _f_ax * h; vy[i] += _f_ay * h; vz[i] += _f_az * h;
				}
			}
		}
	}

	compute_accel(g_scale);
	for (int i = 0; i < n; i++) {
		const double h2 = H / (2.0 * (double)k_sub[i]);
		vx[i] += ax[i] * h2; vy[i] += ay[i] * h2; vz[i] += az[i] * h2;
	}
}

// --- display compression (Units.gd) ---
double NBodyCore::dist_scale(double r) {
	if (r <= 0.0) return 0.0;
	if (r < DIST_R0) return DIST_K * std::pow(DIST_R0, DIST_P) * (r / DIST_R0);
	return DIST_K * std::pow(r, DIST_P);
}

void NBodyCore::to_display(double vx_, double vy_, double vz_, double &ox, double &oy, double &oz) {
	double r = std::sqrt(vx_ * vx_ + vy_ * vy_ + vz_ * vz_);
	if (r < 1e-9) { ox = 0.0; oy = 0.0; oz = 0.0; return; }
	double s = dist_scale(r) / r;
	ox = vx_ * s; oy = vy_ * s; oz = vz_ * s;
}

// Faithful port of NBodySystem.refresh_display (sun-anchored heliocentric
// compression; the sun's own barycentric wobble is compressed separately).
void NBodyCore::refresh_display(bool reset_prev) {
	// mass-weighted barycenter
	double bx = 0.0, by = 0.0, bz = 0.0, M = 0.0;
	for (int i = 0; i < n; i++) { bx += px[i] * m[i]; by += py[i] * m[i]; bz += pz[i] * m[i]; M += m[i]; }
	if (M != 0.0) { bary_x = bx / M; bary_y = by / M; bary_z = bz / M; }
	double sdx = 0.0, sdy = 0.0, sdz = 0.0;
	if (n > 0) {
		to_display(px[0] - bary_x + frame_corr_x, py[0] - bary_y + frame_corr_y,
				pz[0] - bary_z + frame_corr_z, sdx, sdy, sdz);
	}
	for (int i = 0; i < n; i++) {
		if (!reset_prev) { pdispx[i] = dispx[i]; pdispy[i] = dispy[i]; pdispz[i] = dispz[i]; }
		if (i == 0) { dispx[i] = sdx; dispy[i] = sdy; dispz[i] = sdz; }
		else {
			double ox, oy, oz;
			to_display(px[i] - px[0], py[i] - py[0], pz[i] - pz[0], ox, oy, oz);
			dispx[i] = sdx + ox; dispy[i] = sdy + oy; dispz[i] = sdz + oz;
		}
		if (reset_prev) { pdispx[i] = dispx[i]; pdispy[i] = dispy[i]; pdispz[i] = dispz[i]; }
	}
}

double NBodyCore::real_distance(int i, int j) const {
	double dx = px[i] - px[j], dy = py[i] - py[j], dz = pz[i] - pz[j];
	return std::sqrt(dx * dx + dy * dy + dz * dz);
}

double NBodyCore::swept_distance(int i, int j) const {
	double p0x = pdispx[i] - pdispx[j], p0y = pdispy[i] - pdispy[j], p0z = pdispz[i] - pdispz[j];
	double ux = (dispx[i] - dispx[j]) - p0x;
	double uy = (dispy[i] - dispy[j]) - p0y;
	double uz = (dispz[i] - dispz[j]) - p0z;
	double uu = ux * ux + uy * uy + uz * uz;
	double t = 0.0;
	if (uu > 1e-12) t = -(p0x * ux + p0y * uy + p0z * uz) / uu;
	if (t < 0.0) t = 0.0; else if (t > 1.0) t = 1.0;
	double cx = p0x + ux * t, cy = p0y + uy * t, cz = p0z + uz * t;
	return std::sqrt(cx * cx + cy * cy + cz * cz);
}

double NBodyCore::enc_distance(int i, int j) const {
	if (!had_fast) return INF_D;
	double a = enc_min_r2[(size_t)i * n + j];
	double b = enc_min_r2[(size_t)j * n + i];
	double r2 = a < b ? a : b;
	return r2 < INF_D ? std::sqrt(r2) : INF_D;
}

// Faithful port of Simulation._step_physics's block loop (minus trails, which
// stay in GDScript). Returns DONE/BUDGET/MERGE; on MERGE, merge_i/merge_j are
// the colliding pair for the caller to resolve.
int NBodyCore::advance(double dt_days, double g_scale, double h_min, double h_max,
		double tau_frac, double budget) {
	double remaining = dt_days;
	work = 0.0;
	blocks = 0;
	merge_i = -1; merge_j = -1;
	while (remaining > 1e-9) {
		if (work >= budget) { remaining_days = remaining; return BUDGET; }
		blocks++;
		double H = tau_min * tau_frac;
		if (H < h_min) H = h_min; else if (H > h_max) H = h_max;
		if (H > remaining) H = remaining;
		step_block(H, g_scale);
		work += 1.0 + 2.0 * (double)last_fast_evals / (double)(n * n > 0 ? n * n : 1);
		refresh_display(false);
		// collision scan (boundary cadence)
		for (int i = 0; i < n - 1; i++) {
			for (int j = i + 1; j < n; j++) {
				double bk = 0.0;
				if (bound_k[i] > 0.0) bk = bound_k[i];
				if (bound_k[j] > bk) bk = bound_k[j];
				double thresh = 0.75 * (size[i] + size[j]);
				bool hit;
				if (bk > 0.0) {
					double rmin = real_distance(i, j);
					double enc = enc_distance(i, j);
					if (enc < rmin) rmin = enc;
					hit = rmin * bk < thresh;
				} else {
					hit = swept_distance(i, j) < thresh;
				}
				if (hit) { merge_i = i; merge_j = j; remaining -= H; remaining_days = remaining; return MERGE; }
			}
		}
		remaining -= H;
	}
	remaining_days = remaining > 0.0 ? remaining : 0.0;
	return remaining > 1e-9 ? BUDGET : DONE;
}
