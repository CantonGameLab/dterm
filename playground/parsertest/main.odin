// parser 单元测试:验证各命令字符串解析结果(字段正确性)。
package main

import cv "../../src/canvas"
import mem "../../src/memory"
import "core:fmt"

fails := 0

check :: proc(name : string, cond : bool) {
	status := "PASS"
	if !cond {
		status = "FAIL"
		fails += 1
	}
	fmt.printf("%-46s %s\n", name, status)
}

approx :: proc(a, b : f32) -> bool {
	d := a - b
	if d < 0 {
		d = -d
	}
	return d < 0.001
}

main :: proc() {
	// 建树(解析 @id 需要有效节点)
	cv.InitWindowTree()
	root := cv.WindowTreeRoot()
	// 分裂出节点 3
	_, right, ok := cv.TreeNodeSplit(root, .LeftRight, 0.5)
	_ = ok
	p : cv.ParsedCommand

	// split
	p, ok = cv.ParseCommandString(":split right")
	check("split right 解析", ok && p.kind == .Split && p.dir == .LeftRight)
	p, ok = cv.ParseCommandString(":split down")
	check("split down 解析", ok && p.kind == .Split && p.dir == .UpDown)

	// focus id / 方向
	p, ok = cv.ParseCommandString(":focus 3")
	check("focus id 解析", ok && p.kind == .FocusId && p.target.id == 3)
	p, ok = cv.ParseCommandString(":focus left")
	check("focus dir 解析", ok && p.kind == .FocusDir && p.fdir == .Left)
	p, ok = cv.ParseCommandString(":focus up")
	check("focus up 解析", ok && p.fdir == .Up)

	// destroy
	p, ok = cv.ParseCommandString(":destroy")
	check("destroy 解析", ok && p.kind == .Destroy)

	// factor
	p, ok = cv.ParseCommandString(":factor 0.6")
	check("factor 解析", ok && p.kind == .Factor && approx(p.fval, 0.6))
	p, ok = cv.ParseCommandString(":factor 0.35 @3")
	check("factor @id 解析", ok && approx(p.fval, 0.35) && p.target.id == 3)

	// exchange
	p, ok = cv.ParseCommandString(":exchange right")
	check("exchange 解析", ok && p.kind == .Exchange && p.fdir == .Right)

	// font(引号字符串 + 数字)
	p, ok = cv.ParseCommandString(`:font "./a.ttf" 40`)
	check("font 解析", ok && p.kind == .Font && p.sval == "./a.ttf" && approx(p.fval, 40))

	// launch(引号字符串)
	p, ok = cv.ParseCommandString(`:launch "cmd.exe"`)
	check("launch 解析", ok && p.kind == .Launch && p.sval == "cmd.exe")

	// feed
	p, ok = cv.ParseCommandString(`:feed "ls -la"`)
	check("feed 解析", ok && p.kind == .Feed && p.sval == "ls -la")

	// autoclose
	p, ok = cv.ParseCommandString(":autoclose true")
	check("autoclose true", ok && p.kind == .AutoClose && p.bval)
	p, ok = cv.ParseCommandString(":autoclose false")
	check("autoclose false", ok && !p.bval)

	// count / focus-get
	p, ok = cv.ParseCommandString(":count")
	check("count 解析", ok && p.kind == .Count)
	p, ok = cv.ParseCommandString(":focus-get")
	check("focus-get 解析", ok && p.kind == .FocusGet)

	// 错误输入
	_, ok2 := cv.ParseCommandString("")
	check("空串拒绝", !ok2)
	_, ok2 = cv.ParseCommandString("split right")
	check("无冒号拒绝", !ok2)
	_, ok2 = cv.ParseCommandString(":nonsense 1 2")
	check("未知命令拒绝", !ok2)
	_, ok2 = cv.ParseCommandString(":font")
	check("缺参数拒绝", !ok2)
	_, ok2 = cv.ParseCommandString(":factor abc")
	check("坏数字拒绝", !ok2)

	// @id 无效槽 → target 空(不报错,执行时失败)
	p, ok = cv.ParseCommandString(":destroy @999")
	check("@999 无效槽 target 空", ok && p.target.id == 0)

	fmt.printf("\n%s (%d failures)\n", fails == 0 ? "ALL PASS" : "SOME FAILED", fails)
}
