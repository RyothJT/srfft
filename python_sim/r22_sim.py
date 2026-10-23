import cmath
import math
import numpy as np


# =============================================================================
# HELPER FUNCTIONS
# =============================================================================
def bit_reverse(val, bits):
    """Reverses the binary representation of val over given number of bits."""
    res = 0
    for b in range(bits):
        res = (res << 1) | ((val >> b) & 1)
    return res


def reorder_bit_reversed(x):
    """Reorders a bit-reversed sequence into natural monotonic order."""
    N = len(x)
    bits = int(math.log2(N))
    out = [0j] * N
    for i in range(N):
        natural_idx = bit_reverse(i, bits)
        out[natural_idx] = x[i]
    return out


# =============================================================================
# R2^2 STAGE PAIR (Hardware Equivalent of r22_stage_pair.sv)
# =============================================================================
def r22_stage_pair(x, N, return_intermediates=False):
    """Executes one Radix-2^2 stage pair (BF-I, BF-II with -j, and Twiddle Cmult).

    Equivalent to r22_stage_pair.sv.
    Takes input stream of length N, returns processed stream of length N.
    """
    D1 = N // 2
    D2 = N // 4

    # -------------------------------------------------------------------------
    # 1. Butterfly I: Delay D1 = N/2
    # -------------------------------------------------------------------------
    # Sums: a[n] = x[n] + x[n + D1]
    # Diffs: b[n] = x[n] - x[n + D1]
    a = [x[n] + x[n + D1] for n in range(D1)]
    b = [x[n] - x[n + D1] for n in range(D1)]
    bf1_stream = a + b  # Serial stream order out of BF1

    # -------------------------------------------------------------------------
    # 2. Butterfly II: Delay D2 = N/4 with Trivial -j Logic
    # -------------------------------------------------------------------------
    # Applied to upper half (a): No -j rotation
    c = [a[n] + a[n + D2] for n in range(D2)]
    d = [a[n] - a[n + D2] for n in range(D2)]

    # Applied to lower half (b): Trivial -j rotation on second quarter of b
    # (corresponds to 4th quadrant of N: cnt[msb:msb-1] == 2'b11)
    b_rot = [b[n + D2] * (-1j) for n in range(D2)]
    e = [b[n] + b_rot[n] for n in range(D2)]
    f = [b[n] - b_rot[n] for n in range(D2)]

    bf2_stream = c + d + e + f  # 4 blocks of size N/4

    # -------------------------------------------------------------------------
    # 3. Twiddle Multiplication (W_N^k)
    # -------------------------------------------------------------------------
    # Block 0 (c): W_N^0 = 1.0 (bypassed)
    # Block 1 (d): W_N^(2k)
    # Block 2 (e): W_N^k
    # Block 3 (f): W_N^(3k)
    twiddled_stream = [0j] * N
    is_last_stage = N == 4

    for k in range(D2):
        if is_last_stage:
            # Terminal stage (N=4): All twiddles are exactly 1.0
            twiddled_stream[0 * D2 + k] = c[k]
            twiddled_stream[1 * D2 + k] = d[k]
            twiddled_stream[2 * D2 + k] = e[k]
            twiddled_stream[3 * D2 + k] = f[k]
        else:
            w_2k = cmath.exp(-2j * math.pi * (2 * k) / N)
            w_1k = cmath.exp(-2j * math.pi * (1 * k) / N)
            w_3k = cmath.exp(-2j * math.pi * (3 * k) / N)

            twiddled_stream[0 * D2 + k] = c[k] * 1.0
            twiddled_stream[1 * D2 + k] = d[k] * w_2k
            twiddled_stream[2 * D2 + k] = e[k] * w_1k
            twiddled_stream[3 * D2 + k] = f[k] * w_3k

    if return_intermediates:
        intermediates = {
            "bf1_a": a,
            "bf1_b": b,
            "bf2_c": c,
            "bf2_d": d,
            "bf2_e": e,
            "bf2_f": f,
            "twiddled_output": twiddled_stream,
        }
        return twiddled_stream, intermediates
    return twiddled_stream


# =============================================================================
# LINEAR PIPELINE TOP MODULE (Hardware Equivalent of r22_fft_top.sv)
# =============================================================================
def fft_r22(x, return_stages=False):
    """Computes full R2^2 SDF FFT for any power-of-4 length N = 4^m.

    Follows the strict linear cascade of r22_fft_top.sv.
    """
    N = len(x)
    num_pairs = int(math.log2(N)) // 2

    current_data = list(x)
    stage_traces = []

    # Linear cascade across pairs of stages: e.g. 16 -> 4, or 64 -> 16 -> 4
    for i in range(num_pairs):
        stage_N = N // (4**i)
        sub_len = stage_N
        num_sub_blocks = N // sub_len

        next_data = [0j] * N
        pair_intermediates = []

        # Process each block of size stage_N flowing through this stage
        for b in range(num_sub_blocks):
            blk_in = current_data[b * sub_len : (b + 1) * sub_len]
            blk_out, inter = r22_stage_pair(blk_in, stage_N, return_intermediates=True)
            next_data[b * sub_len : (b + 1) * sub_len] = blk_out
            pair_intermediates.append(inter)

        current_data = next_data
        stage_traces.append({"stage_N": stage_N, "data": current_data, "sub_blocks": pair_intermediates})

    raw_bit_reversed_output = current_data
    natural_output = reorder_bit_reversed(raw_bit_reversed_output)

    if return_stages:
        return natural_output, raw_bit_reversed_output, stage_traces
    return natural_output


# =============================================================================
# VERIFICATION TESTS
# =============================================================================
if __name__ == "__main__":
    print("=" * 70)
    print("1. TEST: 16-POINT RADIX-2^2 SDF FFT (N = 16)")
    print("=" * 70)

    # Impulse test vector
    x16 = [1.0] + [0.0] * 15
    X_nat16, X_raw16, stages16 = fft_r22(x16, return_stages=True)
    X_np16 = np.fft.fft(x16)

    # Inspect Stage Pair 1 (N = 16)
    stg1 = stages16[0]["sub_blocks"][0]
    print("\n--- Stage Pair 1 (N = 16) Intermediate Outputs ---")
    print(f"BF-I Sums a[0..7]  : {[f'{v:.2f}' for v in stg1['bf1_a']]}")
    print(f"BF-I Diffs b[0..7] : {[f'{v:.2f}' for v in stg1['bf1_b']]}")
    print(f"BF-II c[0..3] (Blk 0) : {[f'{v:.2f}' for v in stg1['bf2_c']]}")
    print(f"BF-II d[0..3] (Blk 1) : {[f'{v:.2f}' for v in stg1['bf2_d']]}")
    print(f"BF-II e[0..3] (Blk 2) : {[f'{v:.2f}' for v in stg1['bf2_e']]}")
    print(f"BF-II f[0..3] (Blk 3) : {[f'{v:.2f}' for v in stg1['bf2_f']]}")

    print("\n--- Pipeline Outputs ---")
    print("Raw Output from Pipeline (Bit-Reversed Order):")
    for i, val in enumerate(X_raw16):
        print(f"  Cycle {i:2d} (Bin {bit_reverse(i, 4):2d}): {val:.4f}")

    print("\nReordered Output (Natural Frequency Order):")
    for k, val in enumerate(X_nat16):
        print(f"  X16[{k:2d}] = {val:.4f}")

    print("\nMatches NumPy FFT:", np.allclose(X_nat16, X_np16))

    print("\n" + "=" * 70)
    print("2. TEST: 64-POINT RADIX-2^2 SDF FFT (N = 64, Sine Wave Input)")
    print("=" * 70)

    N64 = 64
    k_tone = 16  # Pure tone at bin 16
    x64 = [math.sin(2 * math.pi * k_tone * n / N64) for n in range(N64)]

    X_nat64, X_raw64, _ = fft_r22(x64, return_stages=True)
    X_np64 = np.fft.fft(x64)

    print(f"Input Tone Frequency: Bin {k_tone} and Bin {N64 - k_tone}")
    print(f"Magnitude at Bin {k_tone:2d}      : {abs(X_nat64[k_tone]):.4f} (Expected: {N64/2:.4f})")
    print(f"Magnitude at Bin {N64-k_tone:2d}      : {abs(X_nat64[N64-k_tone]):.4f} (Expected: {N64/2:.4f})")
    print(f"Magnitude at Bin 0 (DC)   : {abs(X_nat64[0]):.4f}")

    print("\nMatches NumPy FFT exactly across all 64 bins:", np.allclose(X_nat64, X_np64))
