# DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
# Run from the worktree root after sourcing /workspace/toolchains/env.sh.
import pathlib, subprocess, re, os
root=pathlib.Path.cwd(); build=pathlib.Path('/tmp/build-F4')
os.environ['LD_LIBRARY_PATH'] = str(build) + ':' + os.environ.get('LD_LIBRARY_PATH', '')
def run(args): subprocess.run(args, check=True)
modules=['HelmCore','HelmFileSystem','HelmPersistence','HelmOperations','HelmSearch','HelmTestKit']
objects=[str(p) for m in modules for p in (build/'debug'/f'{m}.build').glob('*.swift.o')]
ui=[str(p) for p in (root/'Sources/HelmUI').rglob('*.swift') if not re.search(r'import (SwiftUI|AppKit)',p.read_text())]
run(['swiftc','-emit-library',*objects,'-o',str(build/'libF4Dependencies.so')])
for name,files in [('HelmUI',ui),('HelmApp',[str(p) for p in (root/'Sources/HelmApp').glob('*.swift')])]:
 run(['swiftc','-emit-library','-emit-module','-enable-testing','-module-name',name,'-swift-version','5','-I',str(build/'debug/Modules'),*files,'-L',str(build),'-lF4Dependencies','-o',str(build/f'lib{name}.so'),'-emit-module-path',str(build/f'{name}.swiftmodule')])
files=[p for p in (root/'Tests/HelmAppTests').glob('*.swift')]+[p for p in (root/'Tests/HelmUITests').rglob('*.swift') if p.name not in ['SettingsBindingsTests.swift','ContentNativeAdapterTests.swift']]
entries=[]
for p in files:
 text=p.read_text(); cls=re.search(r'final class (\w+): XCTestCase',text)
 if not cls: continue
 methods=re.findall(r'func (test\w+)\(\)([^\{]*)',text)
 entries.append('testCase(['+','.join('("'+n+'", '+('asyncTest('+cls[1]+'.'+n+')' if 'async' in suffix else cls[1]+'.'+n)+')' for n,suffix in methods)+'])')
runner=build/'runner'; runner.mkdir(exist_ok=True)
(runner/'main.swift').write_text('import XCTest\nXCTMain(['+','.join(entries)+'])')
run(['swiftc','-swift-version','5','-I',str(build),'-I',str(build/'debug/Modules'),'-L',str(build),'-lHelmUI','-lHelmApp','-lF4Dependencies',*[str(p) for p in files],str(runner/'main.swift'),'-o',str(build/'F4Tests')])
run([str(build/'F4Tests')])
