"""Bundle a relocatable, arm64-only CPython stdlib runtime from python.org macOS install."""
from pathlib import Path
import os, shutil, subprocess, sys

source = Path(sys.base_prefix)
target = Path(sys.argv[1]).resolve()
if target.exists(): shutil.rmtree(target)
(target / 'bin').mkdir(parents=True)
(target / 'lib').mkdir()
version = f'{sys.version_info.major}.{sys.version_info.minor}'
stdlib = source / 'lib' / f'python{version}'
shutil.copytree(stdlib, target / 'lib' / f'python{version}', ignore=shutil.ignore_patterns(
    '__pycache__', '*.pyc', 'site-packages', 'test', 'tests', 'idlelib', 'tkinter', 'turtledemo', 'ensurepip', 'config-*'))
# Keep only extension modules required by the stdlib-only adapter. This avoids
# bundling network/UI/crypto libraries that the adapter never uses.
dyn = target / 'lib' / f'python{version}' / 'lib-dynload'
keep = {'_struct','math','zlib','_datetime','_zoneinfo','_random','_bisect','_sha2',
        '_blake2','_md5','_sha1','_sha3','_opcode','_typing','_heapq','_json','binascii','_csv','unicodedata',
        '_posixsubprocess','fcntl','select','_bz2','_lzma','_pickle','array'}
for p in dyn.glob('*.so'):
    if p.name.split('.')[0] not in keep: p.unlink()
exe = target / 'bin' / 'python3'
lib = target / 'lib' / f'libpython{version}.dylib'
shutil.copy2(source / 'Resources/Python.app/Contents/MacOS/Python', exe)
shutil.copy2(source / 'Python', lib)
original_python = str(source / 'Python')
machos = [lib, *dyn.glob('*.so'), exe]
for p in machos:
    # The host installation is universal2. Restrict P0's compatibility claim to arm64.
    tmp=p.with_name(p.name+'.thin')
    subprocess.run(['lipo', str(p), '-thin', 'arm64', '-output', str(tmp)], check=True, capture_output=True)
    tmp.replace(p)
    os.chmod(p, 0o755)
    dependencies=subprocess.check_output(['otool','-L',str(p)],text=True).splitlines()[1:]
    for line in dependencies:
        dep=line.strip().split(' (')[0]
        if dep == original_python:
            new='@loader_path/'+os.path.relpath(lib,p.parent)
            subprocess.run(['install_name_tool','-change',dep,new,str(p)],check=True,capture_output=True)
        elif dep.startswith('/Library/') or dep.startswith('/opt/'):
            raise RuntimeError(f'Unbundled dependency: {p}: {dep}')
    if p==lib: subprocess.run(['install_name_tool','-id','@rpath/'+lib.name,str(p)],check=True,capture_output=True)
    subprocess.run(['codesign','--force','--sign','-',str(p)],check=True,capture_output=True)
shutil.copy2(stdlib/'LICENSE.txt',target/'LICENSE-CPython.txt')
# Isolated mode ignores PYTHONHOME/PYTHONPATH. CPython resolves stdlib next to
# this relocated executable; no developer-machine absolute path is required.
subprocess.run([str(exe),'-I','-S','-c',
    "import sys,json,zlib,hashlib,struct,math,datetime,zoneinfo,zipfile,secrets; "
    "assert sys.prefix.startswith(sys.argv[1]),sys.prefix; "
    "print(json.dumps({'python':sys.version.split()[0],'prefix':sys.prefix}))",str(target)],
    check=True,env={'PATH':'/usr/bin:/bin','HOME':'/private/tmp','PYTHONHOME':'/nonexistent','PYTHONPATH':'/nonexistent'})
