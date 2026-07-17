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
