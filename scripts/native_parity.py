"""Strict decoded-media comparisons shared by the native proof and its tests."""
import array
import math
import sys


def compare_rgb(actual, expected, frame_size, tolerance=12):
    if frame_size <= 0 or len(actual) != len(expected) or not actual or len(actual) % frame_size:
        raise ValueError('RGB buffers must have matching, complete, nonempty frames')
    errors = []
    for start in range(0, len(actual), frame_size):
        error = sum(abs(a - b) for a, b in zip(actual[start:start + frame_size],
                                              expected[start:start + frame_size])) / frame_size
        if error >= tolerance:
            raise ValueError(f'Frame {start // frame_size} mean RGB error {error} exceeds {tolerance}')
        errors.append(error)
    return {'frames': len(errors), 'maxMeanRGBError': max(errors)}


def compare_float_audio(actual, expected_s16, channels, tolerance=1 / 32768):
    if channels <= 0 or not actual or len(actual) % (4 * channels) or len(actual) != len(expected_s16) * 2:
        raise ValueError('PCM buffers must have matching, complete, nonempty sample frames')
    floats, integers = array.array('f'), array.array('h')
    floats.frombytes(actual)
    integers.frombytes(expected_s16)
    if sys.byteorder != 'little':
        floats.byteswap()
        integers.byteswap()
    maximum = 0
    for index, (value, reference) in enumerate(zip(floats, integers)):
        if not math.isfinite(value):
            raise ValueError(f'Nonfinite sample {index}')
        error = abs(value - reference / 32768)
        if error > tolerance:
            raise ValueError(f'Sample {index} error {error} exceeds {tolerance}')
        maximum = max(maximum, error)
    return {'samplesPerChannel': len(floats) // channels, 'maxErrorInS16Units': maximum * 32768}
