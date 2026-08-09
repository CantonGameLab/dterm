package canvas

import ct "../conpty"
import stbtt "vendor:stb/truetype"

Term :: struct {
	layer : u16,
	//TODO: get some in their like some other stuff
}

Window :: struct {
	//And some font we will handle that
	height: f32,
	width: f32,
	position_x: f32, //居中锚点
	position_y: f32,
	terms : [dynamic]Term,
}

Interface :: struct {
	
	windows : [dynamic]Window,
}

