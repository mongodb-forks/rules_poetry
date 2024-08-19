import sys
import subprocess
import shutil
import os

dest_dir = sys.argv[1]
os.makedirs(dest_dir, exist_ok=True)
p = subprocess.run([sys.executable] + sys.argv[2:], check=True)
shutil.make_archive(dest_dir, 'zip', dest_dir)
