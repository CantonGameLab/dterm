// 命令层回归:bind/unbind/bindings 字符串命令 + 缺补的动作命令解析。
package main

import cv "../../src/canvas"
import inp "../../src/input"
import "core:fmt"

lines : [64]string
line_count : int

collect :: proc(msg : string) {
	if line_count < len(lines) {
		lines[line_count] = msg
		line_count += 1
	}
}

check :: proc(name : string, got, want : $T) {
	if got == want {
		fmt.printf("  ok  %s\n", name)
	} else {
		fmt.printf("FAIL  %s got=%v want=%v\n", name, got, want)
	}
}

main :: proc() {
	// bind:解析 → 执行 → 查询命中
	pc, ok := cv.ParseCommandString("bind alt+shift+l \"split right\"")
	check("bind parse ok", ok, true)
	check("bind kind", pc.kind, cv.CommandStringKind.SetBinding)
	check("sub handle", pc.sub.id != 0, true)
	fmt.printf("  .. sc=%d mods=%v sub=%d\n", pc.sc, pc.mods, pc.sub.id)
	ok = cv.ExecuteCommandString("bind alt+shift+l \"split right\"")
	check("bind exec", ok, true)
	b, found := cv.GetKeyBinding(inp.Scancode(pc.sc), pc.mods)
	check("bind hit", found, true)
	check("bind cmd kind", b.cmd.kind, cv.CommandStringKind.Split)
	check("bind cmd dir", b.cmd.dir, cv.SplitType.LeftRight)

	// 大小写不敏感 + 无修饰
	ok = cv.ExecuteCommandString("bind F2 \"toggle-commandbar\"")
	check("bind f2 exec", ok, true)
	_, found = cv.GetKeyBinding(.F2, {})
	check("f2 hit", found, true)

	// 覆盖:同 key+mods 换命令
	ok = cv.ExecuteCommandString("bind alt+shift+l \"split down\"")
	check("bind overwrite", ok, true)
	b, _ = cv.GetKeyBinding(inp.Scancode(pc.sc), pc.mods)
	check("overwrite dir", b.cmd.dir, cv.SplitType.UpDown)

	// unbind
	ok = cv.ExecuteCommandString("unbind alt+shift+l")
	check("unbind exec", ok, true)
	_, found = cv.GetKeyBinding(inp.Scancode(pc.sc), pc.mods)
	check("unbind gone", found, false)
	ok = cv.ExecuteCommandString("unbind alt+shift+l")
	check("unbind twice fail", ok, false)

	// bindings 输出
	cv.ExecuteCommandString("bindings", collect)
	check("bindings count>0", line_count > 0, true)
	fmt.printf("  .. %s\n", lines[0])

	// 补缺动作命令解析
	pc, ok = cv.ParseCommandString("fontsizeup")
	check("fontsizeup", ok && pc.kind == .FontSizeUp, true)
	pc, ok = cv.ParseCommandString("fontsizedown")
	check("fontsizedown", ok && pc.kind == .FontSizeDown, true)
	pc, ok = cv.ParseCommandString("reviewup")
	check("reviewup", ok && pc.kind == .ReviewUp, true)
	pc, ok = cv.ParseCommandString("reviewdown")
	check("reviewdown", ok && pc.kind == .ReviewDown, true)
	pc, ok = cv.ParseCommandString("toggle-commandbar")
	check("toggle-commandbar", ok && pc.kind == .ToggleCommandBar, true)

	// 非法组合
	_, ok = cv.ParseCommandString("bind bogus+key \"split right\"")
	check("bad mods", ok, false)
	_, ok = cv.ParseCommandString("bind alt+shift+ \"x\"")
	check("empty key", ok, false)
	_, ok = cv.ParseCommandString("bind alt+f2 \"bind ctrl+f3 \\\"destroy\\\"\"")
	check("nested bind rejected", ok, false)
}
