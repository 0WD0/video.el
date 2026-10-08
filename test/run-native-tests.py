"""Run the native regressions against the same packaged SDK used by video.el."""

import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from wdoom.bazel import package

with tempfile.TemporaryDirectory(dir=os.environ["TEST_TMPDIR"]) as directory:
    package.extract(argparse.Namespace(archive=sys.argv[1], directory=directory))
    for program in sys.argv[2:]:
        subprocess.run([str(Path(directory) / "native" / program)], check=True)
