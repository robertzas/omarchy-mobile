# SPDX-License-Identifier: MIT
"""The AoC's output tuning protocol, for the speaker's Waves component only.

Commands are the GPL AoC interface's structures (aoc-interface-gs201.h),
packed little-endian, each starting with CMD_HDR {u8 type = 0, u8 counter,
u16 length, u16 id, i16 reply}. A bulk exchange, as stock's platform
library does it (device/cheetah/AOC-TUNING-RESEARCH.md 2.2):

  1. open /dev/acd-audio_output_tuning (O_RDWR), audio_bulk_tx (O_WRONLY)
     and audio_bulk_rx (O_RDONLY), all non-blocking;
  2. write the payload, zero-padded to the whole 16 KiB bulk buffer, to
     audio_bulk_tx;
  3. write the 26-byte SET_GET_PARAM_BULK command to audio_output_tuning;
  4. wait for the reply on audio_output_tuning (500 ms, then -110); its
     reply field is the AoC's return code, and a non-zero rx_size means the
     AoC's answer is waiting on audio_bulk_rx;
  5. close all three.

This module refuses everything but block 16 (the speaker mixer) component 2
(Waves): SET_GET_PARAM_BULK of at most 16384 bytes, and the read-only
GET_PARAMETER of key 0 ("AoC Speaker Mixer ASP Mode"). One exchange at a
time.
"""
import errno
import os
import select
import struct
import threading
import time

CMD_SET_PARAMETER = 0x00d1
CMD_SET_PARAMETER_BULK = 0x00d2
CMD_GET_PARAMETER = 0x00d3
CMD_SET_GET_PARAM_BULK = 0x00d5

BLOCK_SPEAKER = 16
COMPONENT_WAVES = 2
KEY_ASP_MODE = 0
BULK_SIZE = 16384

DEV_TUNING = '/dev/acd-audio_output_tuning'
DEV_BULK_TX = '/dev/acd-audio_bulk_tx'
DEV_BULK_RX = '/dev/acd-audio_bulk_rx'

HDR = struct.Struct('<BBHHh')                          # 8
SET_GET_BULK = struct.Struct('<BBHHhBBHHIIHH')         # 26
GET_PARAM = struct.Struct('<BBHHhBBII')                # 18

ETIMEDOUT = -errno.ETIMEDOUT                           # -110, as the AoC driver
ASP_MODES = {0: 'ASP_OFF', 1: 'ASP_ON', 2: 'ASP_BYPASS', 3: 'ASP_GROUND'}


class Refused(Exception):
    """A request outside the allowlist; nothing was sent."""


def check_allowed(cmd, block, component, key=None, size=0):
    if (block, component) != (BLOCK_SPEAKER, COMPONENT_WAVES):
        raise Refused(f'block {block} component {component} is not the speaker Waves component')
    if cmd == CMD_SET_GET_PARAM_BULK:
        if not 0 < size <= BULK_SIZE:
            raise Refused(f'bulk payload of {size} bytes (1..{BULK_SIZE})')
    elif cmd == CMD_GET_PARAMETER:
        if key != KEY_ASP_MODE:
            raise Refused(f'GET_PARAMETER key {key} (only {KEY_ASP_MODE}, ASP Mode)')
    else:
        raise Refused(f'command 0x{cmd:04x}')


def pack_set_get_bulk(counter, block, component, tx_size):
    check_allowed(CMD_SET_GET_PARAM_BULK, block, component, size=tx_size)
    return SET_GET_BULK.pack(0, counter & 0xff, SET_GET_BULK.size, CMD_SET_GET_PARAM_BULK, 0,
                             block, component, 0, 0, 0, 0, tx_size, 0)


def pack_get_parameter(counter, block, component, key):
    check_allowed(CMD_GET_PARAMETER, block, component, key=key)
    return GET_PARAM.pack(0, counter & 0xff, GET_PARAM.size, CMD_GET_PARAMETER, 0,
                          block, component, key, 0)


def parse_reply(msg):
    """(id, counter, reply, fields) of an AoC reply; fields is the decoded
    command for the two commands we send, else None."""
    if len(msg) < HDR.size:
        return None
    _, counter, _, cid, reply = HDR.unpack_from(msg)
    fields = None
    if cid == CMD_SET_GET_PARAM_BULK and len(msg) >= SET_GET_BULK.size:
        fields = SET_GET_BULK.unpack_from(msg)
    elif cid == CMD_GET_PARAMETER and len(msg) >= GET_PARAM.size:
        fields = GET_PARAM.unpack_from(msg)
    return cid, counter, reply, fields


class AocTuningPort:
    """The only opener of the three AoC tuning devices, one exchange at a
    time. `opener(path, flags)` returns a file descriptor (tests pass
    sockets)."""

    def __init__(self, tuning=DEV_TUNING, bulk_tx=DEV_BULK_TX, bulk_rx=DEV_BULK_RX,
                 opener=os.open, timeout=0.5, log=None):
        self.paths = (tuning, bulk_tx, bulk_rx)
        self.opener = opener
        self.timeout = timeout
        self.counter = 0
        self.lock = threading.Lock()
        self.log = log or (lambda msg: None)

    def _open(self):
        flags = (os.O_RDWR, os.O_WRONLY, os.O_RDONLY)
        fds = []
        try:
            for path, fl in zip(self.paths, flags):
                fds.append(self.opener(path, fl | os.O_NONBLOCK | os.O_CLOEXEC))
        except OSError:
            for fd in fds:
                os.close(fd)
            raise
        return fds

    @staticmethod
    def _drain(fd):
        n = 0
        while True:
            r, _, _ = select.select([fd], [], [], 0)
            if not r:
                return n
            try:
                if not os.read(fd, BULK_SIZE):
                    return n
            except BlockingIOError:
                return n
            n += 1

    def _wait_reply(self, fd, cid, counter):
        deadline = time.monotonic() + self.timeout
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return None
            r, _, _ = select.select([fd], [], [], left)
            if not r:
                return None
            try:
                msg = os.read(fd, BULK_SIZE)
            except BlockingIOError:
                continue
            p = parse_reply(msg)
            if p and p[0] == cid and p[1] == counter & 0xff:
                return p
            self.log(f'ignored a stray reply ({len(msg)} bytes, id 0x{p[0]:04x})' if p else
                     f'ignored a short reply ({len(msg)} bytes)')

    def _next(self):
        self.counter = (self.counter + 1) & 0xff
        return self.counter

    def set_get_bulk(self, block, component, payload):
        """One bulk write to the AoC. Returns (rc, rx bytes): rc is the AoC's
        reply (0 or negative), -110 on a timeout, a negative errno when the
        devices could not be used."""
        check_allowed(CMD_SET_GET_PARAM_BULK, block, component, size=len(payload))
        with self.lock:
            counter = self._next()
            cmd = pack_set_get_bulk(counter, block, component, len(payload))
            try:
                tun, tx, rx = self._open()
            except OSError as e:
                return -(e.errno or errno.EIO), b''
            try:
                stale = self._drain(tun) + self._drain(rx)
                if stale:
                    self.log(f'dropped {stale} stale message(s) before the exchange')
                buf = bytes(payload) + bytes(BULK_SIZE - len(payload))
                try:
                    if os.write(tx, buf) != BULK_SIZE:
                        return -errno.EIO, b''
                    if os.write(tun, cmd) != len(cmd):
                        return -errno.EIO, b''
                except OSError as e:
                    return -(e.errno or errno.EIO), b''
                rep = self._wait_reply(tun, CMD_SET_GET_PARAM_BULK, counter)
                if rep is None:
                    return ETIMEDOUT, b''
                _, _, rc, fields = rep
                if fields is None:
                    return -errno.EPROTO, b''
                rx_size = fields[12]   # u16 at offset 24
                if rc != 0 or not rx_size:
                    return rc, b''
                if rx_size > BULK_SIZE:
                    return -errno.EPROTO, b''
                r, _, _ = select.select([rx], [], [], self.timeout)
                if not r:
                    return ETIMEDOUT, b''
                try:
                    data = os.read(rx, BULK_SIZE)
                except OSError as e:
                    return -(e.errno or errno.EIO), b''
                return 0, data[:rx_size]
            finally:
                for fd in (tun, tx, rx):
                    os.close(fd)

    def get_parameter(self, block, component, key):
        """Read-only GET_PARAMETER (ASP Mode). Returns (rc, value)."""
        check_allowed(CMD_GET_PARAMETER, block, component, key=key)
        with self.lock:
            counter = self._next()
            cmd = pack_get_parameter(counter, block, component, key)
            try:
                tun, tx, rx = self._open()
            except OSError as e:
                return -(e.errno or errno.EIO), None
            try:
                self._drain(tun)
                try:
                    os.write(tun, cmd)
                except OSError as e:
                    return -(e.errno or errno.EIO), None
                rep = self._wait_reply(tun, CMD_GET_PARAMETER, counter)
                if rep is None:
                    return ETIMEDOUT, None
                _, _, rc, fields = rep
                if fields is None:
                    return -errno.EPROTO, None
                return rc, fields[8]
            finally:
                for fd in (tun, tx, rx):
                    os.close(fd)
