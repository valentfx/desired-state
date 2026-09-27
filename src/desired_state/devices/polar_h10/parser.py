"""Bluetooth Heart Rate Measurement characteristic (0x2A37) parser."""
from dataclasses import dataclass


@dataclass(frozen=True)
class HeartRatePacket:
    bpm: int
    rr_ticks: tuple[int, ...]  # 1/1024 second units
    contact_detected: bool | None


def parse_heart_rate(data: bytes) -> HeartRatePacket:
    if not data:
        raise ValueError("empty heart-rate measurement")
    flags = data[0]
    offset = 1
    width = 2 if flags & 1 else 1
    if len(data) < offset + width:
        raise ValueError("truncated heart-rate value")
    bpm = int.from_bytes(data[offset:offset + width], "little")
    offset += width
    if flags & 0x08:
        if len(data) < offset + 2:
            raise ValueError("truncated energy-expended value")
        offset += 2
    remainder = data[offset:]
    if flags & 0x10:
        if len(remainder) % 2:
            raise ValueError("truncated RR interval")
        ticks = tuple(int.from_bytes(remainder[i:i + 2], "little") for i in range(0, len(remainder), 2))
    else:
        if remainder:
            raise ValueError("unexpected trailing bytes")
        ticks = ()
    contact = bool(flags & 0x04) if flags & 0x02 else None
    return HeartRatePacket(bpm, ticks, contact)
