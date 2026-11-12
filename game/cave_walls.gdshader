shader_type canvas_item;

// Отрисовка стен пещеры на GPU.
// Коридор считается аналитически в фрагментном шейдере по таблице узлов,
// которую GDScript заливает в knot_tex. Сверху накладываются острые переломы
// (ridge), как в cave.gd — отрисовка совпадает с физикой.

uniform sampler2D knot_tex : filter_nearest, repeat_disable;
uniform float knot_start = -2.0;   // индекс узла, лежащий в texel 0

uniform vec4 rock_color : source_color = vec4(0.24, 0.17, 0.13, 1.0);
uniform vec4 rock_color_hi : source_color = vec4(0.33, 0.24, 0.19, 1.0);
uniform vec4 rim_color : source_color = vec4(0.37, 0.28, 0.21, 1.0);
uniform float rim_width : hint_range(1.0, 12.0) = 5.0;

varying vec2 w_pos;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float ridge(float t, float freq, float amp, float phase) {
	float u = t * freq + phase;
	u = u - floor(u / 2.0) * 2.0;     // fposmod(t, 2) в том же виде
	return (abs(u - 1.0) * 2.0 - 1.0) * amp;
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x),
			   mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}

void vertex() {
	// мировые координаты этого фрагмента (Quad в мире, MODEL_MATRIX переводит в мир)
	w_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	float KNOT = 256.0;
	float y = w_pos.y;
	float kf = floor(y / KNOT);
	float ti = kf - knot_start;
	vec2 a = texture(knot_tex, vec2(clamp((ti + 0.5) / 32.0, 0.0, 1.0), 0.5)).rg;
	vec2 b = texture(knot_tex, vec2(clamp((ti + 1.5) / 32.0, 0.0, 1.0), 0.5)).rg;
	float t = fract(y / KNOT);

	float center = mix(a.x, b.x, t);
	// плавный выход из старта — как center_at() в cave.gd
	center *= clamp(abs(y) / (3.0 * KNOT), 0.0, 1.0);
	float half_w = mix(a.y, b.y, t);

	// угловатые переломы (те же частоты/фазы, что в cave.gd)
	float ridge_l = ridge(y, 0.016, 17.0, 0.3) + ridge(y, 0.007, 11.0, 1.1);
	float ridge_r = ridge(y, 0.014, 17.0, 2.2) + ridge(y, 0.006, 11.0, 0.7);

	// расстояние до ближайшей границы коридора; > 0 — порода
	float d_left = (center - half_w + ridge_l) - w_pos.x;
	float d_right = w_pos.x - (center + half_w + ridge_r);
	float d = max(d_left, d_right);
	if (d < 0.0) {
		discard;   // сам коридор прозрачный — виден фон
	}

	// скальная текстура: value-noise + редкие трещины (угловатые тёмные поры)
	float n = vnoise(w_pos * 0.055) * 0.68 + vnoise(w_pos * 0.19) * 0.24 + vnoise(w_pos * 0.055) * vnoise(w_pos * 0.19) * 0.08;
	vec3 col = mix(rock_color.rgb, rock_color_hi.rgb, n);
	float crack = step(0.92, hash21(floor(w_pos * 0.13)));
	col = mix(col, col * 0.55, crack * 0.65);

	// острый ободок ровно на границе коридора
	float rim = 1.0 - smoothstep(0.0, rim_width, abs(d));
	col = mix(col, rim_color.rgb, rim);

	COLOR = vec4(col, 1.0);
}
