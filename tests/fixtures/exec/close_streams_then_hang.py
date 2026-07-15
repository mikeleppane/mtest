#!/usr/bin/env python3
"""Close stdout and stderr, then sleep forever.

Closing fds 1 and 2 delivers EOF on both capture pipes while the process keeps
running. EOF is therefore NOT completion: a supervisor that treats "both pipes
at EOF" as "child done" and issues a blocking wait hangs here forever. The
correct supervisor keeps enforcing the deadline after EOF and kills this process
when the timeout fires.
"""
import os
import time

os.close(1)
os.close(2)
time.sleep(300)
