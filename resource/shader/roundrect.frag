#version 440 core
// 顶部两角内凹过渡角:形状 = 矩形 ∩ ¬W,其中 W = 两角"扇形帽"
// (以 (角内侧 r 处) 为圆心的 r 圆,限定角象限内 —— 只挖圆盘靠矩形外角
// 的那一象限,凹弧从背景线切点连到 tab 侧边切点)。
// 正半径 = 内凹;0 = 直角。
// 坐标:屏幕像素,y 向上(gl_FragCoord);vRect.y 是屏幕系的矩形上边。
in vec4 vRect;
in vec4 vCorners;
in vec4 vColor;
uniform vec2 uScreenSize;
out vec4 fragColor;

void main() {
    vec2 center = vec2(vRect.x + vRect.z * 0.5, uScreenSize.y - vRect.y - vRect.w * 0.5);
    vec2 p = gl_FragCoord.xy - center;
    vec2 b = vRect.zw * 0.5;

    // 矩形 SDF
    vec2 q = abs(p) - b;
    float d_box = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);

    float r = max(vCorners.x, vCorners.y);
    // 防御:内凹半径不得超过短边 90%(过大会挖出整块半圆畸形)
    r = min(r, min(b.x, b.y) * 0.9);
    float d = d_box;
    if (r > 0.0) {
        // 左上帽:圆心 (-b.x + r, b.y - r);挖"x < cx 且 y > cy 的圆盘"
        // (朝矩形外角那一侧):凹弧从顶边切点连到左边切点
        vec2 c1 = vec2(-b.x + r, b.y - r);
        float w1 = max(length(p - c1) - r, max(p.x - c1.x, c1.y - p.y));
        // 右上帽:圆心 (b.x - r, b.y - r);挖"x > cx 且 y > cy 的圆盘"
        vec2 c2 = vec2(b.x - r, b.y - r);
        float w2 = max(length(p - c2) - r, max(c2.x - p.x, c2.y - p.y));
        float d_w = min(w1, w2);
        d = max(d_box, -d_w); // 矩形挖去两角帽 = 内凹过渡
    }

    float alpha = 1.0 - smoothstep(-1.2, 1.2, d);
    fragColor = vec4(vColor.rgb, vColor.a * alpha);
}
