"""Validate the noninterlaced, 8-bit RGB PNGs exported by iOS screenshots."""
import re
import struct
import zlib


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_png(data):
    require(data[:8] == b'\x89PNG\r\n\x1a\n', 'Not PNG')
    offset = 8
    types = []
    image_data = []
    image_data_closed = False
    ended = False
    while offset < len(data):
        require(len(data) - offset >= 12, 'Truncated PNG chunk')
        length = struct.unpack('>I', data[offset:offset + 4])[0]
        require(length <= len(data) - offset - 12, 'Invalid PNG chunk length')
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        checksum = struct.unpack('>I', data[offset + 8 + length:offset + 12 + length])[0]
        require(zlib.crc32(kind + payload) == checksum, 'PNG checksum mismatch')
        require(re.fullmatch(b'[A-Za-z]{2}[A-Z][A-Za-z]', kind), 'Invalid PNG chunk type')
        require(kind != b'tRNS', 'Transparency is not allowed')
        if not types:
            require(kind == b'IHDR' and length == 13, 'Missing PNG header')
            require(struct.unpack('>IIBBBBB', payload) == (1206, 2622, 8, 2, 0, 0, 0),
                    'Expected opaque 1206 x 2622 RGB screenshot')
        else:
            require(kind != b'IHDR', 'Duplicate PNG header')
        if kind == b'IDAT':
            require(not image_data_closed, 'Nonconsecutive PNG image data')
            image_data.append(payload)
        elif image_data:
            image_data_closed = True
        if kind == b'PLTE':
            require(not image_data and kind not in types and 0 < length <= 768 and length % 3 == 0,
                    'Invalid PNG palette')
        if kind[:1].isupper():
            require(kind in (b'IHDR', b'PLTE', b'IDAT', b'IEND'), 'Unknown critical PNG chunk')
        types.append(kind)
        offset += length + 12
        if kind == b'IEND':
            require(length == 0, 'Invalid PNG end chunk')
            ended = True
            break
    require(ended and offset == len(data) and image_data, 'Incomplete PNG structure')
    # Decode the bounded scanline stream too: a recomputed CRC cannot make
    # broken compression or an invalid row filter into a valid screenshot.
    row_size = 1 + 1206 * 3
    expected_size = row_size * 2622
    decoder = zlib.decompressobj()
    pixels = decoder.decompress(b''.join(image_data), expected_size + 1)
    require(decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail,
            'Invalid PNG compressed stream')
    require(len(pixels) == expected_size, 'Invalid PNG pixel data size')
    require(all(pixels[offset] <= 4 for offset in range(0, expected_size, row_size)),
            'Invalid PNG scanline filter')
