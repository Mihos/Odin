//+ignore
package big

/*
	Copyright 2021 Jeroen van Rijn <nom@duclavier.com>.
	Made available under Odin's BSD-2 license.

	A BigInt implementation in Odin.
	For the theoretical underpinnings, see Knuth's The Art of Computer Programming, Volume 2, section 4.3.
	The code started out as an idiomatic source port of libTomMath, which is in the public domain, with thanks.

	==========================    Low-level routines    ==========================

	IMPORTANT: `internal_*` procedures make certain assumptions about their input.

	The public functions that call them are expected to satisfy their sanity check requirements.
	This allows `internal_*` call `internal_*` without paying this overhead multiple times.

	Where errors can occur, they are of course still checked and returned as appropriate.

	When importing `math:core/big` to implement an involved algorithm of your own, you are welcome
	to use these procedures instead of their public counterparts.

	Most inputs and outputs are expected to be passed an initialized `Int`, for example.
	Exceptions include `quotient` and `remainder`, which are allowed to be `nil` when the calling code doesn't need them.

	Check the comments above each `internal_*` implementation to see what constraints it expects to have met.
*/

import "core:mem"

/*
	Low-level addition, unsigned. Handbook of Applied Cryptography, algorithm 14.7.

	Assumptions:
		`dest`, `a` and `b` != `nil` and have been initalized.
*/
internal_int_add_unsigned :: proc(dest, a, b: ^Int, allocator := context.allocator) -> (err: Error) {
	dest := dest; x := a; y := b;

	old_used, min_used, max_used, i: int;

	if x.used < y.used {
		x, y = y, x;
		assert(x.used >= y.used);
	}

	min_used = y.used;
	max_used = x.used;
	old_used = dest.used;

	if err = grow(dest, max(max_used + 1, _DEFAULT_DIGIT_COUNT), false, allocator); err != nil { return err; }
	dest.used = max_used + 1;
	/*
		All parameters have been initialized.
	*/

	/* Zero the carry */
	carry := DIGIT(0);

	#no_bounds_check for i = 0; i < min_used; i += 1 {
		/*
			Compute the sum one _DIGIT at a time.
			dest[i] = a[i] + b[i] + carry;
		*/
		dest.digit[i] = x.digit[i] + y.digit[i] + carry;

		/*
			Compute carry
		*/
		carry = dest.digit[i] >> _DIGIT_BITS;
		/*
			Mask away carry from result digit.
		*/
		dest.digit[i] &= _MASK;
	}

	if min_used != max_used {
		/*
			Now copy higher words, if any, in A+B.
			If A or B has more digits, add those in.
		*/
		#no_bounds_check for ; i < max_used; i += 1 {
			dest.digit[i] = x.digit[i] + carry;
			/*
				Compute carry
			*/
			carry = dest.digit[i] >> _DIGIT_BITS;
			/*
				Mask away carry from result digit.
			*/
			dest.digit[i] &= _MASK;
		}
	}
	/*
		Add remaining carry.
	*/
	dest.digit[i] = carry;
	zero_count := old_used - dest.used;
	/*
		Zero remainder.
	*/
	if zero_count > 0 {
		mem.zero_slice(dest.digit[dest.used:][:zero_count]);
	}
	/*
		Adjust dest.used based on leading zeroes.
	*/
	return clamp(dest);
}

/*
	Low-level addition, signed. Handbook of Applied Cryptography, algorithm 14.7.

	Assumptions:
		`dest`, `a` and `b` != `nil` and have been initalized.
*/
internal_int_add_signed :: proc(dest, a, b: ^Int, allocator := context.allocator) -> (err: Error) {
	x := a; y := b;
	/*
		Handle both negative or both positive.
	*/
	if x.sign == y.sign {
		dest.sign = x.sign;
		return #force_inline internal_int_add_unsigned(dest, x, y, allocator);
	}

	/*
		One positive, the other negative.
		Subtract the one with the greater magnitude from the other.
		The result gets the sign of the one with the greater magnitude.
	*/
	if c, _ := #force_inline cmp_mag(a, b); c == -1 {
		x, y = y, x;
	}

	dest.sign = x.sign;
	return #force_inline internal_int_sub_unsigned(dest, x, y, allocator);
}

/*
	Low-level addition Int+DIGIT, signed. Handbook of Applied Cryptography, algorithm 14.7.

	Assumptions:
		`dest` and `a` != `nil` and have been initalized.
		`dest` is large enough (a.used + 1) to fit result.
*/
internal_int_add_digit :: proc(dest, a: ^Int, digit: DIGIT) -> (err: Error) {
	/*
		Fast paths for destination and input Int being the same.
	*/
	if dest == a {
		/*
			Fast path for dest.digit[0] + digit fits in dest.digit[0] without overflow.
		*/
		if dest.sign == .Zero_or_Positive && (dest.digit[0] + digit < _DIGIT_MAX) {
			dest.digit[0] += digit;
			dest.used += 1;
			return clamp(dest);
		}
		/*
			Can be subtracted from dest.digit[0] without underflow.
		*/
		if a.sign == .Negative && (dest.digit[0] > digit) {
			dest.digit[0] -= digit;
			dest.used += 1;
			return clamp(dest);
		}
	}

	/*
		If `a` is negative and `|a|` >= `digit`, call `dest = |a| - digit`
	*/
	if a.sign == .Negative && (a.used > 1 || a.digit[0] >= digit) {
		/*
			Temporarily fix `a`'s sign.
		*/
		a.sign = .Zero_or_Positive;
		/*
			dest = |a| - digit
		*/
		if err =  #force_inline internal_int_add_digit(dest, a, digit); err != nil {
			/*
				Restore a's sign.
			*/
			a.sign = .Negative;
			return err;
		}
		/*
			Restore sign and set `dest` sign.
		*/
		a.sign    = .Negative;
		dest.sign = .Negative;

		return clamp(dest);
	}

	/*
		Remember the currently used number of digits in `dest`.
	*/
	old_used := dest.used;

	/*
		If `a` is positive
	*/
	if a.sign == .Zero_or_Positive {
		/*
			Add digits, use `carry`.
		*/
		i: int;
		carry := digit;
		#no_bounds_check for i = 0; i < a.used; i += 1 {
			dest.digit[i] = a.digit[i] + carry;
			carry = dest.digit[i] >> _DIGIT_BITS;
			dest.digit[i] &= _MASK;
		}
		/*
			Set final carry.
		*/
		dest.digit[i] = carry;
		/*
			Set `dest` size.
		*/
		dest.used = a.used + 1;
	} else {
		/*
			`a` was negative and |a| < digit.
		*/
		dest.used = 1;
		/*
			The result is a single DIGIT.
		*/
		dest.digit[0] = digit - a.digit[0] if a.used == 1 else digit;
	}
	/*
		Sign is always positive.
	*/
	dest.sign = .Zero_or_Positive;

	zero_count := old_used - dest.used;
	/*
		Zero remainder.
	*/
	if zero_count > 0 {
		mem.zero_slice(dest.digit[dest.used:][:zero_count]);
	}
	/*
		Adjust dest.used based on leading zeroes.
	*/
	return clamp(dest);	
}

internal_add :: proc { internal_int_add_signed, internal_int_add_digit, };

/*
	Low-level subtraction, dest = number - decrease. Assumes |number| > |decrease|.
	Handbook of Applied Cryptography, algorithm 14.9.

	Assumptions:
		`dest`, `number` and `decrease` != `nil` and have been initalized.
*/
internal_int_sub_unsigned :: proc(dest, number, decrease: ^Int, allocator := context.allocator) -> (err: Error) {
	dest := dest; x := number; y := decrease;
	old_used := dest.used;
	min_used := y.used;
	max_used := x.used;
	i: int;

	if err = grow(dest, max(max_used, _DEFAULT_DIGIT_COUNT), false, allocator); err != nil { return err; }
	dest.used = max_used;
	/*
		All parameters have been initialized.
	*/

	borrow := DIGIT(0);

	#no_bounds_check for i = 0; i < min_used; i += 1 {
		dest.digit[i] = (x.digit[i] - y.digit[i] - borrow);
		/*
			borrow = carry bit of dest[i]
			Note this saves performing an AND operation since if a carry does occur,
			it will propagate all the way to the MSB.
			As a result a single shift is enough to get the carry.
		*/
		borrow = dest.digit[i] >> ((size_of(DIGIT) * 8) - 1);
		/*
			Clear borrow from dest[i].
		*/
		dest.digit[i] &= _MASK;
	}

	/*
		Now copy higher words if any, e.g. if A has more digits than B
	*/
	#no_bounds_check for ; i < max_used; i += 1 {
		dest.digit[i] = x.digit[i] - borrow;
		/*
			borrow = carry bit of dest[i]
			Note this saves performing an AND operation since if a carry does occur,
			it will propagate all the way to the MSB.
			As a result a single shift is enough to get the carry.
		*/
		borrow = dest.digit[i] >> ((size_of(DIGIT) * 8) - 1);
		/*
			Clear borrow from dest[i].
		*/
		dest.digit[i] &= _MASK;
	}

	zero_count := old_used - dest.used;
	/*
		Zero remainder.
	*/
	if zero_count > 0 {
		mem.zero_slice(dest.digit[dest.used:][:zero_count]);
	}
	/*
		Adjust dest.used based on leading zeroes.
	*/
	return clamp(dest);
}

/*
	Low-level subtraction, signed. Handbook of Applied Cryptography, algorithm 14.9.
	dest = number - decrease. Assumes |number| > |decrease|.

	Assumptions:
		`dest`, `number` and `decrease` != `nil` and have been initalized.
*/
internal_int_sub_signed :: proc(dest, number, decrease: ^Int, allocator := context.allocator) -> (err: Error) {
	number := number; decrease := decrease;
	if number.sign != decrease.sign {
		/*
			Subtract a negative from a positive, OR subtract a positive from a negative.
			In either case, ADD their magnitudes and use the sign of the first number.
		*/
		dest.sign = number.sign;
		return #force_inline internal_int_add_unsigned(dest, number, decrease, allocator);
	}

	/*
		Subtract a positive from a positive, OR negative from a negative.
		First, take the difference between their magnitudes, then...
	*/
	if c, _ := #force_inline cmp_mag(number, decrease); c == -1 {
		/*
			The second has a larger magnitude.
			The result has the *opposite* sign from the first number.
		*/
		dest.sign = .Negative if number.sign == .Zero_or_Positive else .Zero_or_Positive;
		number, decrease = decrease, number;
	} else {
		/*
			The first has a larger or equal magnitude.
			Copy the sign from the first.
		*/
		dest.sign = number.sign;
	}
	return #force_inline internal_int_sub_unsigned(dest, number, decrease, allocator);
}

/*
	Low-level subtraction, signed. Handbook of Applied Cryptography, algorithm 14.9.
	dest = number - decrease. Assumes |number| > |decrease|.

	Assumptions:
		`dest`, `number` != `nil` and have been initalized.
		`dest` is large enough (number.used + 1) to fit result.
*/
internal_int_sub_digit :: proc(dest, number: ^Int, digit: DIGIT) -> (err: Error) {
	dest := dest; digit := digit;
	/*
		All parameters have been initialized.

		Fast paths for destination and input Int being the same.
	*/
	if dest == number {
		/*
			Fast path for `dest` is negative and unsigned addition doesn't overflow the lowest digit.
		*/
		if dest.sign == .Negative && (dest.digit[0] + digit < _DIGIT_MAX) {
			dest.digit[0] += digit;
			return nil;
		}
		/*
			Can be subtracted from dest.digit[0] without underflow.
		*/
		if number.sign == .Zero_or_Positive && (dest.digit[0] > digit) {
			dest.digit[0] -= digit;
			return nil;
		}
	}

	/*
		If `a` is negative, just do an unsigned addition (with fudged signs).
	*/
	if number.sign == .Negative {
		t := number;
		t.sign = .Zero_or_Positive;

		err =  #force_inline internal_int_add_digit(dest, t, digit);
		dest.sign = .Negative;

		clamp(dest);
		return err;
	}

	old_used := dest.used;

	/*
		if `a`<= digit, simply fix the single digit.
	*/
	if number.used == 1 && (number.digit[0] <= digit) || number.used == 0 {
		dest.digit[0] = digit - number.digit[0] if number.used == 1 else digit;
		dest.sign = .Negative;
		dest.used = 1;
	} else {
		dest.sign = .Zero_or_Positive;
		dest.used = number.used;

		/*
			Subtract with carry.
		*/
		carry := digit;

		#no_bounds_check for i := 0; i < number.used; i += 1 {
			dest.digit[i] = number.digit[i] - carry;
			carry := dest.digit[i] >> (_DIGIT_TYPE_BITS - 1);
			dest.digit[i] &= _MASK;
		}
	}

	zero_count := old_used - dest.used;
	/*
		Zero remainder.
	*/
	if zero_count > 0 {
		mem.zero_slice(dest.digit[dest.used:][:zero_count]);
	}
	/*
		Adjust dest.used based on leading zeroes.
	*/
	return clamp(dest);
}

internal_sub :: proc { internal_int_sub_signed, internal_int_sub_digit, };

/*
	dest = src  / 2
	dest = src >> 1
*/
internal_int_shr1 :: proc(dest, src: ^Int) -> (err: Error) {
	old_used  := dest.used; dest.used = src.used;
	/*
		Carry
	*/
	fwd_carry := DIGIT(0);

	#no_bounds_check for x := dest.used - 1; x >= 0; x -= 1 {
		/*
			Get the carry for the next iteration.
		*/
		src_digit := src.digit[x];
		carry     := src_digit & 1;
		/*
			Shift the current digit, add in carry and store.
		*/
		dest.digit[x] = (src_digit >> 1) | (fwd_carry << (_DIGIT_BITS - 1));
		/*
			Forward carry to next iteration.
		*/
		fwd_carry = carry;
	}

	zero_count := old_used - dest.used;
	/*
		Zero remainder.
	*/
	if zero_count > 0 {
		mem.zero_slice(dest.digit[dest.used:][:zero_count]);
	}
	/*
		Adjust dest.used based on leading zeroes.
	*/
	dest.sign = src.sign;
	return clamp(dest);	
}

/*
	dest = src  * 2
	dest = src << 1
*/
internal_int_shl1 :: proc(dest, src: ^Int) -> (err: Error) {
	old_used  := dest.used; dest.used  = src.used + 1;

	/*
		Forward carry
	*/
	carry := DIGIT(0);
	#no_bounds_check for x := 0; x < src.used; x += 1 {
		/*
			Get what will be the *next* carry bit from the MSB of the current digit.
		*/
		src_digit := src.digit[x];
		fwd_carry := src_digit >> (_DIGIT_BITS - 1);

		/*
			Now shift up this digit, add in the carry [from the previous]
		*/
		dest.digit[x] = (src_digit << 1 | carry) & _MASK;

		/*
			Update carry
		*/
		carry = fwd_carry;
	}
	/*
		New leading digit?
	*/
	if carry != 0 {
		/*
			Add a MSB which is always 1 at this point.
		*/
		dest.digit[dest.used] = 1;
	}
	zero_count := old_used - dest.used;
	/*
		Zero remainder.
	*/
	if zero_count > 0 {
		mem.zero_slice(dest.digit[dest.used:][:zero_count]);
	}
	/*
		Adjust dest.used based on leading zeroes.
	*/
	dest.sign = src.sign;
	return clamp(dest);
}

/*
	Multiply by a DIGIT.
*/
internal_int_mul_digit :: proc(dest, src: ^Int, multiplier: DIGIT, allocator := context.allocator) -> (err: Error) {
	if multiplier == 0 {
		return zero(dest);
	}
	if multiplier == 1 {
		return copy(dest, src);
	}

	/*
		Power of two?
	*/
	if multiplier == 2 {
		return #force_inline shl1(dest, src);
	}
	if is_power_of_two(int(multiplier)) {
		ix: int;
		if ix, err = log(multiplier, 2); err != nil { return err; }
		return shl(dest, src, ix);
	}

	/*
		Ensure `dest` is big enough to hold `src` * `multiplier`.
	*/
	if err = grow(dest, max(src.used + 1, _DEFAULT_DIGIT_COUNT), false, allocator); err != nil { return err; }

	/*
		Save the original used count.
	*/
	old_used := dest.used;
	/*
		Set the sign.
	*/
	dest.sign = src.sign;
	/*
		Set up carry.
	*/
	carry := _WORD(0);
	/*
		Compute columns.
	*/
	ix := 0;
	#no_bounds_check for ; ix < src.used; ix += 1 {
		/*
			Compute product and carry sum for this term
		*/
		product := carry + _WORD(src.digit[ix]) * _WORD(multiplier);
		/*
			Mask off higher bits to get a single DIGIT.
		*/
		dest.digit[ix] = DIGIT(product & _WORD(_MASK));
		/*
			Send carry into next iteration
		*/
		carry = product >> _DIGIT_BITS;
	}

	/*
		Store final carry [if any] and increment used.
	*/
	dest.digit[ix] = DIGIT(carry);
	dest.used = src.used + 1;
	/*
		Zero unused digits.
	*/
	zero_count := old_used - dest.used;
	if zero_count > 0 {
		mem.zero_slice(dest.digit[zero_count:]);
	}
	return clamp(dest);
}

/*
	High level multiplication (handles sign).
*/
internal_int_mul :: proc(dest, src, multiplier: ^Int, allocator := context.allocator) -> (err: Error) {
	/*
		Early out for `multiplier` is zero; Set `dest` to zero.
	*/
	if multiplier.used == 0 || src.used == 0 { return zero(dest); }

	if src == multiplier {
		/*
			Do we need to square?
		*/
		if        false && src.used >= _SQR_TOOM_CUTOFF {
			/* Use Toom-Cook? */
			// err = s_mp_sqr_toom(a, c);
		} else if false && src.used >= _SQR_KARATSUBA_CUTOFF {
			/* Karatsuba? */
			// err = s_mp_sqr_karatsuba(a, c);
		} else if false && ((src.used * 2) + 1) < _WARRAY &&
		                   src.used < (_MAX_COMBA / 2) {
			/* Fast comba? */
			// err = s_mp_sqr_comba(a, c);
		} else {
			err = _int_sqr(dest, src);
		}
	} else {
		/*
			Can we use the balance method? Check sizes.
			* The smaller one needs to be larger than the Karatsuba cut-off.
			* The bigger one needs to be at least about one `_MUL_KARATSUBA_CUTOFF` bigger
			* to make some sense, but it depends on architecture, OS, position of the
			* stars... so YMMV.
			* Using it to cut the input into slices small enough for _mul_comba
			* was actually slower on the author's machine, but YMMV.
		*/

		min_used := min(src.used, multiplier.used);
		max_used := max(src.used, multiplier.used);
		digits   := src.used + multiplier.used + 1;

		if        false &&  min_used     >= _MUL_KARATSUBA_CUTOFF &&
						    max_used / 2 >= _MUL_KARATSUBA_CUTOFF &&
			/*
				Not much effect was observed below a ratio of 1:2, but again: YMMV.
			*/
							max_used     >= 2 * min_used {
			// err = s_mp_mul_balance(a,b,c);
		} else if false && min_used >= _MUL_TOOM_CUTOFF {
			// err = s_mp_mul_toom(a, b, c);
		} else if false && min_used >= _MUL_KARATSUBA_CUTOFF {
			// err = s_mp_mul_karatsuba(a, b, c);
		} else if digits < _WARRAY && min_used <= _MAX_COMBA {
			/*
				Can we use the fast multiplier?
				* The fast multiplier can be used if the output will
				* have less than MP_WARRAY digits and the number of
				* digits won't affect carry propagation
			*/
			err = _int_mul_comba(dest, src, multiplier, digits);
		} else {
			err = _int_mul(dest, src, multiplier, digits);
		}
	}
	neg      := src.sign != multiplier.sign;
	dest.sign = .Negative if dest.used > 0 && neg else .Zero_or_Positive;
	return err;
}

internal_mul :: proc { internal_int_mul, internal_int_mul_digit, };