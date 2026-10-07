# SPDX-License-Identifier: MIT OR Apache-2.0
"""Run mode-compare in fresh processes; arguments: test program, library."""
import os
import subprocess
import sys

count = 0
for mode in (None, "", "info", "INFO", "debug", "off", "disable", "stream", "unknown"):
    for stream in (None, "live", "LIVE", "other"):
        for propagate in (None, "", "0"):
            env = os.environ.copy()
            for key, value in (
                ("OS_ACTIVITY_MODE", mode),
                ("OS_ACTIVITY_STREAM", stream),
                ("OS_ACTIVITY_PROPAGATE_MODE", propagate),
            ):
                if value is None:
                    env.pop(key, None)
                else:
                    env[key] = value
            result = subprocess.run(sys.argv[1:], env=env, capture_output=True, text=True)
            if result.returncode:
                raise RuntimeError((mode, stream, propagate, result.stdout, result.stderr))
            count += 1
print(f"{count} fresh environments passed; {count * 1003} host state comparisons")
