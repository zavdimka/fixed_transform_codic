"""Image metrics kept outside the integer/byte reference datapath."""

import math
import numpy as np


def psnr(reference: np.ndarray, test: np.ndarray) -> float:
    difference = reference.astype(np.int32) - test.astype(np.int32)
    mse = float(np.mean(difference * difference))
    return float("inf") if mse == 0 else 10.0 * math.log10(255.0 * 255.0 / mse)
