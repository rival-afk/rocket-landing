#version 450
// TAS: один тик перебора. Каждая нить = одна комбинация (beam-запись × действие).
// Интегрирует физику как в torque.gd + Godot 2D (semi-implicit Euler, dt = 1/60),
// проверяет пересечение ракеты со стеной пещеры (5 точек), считает score.
// Формулы пещеры повторяют cave.gd бит в бит.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) buffer InBuf {
    float states[];  // [x, y, vx, vy, rot] * N
} src;

layout(set = 0, binding = 1, std430) buffer OutBuf {
    float children[];  // 8 float-ов на ребёнка: nx, ny, nvx, nvy, nrot, hit, score, pad
} dst;

const float GRAVITY = 980.0;
const float THRUST = 1500.0;
const float TICK = 1.0 / 60.0;
const float ANGULAR = 4.0;
const float HALF_W = 12.0;
const float HALF_H = 14.0;

const float MAX_SHIFT = 175.0;
const float MIN_HALF = 60.0;
const float HALF_VAR = 55.0;
const float KNOT = 256.0;

float cave_hash(float n) {
    float s = sin(n * 127.1 + 311.7) * 43758.5453;
    return s - floor(s);
}

float knot_offset(float k) {
    if (k == 0.0) return 0.0;
    return (cave_hash(k) * 2.0 - 1.0) * MAX_SHIFT;
}

float knot_half(float k) {
    return MIN_HALF + cave_hash(k + 1000.0) * HALF_VAR;
}

float cave_center(float y) {
    float k = floor(y / KNOT);
    float t = (y - k * KNOT) / KNOT;
    float v = mix(knot_offset(k), knot_offset(k + 1.0), t);
    return v * clamp(abs(y) / (3.0 * KNOT), 0.0, 1.0);
}

float cave_half(float y) {
    float k = floor(y / KNOT);
    float t = (y - k * KNOT) / KNOT;
    return mix(knot_half(k), knot_half(k + 1.0), t);
}

bool hits_point(float px, float py) {
    float c = cave_center(py);
    float h = cave_half(py);
    return abs(px - c) >= h;
}

float off_at(float x, float y) {
    float c = cave_center(y);
    float h = cave_half(y);
    return abs(x - c) / max(h, 1.0);
}

void main() {
    uint gid = gl_GlobalInvocationID.x;
    uint child_count = uint(src.states.length() / 5u * 6u);
    if (gid >= child_count) return;

    uint parent = gid / 6u;
    uint action = gid % 6u;  // 0=-, 1=←, 2=→, 3=▲, 4=▲+←, 5=▲+→

    float x = src.states[parent * 5u + 0u];
    float y = src.states[parent * 5u + 1u];
    float vx = src.states[parent * 5u + 2u];
    float vy = src.states[parent * 5u + 3u];
    float rot = src.states[parent * 5u + 4u];

    float torques[6] = float[6](0.0, -1.0, 1.0, 0.0, -1.0, 1.0);
    float torque = torques[action];
    bool thrust = action >= 3u;

    vy += GRAVITY * TICK;
    if (thrust) {
        vx += sin(rot) * THRUST * TICK;
        vy += -cos(rot) * THRUST * TICK;
    }
    x += vx * TICK;
    y += vy * TICK;
    rot += torque * ANGULAR * TICK;

    // пересечение: 9 точек повёрнутого прямоугольника (с запасом 2 px)
    float cR = cos(rot);
    float sR = sin(rot);
    bool hit = hits_point(x, y);
    for (int sx = -1; sx <= 1 && !hit; sx++) {
        for (int sy = -1; sy <= 1 && !hit; sy++) {
            if (sx == 0 && sy == 0) continue;
            float lx = float(sx) * HALF_W;
            float ly = float(sy) * HALF_H;
            hit = hits_point(x + lx * cR - ly * sR, y + lx * sR + ly * cR);
        }
    }

    // score: глубже лучше + отклонение от центра + штраф за скорость падения > 235 px/s
    float off0 = off_at(x, y);
    float off1 = off_at(x, y + 240.0);
    float score = y - off0 * off0 * 60.0 - off1 * off1 * 90.0 - abs(vx) * 0.15
                - max(0.0, vy - 235.0) * 0.22;

    uint o = gid * 8u;
    dst.children[o + 0u] = x;
    dst.children[o + 1u] = y;
    dst.children[o + 2u] = vx;
    dst.children[o + 3u] = vy;
    dst.children[o + 4u] = rot;
    dst.children[o + 5u] = hit ? 1.0 : 0.0;
    dst.children[o + 6u] = score;
    dst.children[o + 7u] = 0.0;
}
