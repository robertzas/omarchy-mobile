# SPDX-License-Identifier: MIT
"""Imported first by every test: the library on sys.path, and every path the
library uses moved into a private temporary directory (no /run, /var or
device access from the tests)."""
import atexit
import os
import shutil
import sys
import tempfile

LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'lib')
TMP = tempfile.mkdtemp(prefix='omandroid-sit-test-')
atexit.register(shutil.rmtree, TMP, True)
os.environ.update({
    'OMANDROID_SIT_RUN': os.path.join(TMP, 'run'),
    'OMANDROID_SIT_STATE': os.path.join(TMP, 'state'),
    'OMANDROID_SIT_CONFIG': os.path.join(TMP, 'modem-sit.conf'),
    'OMANDROID_SIT_DEVICE': 'unix:' + os.path.join(TMP, 'ipc0'),
    'OMANDROID_SIT_ROUTER': 'unix:' + os.path.join(TMP, 'router'),
    'OMANDROID_SIT_BOOT': 'none',
})
os.makedirs(os.path.join(TMP, 'run'), mode=0o700)
if LIB not in sys.path:
    sys.path.insert(0, os.path.abspath(LIB))
