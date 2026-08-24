// 注册表字体名探测 v2:枚举 HKLM\...\CurrentVersion\Fonts,
// 验证"规范化(缓冲版)+ 前缀匹配 + 文件内 family 校验"逻辑(与 src/font/font.odin 同构)。
package main

import win "core:sys/windows"
import stbtt "vendor:stb/truetype"
import "core:fmt"
import "core:os"
import "core:c"
import "core:strings"

normalizeFontName :: proc(s : string, buf : []byte) -> string {
	n := 0
	end := len(s)
	if end > 0 && s[end - 1] == ')' {
		for i := end - 1; i >= 0; i -= 1 {
			if s[i] == '(' {
				end = i
				break
			}
		}
	}
	for i in 0 ..< end {
		c := s[i]
		switch c {
		case ' ', '-', '_':
			continue
		}
		if n >= len(buf) - 1 {
			break
		}
		if c >= 'a' && c <= 'z' {
			c -= 32
		}
		buf[n] = c
		n += 1
	}
	return string(buf[:n])
}

faceFamilyName :: proc(data : []byte, info : ^stbtt.fontinfo, out : []byte) -> string {
	tmp : [160]byte
	combos := [?][3]c.int{{3, 1, 0x409}, {3, 1, 0}, {1, 0, 0}}
	name_ids := [?]c.int{1, 4}
	for combo in combos {
		for name_id in name_ids {
			length : c.int
			p := stbtt.GetFontNameString(info, &length, stbtt.PLATFORM_ID(combo[0]), combo[1], combo[2], name_id)
			if p == nil || length <= 0 {
				continue
			}
			raw := (cast([^]u8)p)[:int(length)]
			m := 0
			for i := 0; i + 1 < int(length); i += 2 {
				if m >= len(tmp) {
					break
				}
				tmp[m] = raw[i + 1]
				m += 1
			}
			if m == 0 {
				continue
			}
			if r := normalizeFontName(string(tmp[:m]), out); len(r) > 0 {
				return r
			}
		}
	}
	return ""
}

SYSTEM_FONT_DIR :: "C:\\Windows\\Fonts\\"

findFont :: proc(input : string) -> (string, bool) {
	key : win.HKEY
	sub := win.utf8_to_wstring(`SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts`)
	if win.RegOpenKeyExW(win.HKEY_LOCAL_MACHINE, sub, 0, win.KEY_READ, &key) != 0 {
		return "", false
	}
	defer win.RegCloseKey(key)

	target_buf : [256]byte
	target := normalizeFontName(input, target_buf[:])
	exact_file : string
	exact_ok := false

	disp_buf : [128]u8
	d_buf : [256]byte
	name_buf : [512]u16
	data_buf : [1024]u8
	for idx : u32 = 0; ; idx += 1 {
		name_len := u32(len(name_buf))
		data_len := u32(len(data_buf))
		if win.RegEnumValueW(key, idx, &name_buf[0], &name_len, nil, nil, cast(^win.BYTE)&data_buf[0], &data_len) != 0 {
			break
		}
		disp := win.utf16_to_utf8_buf(disp_buf[:], name_buf[:name_len])
		d := normalizeFontName(disp, d_buf[:])
		is_exact := d == target
		is_pref := strings.has_prefix(d, target)
		if !is_exact && !is_pref {
			continue
		}
		n16 := int(data_len) / 2
		if n16 > 0 && data_buf[n16 * 2 - 2] == 0 && data_buf[n16 * 2 - 1] == 0 {
			n16 -= 1
		}
		ws := make([]u16, n16, context.temp_allocator)
		for i in 0 ..< n16 {
			ws[i] = u16(data_buf[i * 2]) | u16(data_buf[i * 2 + 1]) << 8
		}
		file, _ := win.utf16_to_utf8_alloc(ws, context.temp_allocator)
		full := file
		if !strings.contains(file, "\\") && !strings.contains(file, "/") {
			full = strings.concatenate({SYSTEM_FONT_DIR, file})
		}
		is_exact_str := is_exact
		if is_exact {
			exact_file = strings.clone(full)
			exact_ok = true
		}
		_ = is_exact_str
		fmt.printf("  %-40s pref=%v exact=%v -> %s", d, is_pref, is_exact, file)
		data2, err := os.read_entire_file_from_path(full, context.allocator)
		if err == nil {
			defer delete(data2, context.allocator)
			info := stbtt.fontinfo{}
			off := stbtt.GetFontOffsetForIndex(cast([^]byte)raw_data(data2), 0)
			stbtt.InitFont(&info, cast([^]byte)raw_data(data2), off)
			fam_buf : [256]byte
			fam := faceFamilyName(data2, &info, fam_buf[:])
			fmt.printf("  family=%q match=%v\n", fam, fam == target)
			if fam == target {
				p := strings.clone(full)
				fmt.printf("   before-return: %v\n", p)
				return p, true
			}
		} else {
			fmt.println("  <file missing>")
		}
	}
	if exact_ok {
		return exact_file, true
	}
	return "", false
}

main :: proc() {
	probes := []string{"FiraCode Nerd Font Mono", "FiraCodeNerdFontMono", "Consolas", "Cascadia Code", "Fira Code"}
	for probe in probes {
		fmt.printf("== probe %q ==\n", probe)
		p, ok := findFont(probe)
		fmt.printf("RESULT: %v -> %v\n", ok, p)
	}
}
