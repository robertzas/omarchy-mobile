# SPDX-License-Identifier: MIT
"""Received SMS are written to disk (fsynced) before the modem gets its ACK,
so a message the network considers delivered is never lost here."""
import os
import uuid

import paths


def persist_sms(packet):
    if len(packet) < 10 or not 1 <= packet[9] <= 244 or len(packet) < 10 + packet[9]:
        raise ValueError('invalid incoming SMS layout')
    inbox = paths.private_dir(paths.INBOX)
    fd = os.open(inbox / (uuid.uuid4().hex + '.sit'),
                 os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600)
    with os.fdopen(fd, 'wb') as out:
        out.write(packet)
        out.flush()
        os.fsync(out.fileno())
    directory = os.open(inbox, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    return packet[8]
