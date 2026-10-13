# SPDX-License-Identifier: MIT
"""IMS voice call layouts: the dial request and the call status indication."""
import struct


def dial_payload(destination):
    """AIMS_DIAL: voice=1, default CLIR, a fixed 513-byte number field; no
    CUG, TTY, emergency, USSD, video, pulled call or geolocation."""
    number = destination.encode('ascii')
    if not 1 <= len(number) <= 513:
        raise ValueError('invalid number length')
    payload = bytearray(679)
    struct.pack_into('<HBH', payload, 0, 1, 0, len(number))
    payload[5:5+len(number)] = number
    return bytes(payload)


def call_status(packet):
    """IND_AIMS_CALL_STATUS: (call type, call id, state, cause). Connected
    party numbers and SDP remain private and are not returned."""
    if len(packet) < 19 or struct.unpack_from('<H', packet, 2)[0] != 0x0d04:
        raise ValueError('short or incorrect IMS call indication')
    call_type, call_id, state, multiparty, users = struct.unpack_from('<HBBBB', packet, 8)
    if state > 8 or multiparty or users > 1:
        raise ValueError('unsupported IMS call status')
    return call_type, call_id, state, packet[15]


def ring(packet):
    """IND_AIMS_CALL_RING: (call type, call id, caller) or None."""
    if len(packet) < 13 or struct.unpack_from('<H', packet, 2)[0] != 0x0d01:
        raise ValueError('short or incorrect IMS ring indication')
    kind, call_id, length = struct.unpack_from('<HBH', packet, 8)
    if length > 513 or len(packet) < 13 + length:
        return None
    caller = packet[13:13+length].rstrip(b'\0').decode('ascii', errors='replace')
    return kind, call_id, caller
