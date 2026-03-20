#!/usr/bin/env python3
"""
Simple brute-force RNG analysis tool.
"""

WORD_BITS = 32
MASK = (1 << WORD_BITS) - 1
SAMPLE_SEEDS = [0, 1, 12345]
ROUNDS = 5
ANALYSIS_SAMPLES = 8192  # 131072
ANALYSIS_ROUNDS = 32


def uword(x):
    return x & MASK


def bit_count_word(x):
    return (x & MASK).bit_count()


def analyze_generator_strong(name, init, step, sample_count=ANALYSIS_SAMPLES, rounds=ANALYSIS_ROUNDS):
    counts = [0] * WORD_BITS
    low8 = [0] * 256
    low16 = {}
    pair16 = {}
    bit_flip_counts = [0] * WORD_BITS
    bit_prev = None
    xor_adj_total = 0
    prev_out = None
    repeats = 0
    seen = set()
    total = 0

    for seed in range(sample_count):
        st = init(seed)
        for _ in range(rounds):
            st, out = step(*st)
            out = uword(out)
            for b in range(WORD_BITS):
                counts[b] += (out >> b) & 1
            low8[out & 0xFF] += 1
            low16_val = out & 0xFFFF
            low16[low16_val] = low16.get(low16_val, 0) + 1

            pair16_val = ((out >> 8) ^ out) & 0xFFFF
            pair16[pair16_val] = pair16.get(pair16_val, 0) + 1

            if bit_prev is not None:
                delta = bit_prev ^ out
                for b in range(WORD_BITS):
                    bit_flip_counts[b] += (delta >> b) & 1
            bit_prev = out

            if prev_out is not None:
                xor_adj_total += bit_count_word(out ^ prev_out)
            if out in seen:
                repeats += 1
            else:
                seen.add(out)
            prev_out = out
            total += 1

    expected = total / 2.0
    max_bit_bias = max(abs(c - expected) for c in counts) / total

    expected_bucket8 = total / 256.0
    max_low8_dev = max(abs(c - expected_bucket8) for c in low8) / expected_bucket8

    expected_bucket16 = total / 65536.0
    max_low16_dev = 0.0
    if low16:
        max_low16_dev = max(abs(c - expected_bucket16) for c in low16.values()) / expected_bucket16

    max_pair16_dev = 0.0
    if pair16:
        max_pair16_dev = max(abs(c - expected_bucket16) for c in pair16.values()) / expected_bucket16

    expected_flips = (total - 1) / 2.0 if total > 1 else 0.0
    max_bit_flip_bias = 0.0
    if total > 1:
        max_bit_flip_bias = max(abs(c - expected_flips) for c in bit_flip_counts) / (total - 1)

    avg_adj_xor_hamming = xor_adj_total / (total - 1) if total > 1 else 0.0
    repeat_rate = repeats / total if total > 0 else 0.0

    print(f"{name} strong analysis")
    print(f"  samples={sample_count}, rounds_per_seed={rounds}, total_outputs={total}")
    print(f"  max_bit_bias={max_bit_bias:.6f}")
    print(f"  avg_adjacent_xor_hamming={avg_adj_xor_hamming:.3f}")
    print(f"  max_low8_bucket_deviation={max_low8_dev:.6f}")
    print(f"  max_low16_bucket_deviation={max_low16_dev:.6f}")
    print(f"  max_pair16_bucket_deviation={max_pair16_dev:.6f}")
    print(f"  max_bit_flip_bias={max_bit_flip_bias:.6f}")
    print(f"  repeat_rate={repeat_rate:.6f}")
    print()


def analyze_generator_longrun(name, init, step, seed=12345, rounds=200000):
    seen = {}
    repeats = 0
    xor_adj_total = 0
    prev_out = None
    first_repeat = None
    st = init(seed)

    for i in range(rounds):
        st, out = step(*st)
        out = uword(out)
        if prev_out is not None:
            xor_adj_total += bit_count_word(out ^ prev_out)
        if out in seen:
            repeats += 1
            if first_repeat is None:
                first_repeat = (seen[out], i, out)
        else:
            seen[out] = i
        prev_out = out

    avg_adj_xor_hamming = xor_adj_total / (rounds - 1) if rounds > 1 else 0.0

    print(f"{name} long-run analysis")
    print(f"  seed={seed}, rounds={rounds}")
    print(f"  unique_outputs={len(seen)}")
    print(f"  repeats={repeats}")
    print(f"  avg_adjacent_xor_hamming={avg_adj_xor_hamming:.3f}")
    if first_repeat is None:
        print("  first_repeat=None")
    else:
        a, b, out = first_repeat
        print(f"  first_repeat=({a}, {b}, {out})")
    print()


# Helper for running generator rounds for a seed.
def run_generator_rounds(init, step, seed, rounds):
    st = init(seed)
    outs = []
    for _ in range(rounds):
        st, out = step(*st)
        outs.append(out)
    return outs


def print_generator_samples(name, init, step, seeds=SAMPLE_SEEDS, rounds=ROUNDS):
    print(name)
    for seed in seeds:
        print(seed, run_generator_rounds(init, step, seed, rounds))
    print()


def initG8(seed):
    x = uword(seed + 19)
    y = uword(3 * seed - 5)
    w = uword(-7 * seed + 11)
    return x, y, w


def stepG8(x, y, w):
    w = uword(w + 19)
    x = uword(x * x + 3 * y - 5 * w)
    y = uword(y * y + x * x - 7 * x + 11 * w)
    w = uword(w * w - 13 * x + 17 * y)
    out = uword(x * x - 19 * y + 31 * w)
    return (x, y, w), out


GENERATORS = [
    ("G8_quadratic_output", initG8, stepG8),
]

# Tape layout:
#   0 = seed/out  (input seed during init, output after init)
#   1 = x
#   2 = tx   (next x)
#   3 = xsq  (cached updated x^2 for the round)
#   4 = y
#   5 = ty   (next y)
#   6 = w
#   7 = tw   (next w)
#   8 = r    (restore scratch)
#   9 = a    (square/mul scratch)
#  10 = b    (square/mul scratch)
#  11 = tmp  (square/mul scratch)

BF_CELLS = {
    "seed": 0,
    "out": 0,
    "x": 1,
    "tx": 2,
    "xsq": 3,
    "y": 4,
    "ty": 5,
    "w": 6,
    "tw": 7,
    "r": 8,
    "a": 9,
    "b": 10,
    "tmp": 11,
}


class BFEmitter:
    def __init__(self, cells):
        self.cells = cells
        self.ptr = 0
        self.code = []

    def reset(self):
        self.ptr = 0
        self.code = []

    def square_destroy_into_zero(self, src, dst):
        a = self.cells["a"]
        b = self.cells["b"]
        tmp = self.cells["tmp"]

        self.clear(b)

        self.mv(src)
        self.code.append("[")
        self.code.append("-")
        self._emit_move_between(src, a)
        self.code.append("+")
        self._emit_move_between(a, b)
        self.code.append("+")
        self._emit_move_between(b, src)
        self.code.append("]")
        self.ptr = src

        self._mul_from_ab_into_dst(a, b, dst, tmp)

    def move_value_into_zero(self, src, dst):
        self._move_body(src, dst, clear_dst=False)

    def accumulate_into(self, dst, terms):
        for src, coeff in terms:
            self.preserve_add_scaled(src, dst, coeff, self.cells["r"])

    def square_add_move_back(self, src, tmp_dst, terms):
        self.square_destroy_into_zero(src, tmp_dst)
        self.accumulate_into(tmp_dst, terms)
        self.move_value_into_zero(tmp_dst, src)

    def preserve_add_scaled(self, src, dst, coeff, scratch=None):
        if scratch is None:
            scratch = self.cells["r"]
        self.mv(src)
        self.code.append("[")
        self.code.append("-")
        self._emit_move_between(src, dst)
        if coeff >= 0:
            self.code.append("+" * coeff)
        else:
            self.code.append("-" * (-coeff))
        self._emit_move_between(dst, scratch)
        self.code.append("+")
        self._emit_move_between(scratch, src)
        self.code.append("]")

        self.mv(scratch)
        self.code.append("[")
        self.code.append("-")
        self._emit_move_between(scratch, src)
        self.code.append("+")
        self._emit_move_between(src, scratch)
        self.code.append("]")
        self.ptr = scratch

    def _emit_relative_move(self, delta):
        if delta > 0:
            self.code.append(">" * delta)
        elif delta < 0:
            self.code.append("<" * (-delta))

    def _emit_move_between(self, src, dst):
        self._emit_relative_move(dst - src)

    def mv(self, to):
        self._emit_relative_move(to - self.ptr)
        self.ptr = to

    def clear(self, cell):
        self.mv(cell)
        self.code.append("[-]")

    def clear_many(self, *cells):
        for cell in cells:
            self.clear(cell)

    def add_const(self, cell, k):
        self.mv(cell)
        if k >= 0:
            self.code.append("+" * k)
        else:
            self.code.append("-" * (-k))

    def distribute_destroy(self, src, targets):
        self.mv(src)
        self.code.append("[")
        self.code.append("-")
        pos = src
        for dst, coeff in targets:
            self._emit_move_between(pos, dst)
            pos = dst
            if coeff >= 0:
                self.code.append("+" * coeff)
            else:
                self.code.append("-" * (-coeff))
        self._emit_move_between(pos, src)
        self.code.append("]")
        self.ptr = src

    def distribute_preserve(self, src, targets, scratch):
        self.mv(src)
        self.code.append("[")
        self.code.append("-")
        pos = src
        for dst, coeff in [*targets, (scratch, 1)]:
            self._emit_move_between(pos, dst)
            pos = dst
            if coeff >= 0:
                self.code.append("+" * coeff)
            else:
                self.code.append("-" * (-coeff))
        self._emit_move_between(pos, src)
        self.code.append("]")

        self.mv(scratch)
        self.code.append("[")
        self.code.append("-")
        self._emit_move_between(scratch, src)
        self.code.append("+")
        self._emit_move_between(src, scratch)
        self.code.append("]")
        self.ptr = scratch

    def _move_body(self, src, dst, clear_dst):
        if clear_dst:
            self.clear(dst)
        self.mv(src)
        self.code.append("[")
        self.code.append("-")
        self._emit_move_between(src, dst)
        self.code.append("+")
        self._emit_move_between(dst, src)
        self.code.append("]")
        self.ptr = src

    def _mul_from_ab_into_dst(self, a, b, dst, tmp):
        pos = self.ptr

        def move_to(dest):
            nonlocal pos
            self._emit_move_between(pos, dest)
            pos = dest

        move_to(a)
        self.code.append("[")
        self.code.append("-")

        move_to(b)
        self.code.append("[")
        self.code.append("-")
        move_to(dst)
        self.code.append("+")
        move_to(tmp)
        self.code.append("+")
        move_to(b)
        self.code.append("]")

        move_to(tmp)
        self.code.append("[")
        self.code.append("-")
        move_to(b)
        self.code.append("+")
        move_to(tmp)
        self.code.append("]")

        move_to(a)
        self.code.append("]")

        self.ptr = pos

    def square_preserve(self, src, dst):
        a = self.cells["a"]
        b = self.cells["b"]
        tmp = self.cells["tmp"]
        r = self.cells["r"]

        self.clear_many(dst, b)

        # Copy src into a and b while preserving src, then multiply a*b into dst.
        self.distribute_preserve(src, [(a, 1), (b, 1)], r)
        self._mul_from_ab_into_dst(a, b, dst, tmp)

    def build(self):
        return "".join(self.code)


def emit_g8_bf(rounds=5):
    bf = BFEmitter(BF_CELLS)
    bf.reset()

    seed = BF_CELLS["seed"]
    x = BF_CELLS["x"]
    y = BF_CELLS["y"]
    w = BF_CELLS["w"]
    out = BF_CELLS["out"]
    tx = BF_CELLS["tx"]
    ty = BF_CELLS["ty"]
    tw = BF_CELLS["tw"]
    xsq = BF_CELLS["xsq"]

    bf.mv(seed)
    bf.code.append(",")

    # Init G8 exactly: x = seed + 19, y = 3*seed - 5, w = -7*seed + 11.
    bf.distribute_destroy(seed, [
        (x, 1),
        (y, 3),
        (w, -7),
    ])
    bf.add_const(x, 19)
    bf.add_const(y, -5)
    bf.add_const(w, 11)

    for _ in range(rounds):
        # w = w + 19
        bf.add_const(w, 19)

        # x = x*x + 3*y - 5*w
        bf.square_add_move_back(x, tx, [
            (y, 3),
            (w, -5),
        ])

        # Cache updated x^2 once for reuse in y and out.
        bf.square_preserve(x, xsq)

        # y = y*y + x*x - 7*x + 11*w
        bf.square_destroy_into_zero(y, ty)
        bf.accumulate_into(ty, [
            (xsq, 1),
            (x, -7),
            (w, 11),
        ])
        bf.move_value_into_zero(ty, y)

        # w = w*w - 13*x + 17*y
        bf.square_add_move_back(w, tw, [
            (x, -13),
            (y, 17),
        ])

        # out = x*x - 19*y + 31*w
        bf.clear(out)
        bf.move_value_into_zero(xsq, out)
        bf.accumulate_into(out, [
            (y, -19),
            (w, 31),
        ])

        bf.mv(out)
        bf.code.append(".")

    return bf.build()


def main():
    for name, init, step in GENERATORS:
        print_generator_samples(name, init, step)

    for name, init, step in GENERATORS:
        analyze_generator_strong(name, init, step)

    for name, init, step in GENERATORS:
        analyze_generator_longrun(name, init, step)

    bf_program = emit_g8_bf()
    print("Exact raw BF code for G8:")
    print(bf_program)
    print()
    print(f"BF length: {len(bf_program)}")


if __name__ == "__main__":
    main()
