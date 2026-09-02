#version 440 core
layout(location = 0) in vec2 aPos;      // 顶点像素坐标(y 向下)
layout(location = 1) in vec4 aRect;     // 矩形 x,y,w,h(每顶点重复)
layout(location = 2) in vec4 aCorners;  // 角半径:左上,右上,右下,左下
layout(location = 3) in vec4 aColor;    // RGBA(0..1)
uniform vec2 uScreenSize;
out vec4 vRect;
out vec4 vCorners;
out vec4 vColor;
void main() {
    vRect = aRect;
    vCorners = aCorners;
    vColor = aColor;
    vec2 ndc = vec2(aPos.x / uScreenSize.x * 2.0 - 1.0, 1.0 - aPos.y / uScreenSize.y * 2.0);
    gl_Position = vec4(ndc, 0.0, 1.0);
}
