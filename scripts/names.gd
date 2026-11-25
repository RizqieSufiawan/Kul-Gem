class_name Names
extends RefCounted
## Names for the village's soldiers: a given name plus a family name.

const GIVEN := [
	"Aldo", "Bram", "Cael", "Dorran", "Edda", "Fenn", "Garet", "Hale", "Ilse", "Jory",
	"Kell", "Lio", "Marta", "Nils", "Oren", "Pell", "Quill", "Rhea", "Sten", "Tamsin",
	"Ulric", "Vara", "Wil", "Yorick", "Ansel", "Brit", "Corin", "Dagny", "Elric", "Frey",
	"Gunnar", "Hester", "Ivo", "Jessa", "Karl", "Lena", "Mads", "Nora", "Osric", "Petra",
	"Rolf", "Signe", "Tobin", "Una", "Vik", "Wenna", "Arno", "Bette", "Calder", "Dain",
	"Elske", "Falk", "Greta", "Hob", "Ingrid", "Jarl", "Kasimir", "Liesl", "Merrin", "Odo",
]

const FAMILY := [
	"Holt", "Marsh", "Brook", "Thorne", "Ashby", "Fell", "Wick", "Croft", "Barrow", "Hart",
	"Rook", "Stone", "Mill", "Ford", "Hollis", "Reed", "Dunn", "Vale", "Cobb", "Fenwick",
	"Tanner", "Cooper", "Fletcher", "Smith", "Ward", "Hay", "Pike", "Lowe", "Moss", "Birch",
]


## A name not already in `used` (adds it to `used`).
static func unique(used: Dictionary) -> String:
	for attempt in 200:
		var n := "%s %s" % [GIVEN.pick_random(), FAMILY.pick_random()]
		if not used.has(n):
			used[n] = true
			return n
	var fallback := "Recruit %d" % used.size()
	used[fallback] = true
	return fallback
