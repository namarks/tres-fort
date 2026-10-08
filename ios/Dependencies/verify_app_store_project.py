"""Require the public iPhone + iPad project without experimental camera SDK inputs."""
from pathlib import Path
import re
import sys


def verify_project(path):
    contents = Path(path).read_text()
    for forbidden in ('.dependencies/mediapipe', 'MediaPipeTasksVision',
                      'MediaPipeTasksCommon', 'pose_landmarker_full.task', '-force_load'):
        if forbidden in contents:
            raise ValueError(f'App Store project retains Station SDK input: {forbidden}')
    if 'APP_STORE_IPHONE_ONLY' in contents:
        raise ValueError('App Store project retains deprecated APP_STORE_IPHONE_ONLY')
    if 'APP_STORE_BUILD' not in contents:
        raise ValueError('App Store project is missing APP_STORE_BUILD')
    families = re.findall(r'TARGETED_DEVICE_FAMILY = ([^;]+);', contents)
    # XcodeGen also writes device families on test targets. The packaging test
    # resolves app/widget configuration references; this prebuild guard rejects
    # any single-family declaration, including overrides on either test target.
    if len(families) < 4 or any(value.strip().strip('"') != '1,2' for value in families):
        raise ValueError('App Store project must target iPhone + iPad in its device-family settings')


if __name__ == '__main__':
    try:
        verify_project(sys.argv[1])
    except (OSError, ValueError) as error:
        sys.exit(str(error))
