import sys
import subprocess
import os

wheel_file = sys.argv[2]
wheel_dir = os.path.dirname(wheel_file)
args = sys.argv[3:]
os.makedirs(wheel_dir, exist_ok=True)
subprocess.run([sys.executable] + args)
os.link(os.listdir(wheel_dir)[0], wheel_file) 
