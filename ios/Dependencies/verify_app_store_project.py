"""Fail before archiving if the iPhone-only project still includes Station SDK inputs."""
from pathlib import Path
import sys


def verify_project(path):
    contents = Path(path).read_text()
    for forbidden in ('.dependencies/mediapipe', 'MediaPipeTasksVision',
                      'MediaPipeTasksCommon', 'pose_landmarker_full.task', '-force_load'):
        if forbidden in contents:
            raise ValueError(f'App Store project retains Station SDK input: {forbidden}')
    if 'APP_STORE_IPHONE_ONLY' not in contents:
        raise ValueError('App Store project is missing APP_STORE_IPHONE_ONLY')


if __name__ == '__main__':
    try:
        verify_project(sys.argv[1])
    except (OSError, ValueError) as error:
        sys.exit(str(error))
