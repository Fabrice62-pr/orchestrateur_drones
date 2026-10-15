extends SceneTree
## Calcule la direction du soleil à partir du point le plus lumineux du ciel HDRI
## et l'enregistre dans assets/sky/sun.json (lu par render/atmosphere.gd).
## godot --headless --path . -s tools/compute_sun.gd


func _initialize() -> void:
	var tex: Texture2D = load("res://assets/sky/sky.hdr")
	var img := tex.get_image()
	if img.is_compressed():
		img.decompress()
	img.resize(512, 256, Image.INTERPOLATE_BILINEAR)
	var best := -1.0
	var bu := 0.5
	var bv := 0.3
	for y in 128:
		for x in 512:
			var c := img.get_pixel(x, y)
			var l := c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
			if l > best:
				best = l
				bu = (x + 0.5) / 512.0
				bv = (y + 0.5) / 256.0
	var theta := (bu - 0.5) * TAU
	var phi := bv * PI
	var d := Vector3(sin(theta) * sin(phi), cos(phi), -cos(theta) * sin(phi)).normalized()
	var f := FileAccess.open("res://assets/sky/sun.json", FileAccess.WRITE)
	f.store_string(JSON.stringify({"direction": [d.x, d.y, d.z], "luminance": best, "elevation_deg": rad_to_deg(asin(d.y))}, "  "))
	f.close()
	print("soleil : direction ", d, " élévation %.1f°" % rad_to_deg(asin(d.y)), " luminance ", best)
	quit()
