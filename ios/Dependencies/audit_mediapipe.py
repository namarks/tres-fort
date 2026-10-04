"""Fail closed if pinned MediaPipe binaries drift from the reviewed local runner."""
import hashlib
import json
from pathlib import Path
import subprocess


def check_symbols(symbols, require_runner=False):
    forbidden = ('TasksLogger', 'TasksStats', 'StatsLogger', 'Clearcut', 'GTMSessionFetcher',
                 'NSURLSession', 'NSURLConnection', 'CFHTTP', 'CFNetwork', 'curl_easy', 'curl_multi')
    network_imports = {'_socket', '_connect', '_send', '_sendto', '_recv', '_recvfrom',
                       '_getaddrinfo', '_gethostbyname'}
    for symbol in symbols.splitlines():
        if any(term in symbol for term in forbidden) or symbol.strip() in network_imports:
            raise ValueError('Unreviewed metrics/network symbol in MediaPipe: ' + symbol)
    if require_runner:
        for method in ('Create', 'Process', 'Close'):
            if not any('TaskRunner' in line and method in line for line in symbols.splitlines()):
                raise ValueError('Expected MediaPipe TaskRunner method missing: ' + method)


def audit_install(destination, audit_path):
    audit = json.loads(audit_path.read_text())
    lock = json.loads((audit_path.parent / 'mediapipe.lock.json').read_text())
    if audit['runtime_version'] != lock['runtime_version']:
        raise ValueError('MediaPipe runtime version needs a new source and binary audit')
    for relative, expected in audit['binary_sha256'].items():
        path = destination / relative
        digest = hashlib.sha256()
        with path.open('rb') as binary:
            for chunk in iter(lambda: binary.read(1024 * 1024), b''):
                digest.update(chunk)
        if digest.hexdigest() != expected:
            raise ValueError('MediaPipe binary differs from the reviewed runner: ' + relative)
        symbols = subprocess.check_output(['nm', '-j', str(path)], text=True, stderr=subprocess.PIPE)
        check_symbols(symbols, require_runner=relative.endswith('.framework/MediaPipeTasksCommon'))
    print('MediaPipe source/binary audit: all six pinned binaries verified')


if __name__ == '__main__':
    dependencies = Path(__file__).resolve().parent
    audit_install(dependencies.parent / '.dependencies' / 'mediapipe', dependencies / 'mediapipe-audit.json')
