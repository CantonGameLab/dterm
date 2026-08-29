// 参考屏幕模拟器:独立于 dterm 解析器的最小 VT 渲染(只实现 claude UI 用到的
// 序列:CUP/CUU/CUD/CUF/CUB/ED/EL/CR/LF/BS/TAB/Print,宽字符按 1 格),
// 与 playground/simrender(完整管线)输出 diff → 定位解析器错位点。
// 用法:odin run playground/reftest/(仓库根,dump.bin 同目录;同样行数要求)
package main

import "core:fmt"
import "core:os"
import "core:strings"

ROWS :: 40
COLS :: 120

main :: proc() {
	data, err := os.read_entire_file_from_path("dump.bin", context.allocator)
	if err != nil {
		fmt.eprintln("no dump.bin")
		return
	}
	defer delete(data)

	grid : [ROWS][COLS]rune // 空 = 0(' ')
	fill(grid[:])
	r, c : int
	i := 0
	for i < len(data) {
		b := data[i]
		// UTF-8 多字节(合法序列,一律单格)
		if b >= 0xC2 {
			seq, n := decodeAny(data[i:])
			if n > 0 {
				grid[r][c] = seq
				c = min(c + 1, COLS - 1)
				i += n
				continue
			}
			i += 1
			continue
		}
		switch b {
		case 0x0D:
			c = 0
			i += 1
		case 0x0A:
			r = min(r + 1, ROWS - 1)
			lineFill(&grid[r], ' ')
			i += 1
		case 0x08:
			c = max(c - 1, 0)
			i += 1
		case 0x09:
			c = min((c / 8 + 1) * 8, COLS - 1)
			i += 1
		case 0x07, 0x00 ..= 0x06, 0x0B, 0x0C, 0x0E ..= 0x17, 0x19, 0x1A, 0x1C ..= 0x1F:
			i += 1
		case 0x1B:
			// ESC 序列(最小集)
			if i + 1 < len(data) && data[i + 1] == '[' {
				i += 2
				p0, p1 := 0, 0
				pn := 0
				cur := 0
				for i < len(data) {
					ch := data[i]
					if ch >= '0' && ch <= '9' {
						cur = cur * 10 + int(ch - '0')
						if pn == 0 { p0 = cur } else { p1 = cur }
						i += 1
					} else if ch == ';' || ch == ':' {
						pn += 1
						cur = 0
						i += 1
					} else if ch == '?' || ch == '>' || ch == '<' || ch == '=' {
						i += 1 // 私用标记(布局无关,跳过)
					} else {
						break
					}
				}
				if i < len(data) {
					f := data[i]
					i += 1
					// 隐藏/显示光标与 sync 模式不影响布局;SGR/keyboard 查询忽略
					switch f {
					case 'H', 'f':
						r = min(max(p0 - 1, 0), ROWS - 1)
						c = min(max(p1 - 1, 0), COLS - 1)
					case 'A': r = max(r - max(p0, 1), 0)
					case 'B': r = min(r + max(p0, 1), ROWS - 1)
					case 'C': c = min(c + max(p0, 1), COLS - 1)
					case 'D': c = max(c - max(p0, 1), 0)
					case 'G': c = min(max(p0 - 1, 0), COLS - 1)
					case 'd': r = min(max(p0 - 1, 0), ROWS - 1)
					case '`': c = min(max(p0 - 1, 0), COLS - 1)
					case 'e': r = min(r + max(p0, 1), ROWS - 1)
					case 'a': c = min(c + max(p0, 1), COLS - 1)
					case 'J':
						if p0 == 2 || p0 == 3 {
							fill(grid[:])
						} else if p0 == 1 {
							for k in 0 ..= c { grid[r][k] = ' ' }
							for k in 0 ..< r { lineFill(&grid[k], ' ') }
						} else {
							for k in c ..< COLS { grid[r][k] = ' ' }
							for k in r + 1 ..< ROWS { lineFill(&grid[k], ' ') }
						}
					case 'K':
						if p0 == 2 {
							lineFill(&grid[r], ' ')
						} else if p0 == 1 {
							for k in 0 ..= c { grid[r][k] = ' ' }
						} else {
							for k in c ..< COLS { grid[r][k] = ' ' }
						}
					case 'm': // SGR 忽略
					case 'M': // DL:删除若干行(UI 少见)
						for _ in 0 ..< max(p0, 1) {
							copy(grid[r:], grid[r + 1:])
							lineFill(&grid[ROWS - 1], ' ')
						}
					case 'L':
						for _ in 0 ..< max(p0, 1) {
							copy(grid[r + 1:], grid[r:ROWS - 1])
							lineFill(&grid[r], ' ')
						}
					case 'P', '@', 'X', 'S', 'T': // 字符/行操作少见,忽略
					}
				}
			} else if i + 1 < len(data) && data[i + 1] == ']' {
				// OSC:跳过到 BEL 或 ESC\
				i += 2
				for i < len(data) {
					if data[i] == 0x07 { i += 1; break }
					if data[i] == 0x1B && i + 1 < len(data) && data[i + 1] == '\\' { i += 2; break }
					i += 1
				}
			} else if i + 1 < len(data) {
				// ESC 单字符:D/E/M/c/7/8(7/8 光标存/取;D=下移 E=换行 M=上移)
				switch data[i + 1] {
				case 'D': r = min(r + 1, ROWS - 1)
				case 'E': r = min(r + 1, ROWS - 1); c = 0
				case 'M': r = max(r - 1, 0)
				}
				i += 2
			} else {
				i += 1
			}
		case 0x20, 0x20 ..= 0x7E:
			// 可打印:xterm 语义(满列后下一字符折行;光标允许停在行尾)
			if c >= COLS {
				c = 0
				r = min(r + 1, ROWS - 1)
			}
			grid[r][c] = rune(b)
			c += 1 // 允许 == COLS(行尾)
			i += 1
		case 0x7F:
			i += 1
		case:
			// 其余(不常见)按 1 字节打印
			if c >= COLS {
				c = 0
				r = min(r + 1, ROWS - 1)
			}
			grid[r][c] = rune(b)
			c += 1
			i += 1
		}
	}

	// 输出:空行显式 <blank>
	for ro in 0 ..< ROWS {
		sb : strings.Builder
		for cc in 0 ..< COLS {
			ch := grid[ro][cc]
			if ch == 0 { ch = ' ' }
			if ch >= 0x7F { ch = '#' }
			strings.write_rune(&sb, ch)
		}
		fmt.println(strings.to_string(sb))
	}
	fmt.println("cursor at", r, c)
}

fill :: proc(g : [][COLS]rune) {
	for i in 0 ..< len(g) {
		lineFill(&g[i], ' ')
	}
}

lineFill :: proc(line : ^[COLS]rune, ch : rune) {
	for i in 0 ..< COLS {
		line[i] = ch
	}
}

// 解析一个 UTF-8 序列(合法则返回 rune + 字节数;非法返回 0,0)
decodeAny :: proc(s : []u8) -> (rune, int) {
	b := s[0]
	n := 0
	if b < 0xE0 {
		n = 2
	} else if b < 0xF0 {
		n = 3
	} else {
		n = 4
	}
	if len(s) < n {
		return 0, 0
	}
	for j in 1 ..< n {
		if s[j] & 0xC0 != 0x80 {
			return 0, 0
		}
	}
	cp := rune(0)
	switch n {
	case 2: cp = rune(s[0] & 0x1F) << 6 | rune(s[1] & 0x3F)
	case 3: cp = rune(s[0] & 0x0F) << 12 | rune(s[1] & 0x3F) << 6 | rune(s[2] & 0x3F)
	case 4: cp = rune(s[0] & 0x07) << 18 | rune(s[1] & 0x3F) << 12 | rune(s[2] & 0x3F) << 6 | rune(s[3] & 0x3F)
	}
	return cp, n
}
