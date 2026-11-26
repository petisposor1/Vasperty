package vasperty_game

import "core:math/bits"

@(private)
CITY_K0 :: u64(0xC3A5_C85C_97CB_3127)
@(private)
CITY_K1 :: u64(0xB492_B66F_BE98_F273)
@(private)
CITY_K2 :: u64(0x9AE1_6A3B_2F90_404F)
@(private)
CITY_KMUL :: u64(0x9DDF_EA08_EB38_2D69)

@(private)
rotr64 :: #force_inline proc "contextless" (v: u64, shift: uint) -> u64 {
	s := shift & 63
	if s == 0 {
		return v
	}
	return (v >> s) | (v << (64 - s))
}

@(private)
read_city_u64 :: #force_inline proc(s: []u8, i: int) -> u64 {
	return u64(s[i]) |
		(u64(s[i + 1]) << 8) |
		(u64(s[i + 2]) << 16) |
		(u64(s[i + 3]) << 24) |
		(u64(s[i + 4]) << 32) |
		(u64(s[i + 5]) << 40) |
		(u64(s[i + 6]) << 48) |
		(u64(s[i + 7]) << 56)
}

@(private)
read_city_u32 :: #force_inline proc(s: []u8, i: int) -> u64 {
	return u64(s[i]) |
		(u64(s[i + 1]) << 8) |
		(u64(s[i + 2]) << 16) |
		(u64(s[i + 3]) << 24)
}

@(private)
smix :: #force_inline proc "contextless" (v: u64) -> u64 {
	return v ~ (v >> 47)
}

@(private)
hash_len_16 :: #force_inline proc "contextless" (u, v, mul: u64) -> u64 {
	a := smix((u ~ v) * mul)
	b := smix((v ~ a) * mul)
	return b * mul
}

@(private)
city_to16 :: proc(s: []u8) -> u64 {
	n := len(s)
	mul := CITY_K2 + u64(n) * 2
	if n >= 8 {
		a := read_city_u64(s, 0) + CITY_K2
		b := read_city_u64(s, n - 8)
		c := rotr64(b, 37) * mul + a
		d := (rotr64(a, 25) + b) * mul
		return hash_len_16(c, d, mul)
	}
	if n >= 4 {
		return hash_len_16(u64(n) + (read_city_u32(s, 0) << 3), read_city_u32(s, n - 4), mul)
	}
	if n > 0 {
		y := u64(s[0]) + (u64(s[n >> 1]) << 8)
		z := u64(n) + (u64(s[n - 1]) << 2)
		return smix((y * CITY_K2) ~ (z * CITY_K0)) * CITY_K2
	}
	return CITY_K2
}

@(private)
city_to32 :: proc(s: []u8) -> u64 {
	n := len(s)
	mul := CITY_K2 + u64(n) * 2
	a := read_city_u64(s, 0) * CITY_K1
	b := read_city_u64(s, 8)
	c := read_city_u64(s, n - 8) * mul
	d := read_city_u64(s, n - 16) * CITY_K2
	return hash_len_16(
		rotr64(a + b, 43) + rotr64(c, 30) + d,
		a + rotr64(b + CITY_K2, 18) + c,
		mul,
	)
}

@(private)
city_to64 :: proc(s: []u8) -> u64 {
	n := len(s)
	mul := CITY_K2 + u64(n) * 2
	a := read_city_u64(s, 0) * CITY_K2
	b := read_city_u64(s, 8)
	c := read_city_u64(s, n - 24)
	d := read_city_u64(s, n - 32)
	e := read_city_u64(s, 16) * CITY_K2
	f := read_city_u64(s, 24) * 9
	g := read_city_u64(s, n - 8)
	h := read_city_u64(s, n - 16) * mul
	u := rotr64(a + g, 43) + (rotr64(b, 30) + c) * 9
	v := ((a + g) ~ d) + f + 1
	w := bits.byte_swap((u + v) * mul) + h
	x := rotr64(e + f, 42) + c
	y := (bits.byte_swap((v + w) * mul) + g) * mul
	z := e + f + c
	a2 := bits.byte_swap((x + z) * mul + y) + b
	b2 := smix((z + a2) * mul + d + h) * mul
	return b2 + x
}

@(private)
weak_hash_len_32_with_seeds :: proc(s: []u8, i: int, a0, b0: u64) -> (u64, u64) {
	w := read_city_u64(s, i)
	x := read_city_u64(s, i + 8)
	y := read_city_u64(s, i + 16)
	z := read_city_u64(s, i + 24)
	a := a0 + w
	b := rotr64(b0 + a + z, 21)
	c := a
	a = a + x + y
	b = b + rotr64(a, 44)
	return a + z, b + c
}

// city64 computes CityHash64 (v1.1) identically to the console shader pack / PSO tables.
city64 :: proc(s: []u8) -> u64 {
	n := len(s)
	if n <= 16 {
		return city_to16(s)
	}
	if n <= 32 {
		return city_to32(s)
	}
	if n <= 64 {
		return city_to64(s)
	}

	x := read_city_u64(s, n - 40)
	y := read_city_u64(s, n - 16) + read_city_u64(s, n - 56)
	z := hash_len_16(read_city_u64(s, n - 48) + u64(n), read_city_u64(s, n - 24), CITY_KMUL)
	v0, v1 := weak_hash_len_32_with_seeds(s, n - 64, u64(n), z)
	w0, w1 := weak_hash_len_32_with_seeds(s, n - 32, y + CITY_K1, x)
	x = x * CITY_K1 + read_city_u64(s, 0)

	i := 0
	left := (n - 1) & ~int(63)
	for left > 0 {
		x = rotr64(x + y + v0 + read_city_u64(s, i + 8), 37) * CITY_K1
		y = rotr64(y + v1 + read_city_u64(s, i + 48), 42) * CITY_K1
		x ~= w1
		y += v0 + read_city_u64(s, i + 40)
		z = rotr64(z + w0, 33) * CITY_K1
		v0, v1 = weak_hash_len_32_with_seeds(s, i, v1 * CITY_K1, x + w0)
		w0, w1 = weak_hash_len_32_with_seeds(s, i + 32, z + w1, y + read_city_u64(s, i + 16))
		z, x = x, z
		i += 64
		left -= 64
	}

	return hash_len_16(
		hash_len_16(v0, w0, CITY_KMUL) + smix(y) * CITY_K1 + z,
		hash_len_16(v1, w1, CITY_KMUL) + x,
		CITY_KMUL,
	)
}
