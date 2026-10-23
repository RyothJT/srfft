import cmath
import math
import numpy as np


# =============================================================================
# BASE BUTTERFLIES
# =============================================================================
def radix2(a, b, w=1.0):
    """2-point DIF butterfly with twiddle w."""
    bw = b * w
    return a + bw, a - bw


def radix4(y0, y1, y2, y3):
    """4-point Radix-4 DIF butterfly (computes full 4-point DFT)."""
    t0, t1 = y0 + y2, y0 - y2
    t2, t3 = y1 + y3, -1j * (y1 - y3)
    return t0 + t2, t1 + t3, t0 - t2, t1 - t3


# =============================================================================
# 8-POINT SPLIT-RADIX (The "2nd L-shape" in the diagram)
# =============================================================================
def fft_8point_split_radix_dif(x, return_stage1=False):
    """8-point DIF Split-Radix unit.

    If return_stage1=True, returns (X, stage1_outputs) where stage1_outputs
    contains the 8 values before entering the sub-transforms.
    """
    C = math.sqrt(2) / 2
    W8_1 = complex(C, -C)
    W8_3 = complex(-C, -C)

    # --- 8-point Split-Radix Unit (2nd L-shape) ---
    # 4 span-4 butterflies
    s0, d0 = radix2(x[0], x[4])
    s1, d1 = radix2(x[1], x[5])
    s2, d2 = radix2(x[2], x[6])
    s3, d3 = radix2(x[3], x[7])

    # 2 cross butterflies with w = -j
    p0, q0 = radix2(d0, d2, w=-1j)
    p1, q1 = radix2(d1, d3, w=-1j)

    # DIF Twiddles applied after subtraction
    u0, u1 = p0 * 1.0, p1 * W8_1
    v0, v1 = q0 * 1.0, q1 * W8_3

    # Pack the 8 direct intermediate outputs before sub-transforms:
    # - [s0, s1, s2, s3] feed the Radix-4 unit
    # - [u0, u1]         feed Radix-2 unit #1
    # - [v0, v1]         feed Radix-2 unit #2
    stage1_outputs = {
        "radix4_inputs_s": [s0, s1, s2, s3],
        "radix2_inputs_u": [u0, u1],
        "radix2_inputs_v": [v0, v1],
    }

    # --- Sub-transforms ---
    X0, X2, X4, X6 = radix4(s0, s1, s2, s3)
    X1, X5 = radix2(u0, u1)
    X3, X7 = radix2(v0, v1)

    X = [X0, X1, X2, X3, X4, X5, X6, X7]

    if return_stage1:
        return X, stage1_outputs
    return X


# =============================================================================
# 16-POINT SPLIT-RADIX (The "1st L-shape" in the diagram)
# =============================================================================
def fft_16point_split_radix_dif(x, return_stages=False):
    """16-point Decimation-in-Frequency (DIF) Split-Radix FFT.

    If return_stages=True, returns (X, stage_outputs) where stage_outputs
    contains:
      - 'stage16': direct outputs of the 16-pt stage (s, u, v)
      - 'stage8' : direct intermediate outputs of the nested 8-pt stage
    """
    # 8 span-8 Radix-2 butterflies across distance N/2 = 8
    s = [0j] * 8
    d = [0j] * 8
    for n in range(8):
        s[n], d[n] = radix2(x[n], x[n + 8])

    # 4 cross Radix-2 butterflies across distance N/4 = 4 with w = -j
    p = [0j] * 4
    q = [0j] * 4
    for n in range(4):
        p[n], q[n] = radix2(d[n], d[n + 4], w=-1j)

    # Twiddle factors W_16^n and W_16^(3n)
    u = [0j] * 4
    v = [0j] * 4
    for n in range(4):
        w_n = cmath.exp(-2j * math.pi * n / 16)
        w_3n = cmath.exp(-2j * math.pi * (3 * n) / 16)
        u[n] = p[n] * w_n
        v[n] = q[n] * w_3n

    # --- Sub-transforms ---
    # Even path (length 8) feeds the 8-point split-radix unit
    E, stage8_intermediates = fft_8point_split_radix_dif(s, return_stage1=True)

    # Odd paths (length 4 each) feed two Radix-4 terminal units
    O1_0, O1_1, O1_2, O1_3 = radix4(u[0], u[1], u[2], u[3])
    O3_0, O3_1, O3_2, O3_3 = radix4(v[0], v[1], v[2], v[3])

    # Reconstruct natural order
    X = [0j] * 16
    for k in range(8):
        X[2 * k] = E[k]

    X[1], X[5], X[9], X[13] = O1_0, O1_1, O1_2, O1_3
    X[3], X[7], X[11], X[15] = O3_0, O3_1, O3_2, O3_3

    if return_stages:
        stage_outputs = {
            "stage16": {
                "s_to_8pt": s,
                "u_to_radix4": u,
                "v_to_radix4": v,
            },
            "stage8": stage8_intermediates,
        }
        return X, stage_outputs
    return X


# =============================================================================
# VERIFICATION TESTS
# =============================================================================
if __name__ == "__main__":
    print("=" * 65)
    print("1. TEST: 8-POINT SPLIT-RADIX FFT")
    print("=" * 65)

    x8 = [1.0] + [0.0] * 7
    X_sr8, stage1 = fft_8point_split_radix_dif(x8, return_stage1=True)
    X_np8 = np.fft.fft(x8)

    print("\n--- Direct Outputs of 8-pt Split-Radix Unit (Before Sub-transforms) ---")
    s = stage1["radix4_inputs_s"]
    u = stage1["radix2_inputs_u"]
    v = stage1["radix2_inputs_v"]

    print("Upper Branch (to Radix-4):")
    for i in range(4):
        print(f"  s[{i}] = {s[i]:.4f}")

    print("Lower Branch 1 (to Radix-2 #1):")
    for i in range(2):
        print(f"  u[{i}] = {u[i]:.4f}")

    print("Lower Branch 2 (to Radix-2 #2):")
    for i in range(2):
        print(f"  v[{i}] = {v[i]:.4f}")

    print("\n--- Final 8-Point FFT Output ---")
    for k in range(8):
        print(f"X8[{k}] = {X_sr8[k]:.4f}")

    print("Matches NumPy FFT:", np.allclose(X_sr8, X_np8))

    print("\n" + "=" * 65)
    print("2. TEST: 16-POINT SPLIT-RADIX FFT")
    print("=" * 65)

    # Test vector for 16-point FFT (Impulse input)
    x16 = [1.0] + [0.0] * 15
    X_sr16, stages16 = fft_16point_split_radix_dif(x16, return_stages=True)
    X_np16 = np.fft.fft(x16)

    print("\n--- Direct Outputs of 16-pt Split-Radix Unit (1st L-shape) ---")
    s16 = stages16["stage16"]["s_to_8pt"]
    u16 = stages16["stage16"]["u_to_radix4"]
    v16 = stages16["stage16"]["v_to_radix4"]

    print("Upper Branch s (feeds 8-pt Split-Radix Unit, length 8):")
    for i in range(8):
        print(f"  s[{i}] = {s16[i]:.4f}")

    print("\nLower Branch 1 u (feeds Odd Radix-4 Core #1, length 4):")
    for i in range(4):
        print(f"  u[{i}] = {u16[i]:.4f}")

    print("\nLower Branch 2 v (feeds Odd Radix-4 Core #2, length 4):")
    for i in range(4):
        print(f"  v[{i}] = {v16[i]:.4f}")

    print("\n--- Direct Outputs of Nested 8-pt Split-Radix Unit (2nd L-shape) ---")
    s8 = stages16["stage8"]["radix4_inputs_s"]
    u8 = stages16["stage8"]["radix2_inputs_u"]
    v8 = stages16["stage8"]["radix2_inputs_v"]

    print("Even-Upper Branch s8 (feeds Even Radix-4 Core, length 4):")
    for i in range(4):
        print(f"  s8[{i}] = {s8[i]:.4f}")

    print("\nEven-Lower Branch 1 u8 (feeds Even Radix-2 Core #1, length 2):")
    for i in range(2):
        print(f"  u8[{i}] = {u8[i]:.4f}")

    print("\nEven-Lower Branch 2 v8 (feeds Even Radix-2 Core #2, length 2):")
    for i in range(2):
        print(f"  v8[{i}] = {v8[i]:.4f}")

    print("\n--- Final 16-Point FFT Output ---")
    for k in range(16):
        print(f"X16[{k:2d}] = {X_sr16[k]:.4f}")

    print("\nMatches NumPy FFT exactly:", np.allclose(X_sr16, X_np16))
