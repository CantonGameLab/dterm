#version 440 core
in vec2 vUv;
in vec4 vColor;
uniform sampler2D uTex;
out vec4 fragColor;
void main() {
    // 图集为 R8 灰度:灰度值作 alpha,颜色纯由顶点色给出
    fragColor = vec4(vColor.rgb, vColor.a * texture(uTex, vUv).r);
}
