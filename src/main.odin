package main

import "core:fmt"
import "vendor:raylib"

term_w: f32 = 768
term_h: f32 = 432
term_roundedness : f32 = 0.08
term_bg : raylib.Color = {0, 0, 0, 255}
term := raylib.Rectangle{256, 36, term_w, term_h}

main :: proc() {
	fmt.println("Initializing Window")
	win_width: i32 = 1280
	win_height: i32 = 720

	raylib.InitWindow(win_width, win_height, "Saw16")
	raylib.SetTargetFPS(60)
	fmt.println("Done Initializing Window")


	for raylib.WindowShouldClose() == false {
		raylib.BeginDrawing()
		raylib.ClearBackground(raylib.RAYWHITE)
		raylib.DrawRectangleRounded(term, term_roundedness, 1, term_bg)
		raylib.EndDrawing()
	}
}
